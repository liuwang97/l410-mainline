/*
 * libl410-fastrsa.so: LD_PRELOAD shim for WPS Office (L410, docs/tuning/launch-latency.md).
 *
 * WPS ships an OpenSSL 1.1.1 libcrypto built for "linux-generic32" (plain C, 32-bit limbs).
 * At every start its libkccservice decrypts two blobs with a bundled RSA private key through
 * RSA_private_decrypt(): 38-65 ms on the main thread on a Cortex-A76, 116 ms on an A55. This shim takes that
 * one function over and runs the private-key operation in a statically linked OpenSSL 1.1.1w
 * built for linux-aarch64 (assembler Montgomery multiplication). Its symbols are all local
 * (-Wl,--exclude-libs,ALL); WPS's key is read through WPS's own RSA_get0_* accessors (dlsym
 * RTLD_NEXT), and anything unexpected falls back to WPS's RSA_private_decrypt(). The results are
 * cached per boot (see cache_path()): the same two blobs come back at every start.
 * L410_FASTRSA_OFF=1 passes everything to WPS's own function; L410_FASTRSA_CHECK=1 runs both
 * and logs the comparison to /tmp/l410-fastrsa.log.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <pthread.h>
#include <unistd.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <openssl/bn.h>
#include <openssl/rsa.h>
#include <openssl/sha.h>

/* the static OpenSSL 1.1.1w copy of RSA_private_decrypt, renamed by objcopy (build.sh) */
int l410_ossl_RSA_private_decrypt(int, const unsigned char *, unsigned char *, RSA *, int);

/* WPS's libcrypto (the next definition in the lookup order) */
typedef int (*decrypt_fn)(int, const unsigned char *, unsigned char *, RSA *, int);
typedef void (*get3_fn)(const RSA *, const BIGNUM **, const BIGNUM **, const BIGNUM **);
typedef void (*get2_fn)(const RSA *, const BIGNUM **, const BIGNUM **);
typedef int (*bits_fn)(const BIGNUM *);
typedef int (*bn2bin_fn)(const BIGNUM *, unsigned char *);

static struct {
	decrypt_fn decrypt;
	get3_fn get0_key, get0_crt_params;
	get2_fn get0_factors;
	bits_fn num_bits;
	bn2bin_fn bn2bin;
	int ok;
} wps;
static pthread_once_t once = PTHREAD_ONCE_INIT;

static void init(void)
{
	wps.decrypt = (decrypt_fn)dlsym(RTLD_NEXT, "RSA_private_decrypt");
	wps.get0_key = (get3_fn)dlsym(RTLD_NEXT, "RSA_get0_key");
	wps.get0_crt_params = (get3_fn)dlsym(RTLD_NEXT, "RSA_get0_crt_params");
	wps.get0_factors = (get2_fn)dlsym(RTLD_NEXT, "RSA_get0_factors");
	wps.num_bits = (bits_fn)dlsym(RTLD_NEXT, "BN_num_bits");
	wps.bn2bin = (bn2bin_fn)dlsym(RTLD_NEXT, "BN_bn2bin");
	wps.ok = wps.decrypt && wps.get0_key && wps.get0_crt_params && wps.get0_factors &&
		 wps.num_bits && wps.bn2bin && !getenv("L410_FASTRSA_OFF");
}

/* WPS BIGNUM -> our BIGNUM, through the big-endian byte form */
static BIGNUM *conv(const BIGNUM *b)
{
	unsigned char buf[1024];
	int n;

	if (!b)
		return NULL;
	n = (wps.num_bits(b) + 7) / 8;
	if (n > (int)sizeof(buf))
		return NULL;
	wps.bn2bin(b, buf);
	return BN_bin2bn(buf, n, NULL);
}

/*
 * Result cache. A private-key decryption is a function of (key, ciphertext, padding), so the
 * plaintext is cached under SHA-256(padding || modulus || ciphertext) in the caller's runtime
 * directory (tmpfs, per boot, user only): WPS decrypts the same two blobs with its bundled key at
 * every start. Anything that differs is a miss. L410_FASTRSA_NOCACHE=1 turns it off.
 */
static int cache_path(char *path, size_t len, int padding, const BIGNUM *n, int flen,
		      const unsigned char *from)
{
	const char *rt = getenv("XDG_RUNTIME_DIR");
	unsigned char mod[1024], md[SHA256_DIGEST_LENGTH];
	SHA256_CTX c;
	int nl, i, o;

	if (!rt || !*rt || getenv("L410_FASTRSA_NOCACHE") || getenv("L410_FASTRSA_CHECK"))
		return -1;
	nl = (wps.num_bits(n) + 7) / 8;
	if (nl > (int)sizeof(mod))
		return -1;
	wps.bn2bin(n, mod);
	SHA256_Init(&c);
	SHA256_Update(&c, &padding, sizeof(padding));
	SHA256_Update(&c, mod, nl);
	SHA256_Update(&c, from, flen);
	SHA256_Final(md, &c);
	o = snprintf(path, len, "%s/l410-fastrsa/", rt);
	if (o < 0 || (size_t)o + 2 * sizeof(md) + 1 > len)
		return -1;
	for (i = 0; i < (int)sizeof(md); i++)
		sprintf(path + o + 2 * i, "%02x", md[i]);
	return 0;
}

static int cache_get(const char *path, unsigned char *to, int max)
{
	struct stat st;
	int fd, r;

	fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
	if (fd < 0)
		return -1;
	if (fstat(fd, &st) || st.st_uid != getuid() || (st.st_mode & 077) ||
	    st.st_size <= 0 || st.st_size > max) {
		close(fd);
		return -1;
	}
	r = read(fd, to, st.st_size);
	close(fd);
	return r == st.st_size ? r : -1;
}

static void cache_put(const char *path, const unsigned char *data, int len)
{
	char dir[4096], tmp[4200];
	struct stat st;
	const char *slash = strrchr(path, '/');
	int fd;

	if (!slash || (size_t)(slash - path) >= sizeof(dir))
		return;
	memcpy(dir, path, slash - path);
	dir[slash - path] = 0;
	if (mkdir(dir, 0700) && errno != EEXIST)
		return;
	if (lstat(dir, &st) || !S_ISDIR(st.st_mode) || st.st_uid != getuid() || (st.st_mode & 077))
		return;
	snprintf(tmp, sizeof(tmp), "%s.%d.tmp", path, (int)getpid());
	fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
	if (fd < 0)
		return;
	if (write(fd, data, len) != len || close(fd) || rename(tmp, path))
		unlink(tmp);
}

__attribute__((visibility("default")))
int RSA_private_decrypt(int flen, const unsigned char *from, unsigned char *to, RSA *rsa, int padding)
{
	const BIGNUM *n, *e, *d, *p, *q, *dmp1, *dmq1, *iqmp;
	BIGNUM *bn[8] = { NULL };
	char cpath[4096];
	int cached = -1;
	RSA *r = NULL;
	int ret = -1, i;

	pthread_once(&once, init);
	if (!wps.decrypt)
		return -1;
	if (!wps.ok)
		return wps.decrypt(flen, from, to, rsa, padding);

	wps.get0_key(rsa, &n, &e, &d);
	wps.get0_factors(rsa, &p, &q);
	wps.get0_crt_params(rsa, &dmp1, &dmq1, &iqmp);
	if (!n || !e || !d || !p || !q || !dmp1 || !dmq1 || !iqmp)
		return wps.decrypt(flen, from, to, rsa, padding);

	if (cache_path(cpath, sizeof(cpath), padding, n, flen, from) == 0) {
		cached = 0;
		ret = cache_get(cpath, to, (wps.num_bits(n) + 7) / 8);
		if (ret >= 0)
			return ret;
	}

	bn[0] = conv(n); bn[1] = conv(e); bn[2] = conv(d); bn[3] = conv(p);
	bn[4] = conv(q); bn[5] = conv(dmp1); bn[6] = conv(dmq1); bn[7] = conv(iqmp);
	for (i = 0; i < 8; i++)
		if (!bn[i])
			goto fallback;
	r = RSA_new();
	if (!r || !RSA_set0_key(r, bn[0], bn[1], bn[2]))
		goto fallback;
	bn[0] = bn[1] = bn[2] = NULL;
	if (!RSA_set0_factors(r, bn[3], bn[4]))
		goto fallback;
	bn[3] = bn[4] = NULL;
	if (!RSA_set0_crt_params(r, bn[5], bn[6], bn[7]))
		goto fallback;
	bn[5] = bn[6] = bn[7] = NULL;

	{
		struct timespec t0, t1, t2;
		unsigned char *chk = NULL;
		int cret = 0;

		clock_gettime(CLOCK_MONOTONIC, &t0);
		ret = l410_ossl_RSA_private_decrypt(flen, from, to, r, padding);
		clock_gettime(CLOCK_MONOTONIC, &t1);
		/* L410_FASTRSA_CHECK=1: also run WPS's own decrypt and compare (log in /tmp) */
		if (ret >= 0 && getenv("L410_FASTRSA_CHECK") && (chk = malloc(flen + 64))) {
			FILE *f;

			cret = wps.decrypt(flen, from, chk, rsa, padding);
			clock_gettime(CLOCK_MONOTONIC, &t2);
			if ((f = fopen("/tmp/l410-fastrsa.log", "a"))) {
				fprintf(f, "pid %d bits %d pad %d: fast %d bytes %.1f ms, wps %d bytes %.1f ms, %s\n",
					(int)getpid(), RSA_bits(r), padding, ret,
					(t1.tv_sec - t0.tv_sec) * 1e3 + (t1.tv_nsec - t0.tv_nsec) / 1e6, cret,
					(t2.tv_sec - t1.tv_sec) * 1e3 + (t2.tv_nsec - t1.tv_nsec) / 1e6,
					cret == ret && !memcmp(chk, to, ret) ? "IDENTICAL" : "MISMATCH");
				fclose(f);
			}
			free(chk);
		}
	}
	RSA_free(r);
	if (ret >= 0) {
		if (cached == 0)
			cache_put(cpath, to, ret);
		return ret;
	}
	r = NULL;
fallback:
	RSA_free(r);
	for (i = 0; i < 8; i++)
		BN_clear_free(bn[i]);
	return wps.decrypt(flen, from, to, rsa, padding);
}

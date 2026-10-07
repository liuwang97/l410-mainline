#!/bin/bash
# Build libl410-fastrsa.so on an x86-64 Debian host or WSL (cross, aarch64; needs gcc-aarch64-linux-gnu): OpenSSL 1.1.1w libcrypto.a for linux-aarch64,
# its RSA_private_decrypt renamed, linked into the shim with every OpenSSL symbol local.
set -e
H=$(dirname "$(readlink -f "$0")")
W=$HOME/.cache/l410-openssl111; mkdir -p $W && cd $W
[ -f openssl-1.1.1w.tar.gz ] || curl -sfL -o openssl-1.1.1w.tar.gz https://github.com/openssl/openssl/releases/download/OpenSSL_1_1_1w/openssl-1.1.1w.tar.gz
echo "cf3098950cb4d853ad95c0841f1f9c6d3dc102dccfcacd521d93925208b76ac8  openssl-1.1.1w.tar.gz" | sha256sum -c -
if [ ! -f openssl-1.1.1w/libcrypto.a ]; then
	rm -rf openssl-1.1.1w && tar -xzf openssl-1.1.1w.tar.gz && cd openssl-1.1.1w
	./Configure linux-aarch64 --cross-compile-prefix=aarch64-linux-gnu- no-shared no-tests no-engine no-dso -O2 > ../configure.log
	make -j16 build_libs > ../make.log 2>&1
	cd ..
fi
aarch64-linux-gnu-objcopy --redefine-sym RSA_private_decrypt=l410_ossl_RSA_private_decrypt \
	openssl-1.1.1w/libcrypto.a libcrypto-l410.a
aarch64-linux-gnu-gcc -shared -fPIC -O2 -fvisibility=hidden -I openssl-1.1.1w/include \
	-o libl410-fastrsa.so $H/fastrsa.c libcrypto-l410.a \
	-Wl,--exclude-libs,ALL -Wl,--version-script=$H/fastrsa.map -Wl,-z,now -ldl -lpthread
aarch64-linux-gnu-strip --strip-unneeded libl410-fastrsa.so
ls -l libl410-fastrsa.so
aarch64-linux-gnu-nm -D --defined-only libl410-fastrsa.so

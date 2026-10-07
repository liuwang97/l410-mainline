/*
 * framelat: model one compositor frame on one CPU.
 * Every period: absolute-timer wakeup, then a fixed amount of CPU work that takes
 * WORK_US at the CPU's top speed. Reports wakeup latency, burst duration and how long
 * the CPU needed to reach 90% of its top speed inside the burst (DVFS ramp).
 *
 *   framelat <cpu> <rr|fair> [frames=300] [work_us=2000] [period_us=16667]
 *
 * Build and run on the L410 (needs gcc; rr needs root):
 *   ssh l410 'mkdir -p ~/.dlat && cat > ~/.dlat/framelat.c && gcc -O2 -o ~/.dlat/framelat ~/.dlat/framelat.c' < tests/bench/framelat.c
 *   ssh l410 'for c in 1 4 6; do for p in rr fair; do sudo ~/.dlat/framelat $c $p; done; done'
 * WORK_US is relative to each CPU's own top speed (an A55 at 1.86 GHz does ~0.28x
 * the work of a big A76 at 2.86 GHz in the same time). See docs/tuning/desktop-latency.md.
 */
#define _GNU_SOURCE
#include <sched.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define MAXCH 4096

static inline uint64_t now_ns(void)
{
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return t.tv_sec * 1000000000ull + t.tv_nsec;
}

static volatile uint64_t sink;
static void work(long n)
{
	uint64_t x = sink;
	for (long i = 0; i < n; i++)
		x = x * 6364136223846793005ull + 1442695040888963407ull;
	sink = x;
}

static int cmp(const void *a, const void *b)
{
	double x = *(const double *)a, y = *(const double *)b;
	return x < y ? -1 : x > y;
}

static double q(double *v, int n, double p)
{
	int i = (int)(n * p);
	return v[i < n ? i : n - 1];
}

int main(int argc, char **argv)
{
	if (argc < 3)
		return 2;
	int cpu = atoi(argv[1]);
	int rr = !strcmp(argv[2], "rr");
	int frames = argc > 3 ? atoi(argv[3]) : 300;
	double work_us = argc > 4 ? atof(argv[4]) : 2000;
	double period_us = argc > 5 ? atof(argv[5]) : 16667;

	cpu_set_t set;
	CPU_ZERO(&set);
	CPU_SET(cpu, &set);
	if (sched_setaffinity(0, sizeof(set), &set))
		return perror("affinity"), 1;
	if (rr) {
		struct sched_param sp = { .sched_priority = 1 };
		if (sched_setscheduler(0, SCHED_RR, &sp))
			return perror("sched"), 1;
	}

	/* calibrate at top speed: 400 ms busy first so DVFS is at max */
	uint64_t t = now_ns();
	while (now_ns() - t < 400000000ull)
		work(10000);
	long n = 2000000;
	t = now_ns();
	work(n);
	double rate = n / ((now_ns() - t) / 1000.0); /* iterations per us at max */
	long chunk = (long)(rate * 20);               /* 20 us of work per chunk */
	int nch = (int)(work_us / 20);
	if (nch > MAXCH)
		nch = MAXCH;

	double *wake = calloc(frames, sizeof(double));
	double *burst = calloc(frames, sizeof(double));
	double *ramp = calloc(frames, sizeof(double));
	uint64_t *ts = calloc(nch + 1, sizeof(uint64_t));
	struct timespec sl = { 0, 300000000 };
	nanosleep(&sl, NULL); /* let the CPU go idle / clock down */

	uint64_t t0 = now_ns();
	for (int k = 0; k < frames; k++) {
		uint64_t target = t0 + (uint64_t)((k + 1) * period_us * 1000);
		struct timespec tt = { target / 1000000000ull, target % 1000000000ull };
		clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &tt, NULL);
		ts[0] = now_ns();
		wake[k] = (ts[0] - target) / 1000.0;
		for (int c = 1; c <= nch; c++) {
			work(chunk);
			ts[c] = now_ns();
		}
		burst[k] = (ts[nch] - ts[0]) / 1000.0;
		ramp[k] = burst[k];
		for (int c = 1; c <= nch; c++)
			if ((ts[c] - ts[c - 1]) / 1000.0 <= 20 / 0.9) {
				ramp[k] = (ts[c - 1] - ts[0]) / 1000.0;
				break;
			}
	}
	qsort(wake, frames, sizeof(double), cmp);
	qsort(burst, frames, sizeof(double), cmp);
	qsort(ramp, frames, sizeof(double), cmp);
	printf("cpu%d %-4s wake us p50 %5.0f p90 %5.0f p99 %5.0f max %5.0f | burst ms (ideal %.1f) p50 %5.2f p90 %5.2f p99 %5.2f max %5.2f | ramp-to-90%% ms p50 %4.2f p90 %4.2f\n",
	       cpu, rr ? "rr" : "fair",
	       q(wake, frames, .5), q(wake, frames, .9), q(wake, frames, .99), wake[frames - 1],
	       work_us / 1000, q(burst, frames, .5) / 1000, q(burst, frames, .9) / 1000,
	       q(burst, frames, .99) / 1000, burst[frames - 1] / 1000,
	       q(ramp, frames, .5) / 1000, q(ramp, frames, .9) / 1000);
	return 0;
}

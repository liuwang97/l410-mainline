// tests/scroll-accel-test: drives the L410 libinput scroll acceleration
// (system/input/libinput/evdev-mt-touchpad-scroll-accel.c) through a real libinput context. A uinput
// touchpad with the L410 Goodix pad's axes (1920x1080 at 16/15 units per mm) performs two-finger
// swipes with given speed profiles, in real time (the kernel timestamps uinput events when they
// are written); libinput turns them into finger scroll events. The patched library logs speed and
// gain per frame at debug priority, which this program collects. tests/scroll-accel-test.sh
// builds and runs it (root; it keeps the device away from KWin with a udev seat rule).
//
//   scroll-accel-test const <mm/s>... [-d mm]      constant speed (default travel 30 mm)
//   scroll-accel-test flick <peak mm/s>... [-d mm]  minimum-jerk swipe (bell-shaped speed)
//   scroll-accel-test -v ...                        print every scroll event
//   -f <ms>                                         report interval (default 8)
//
// Output per swipe: finger travel, the travel libinput scrolled for (mm), the scroll output in
// libinput units and in mm of finger-equivalent (units / 10.52), the effective gain and the
// highest speed the library measured.
#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <libinput.h>
#include <linux/uinput.h>
#include <math.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>

#define NAME "l410-scrolltest touchpad"
#define RES_X 16
#define RES_Y 15
#define MAX_X 1919
#define MAX_Y 1079
#define UNITS_PER_MM (1000.0 / 25.4 * 0.9 * 0.2968)

static double frame_ms = 8.0;
static int verbose;
static int ufd;
static struct libinput *li;

// From the library's debug log: "scroll accel: dt %.1f ms, %.3f mm, %.1f mm/s, gain %.3f"
static struct {
	double mm, speed, gain;
	int frames;
	double sum_mm, vmax;
} acc;

static void log_handler(struct libinput *l, enum libinput_log_priority p, const char *fmt, va_list args)
{
	char buf[512];
	vsnprintf(buf, sizeof(buf), fmt, args);
	const char *s = strstr(buf, "scroll accel: dt ");
	double dt, mm, v, g;
	if (s && sscanf(s, "scroll accel: dt %lf ms, %lf mm, %lf mm/s, gain %lf", &dt, &mm, &v, &g) == 4) {
		acc.mm = mm;
		acc.speed = v;
		acc.gain = g;
		acc.frames++;
		acc.sum_mm += mm;
		if (v > acc.vmax)
			acc.vmax = v;
	} else if (p >= LIBINPUT_LOG_PRIORITY_INFO) {
		fputs(buf, stderr);
	}
}

static int open_restricted(const char *path, int flags, void *data)
{
	int fd = open(path, flags);
	return fd < 0 ? -errno : fd;
}

static void close_restricted(int fd, void *data)
{
	close(fd);
}

static const struct libinput_interface iface = { open_restricted, close_restricted };

static void emit(int type, int code, int value)
{
	struct input_event ev = { .type = type, .code = code, .value = value };
	if (write(ufd, &ev, sizeof(ev)) != sizeof(ev)) {
		perror("uinput write");
		exit(1);
	}
}

static void abs_setup(int code, int max, int res)
{
	struct uinput_abs_setup a = { .code = code, .absinfo = { .maximum = max, .resolution = res } };
	ioctl(ufd, UI_SET_ABSBIT, code);
	ioctl(ufd, UI_ABS_SETUP, &a);
}

static void create_device(char *devnode, size_t len)
{
	ufd = open("/dev/uinput", O_WRONLY | O_NONBLOCK);
	if (ufd < 0) {
		perror("/dev/uinput");
		exit(1);
	}
	ioctl(ufd, UI_SET_EVBIT, EV_KEY);
	ioctl(ufd, UI_SET_EVBIT, EV_ABS);
	int keys[] = { BTN_LEFT, BTN_TOUCH, BTN_TOOL_FINGER, BTN_TOOL_DOUBLETAP, BTN_TOOL_TRIPLETAP, BTN_TOOL_QUADTAP, BTN_TOOL_QUINTTAP };
	for (size_t i = 0; i < sizeof(keys) / sizeof(keys[0]); i++)
		ioctl(ufd, UI_SET_KEYBIT, keys[i]);
	ioctl(ufd, UI_SET_PROPBIT, INPUT_PROP_POINTER);
	ioctl(ufd, UI_SET_PROPBIT, INPUT_PROP_BUTTONPAD);
	abs_setup(ABS_X, MAX_X, RES_X);
	abs_setup(ABS_Y, MAX_Y, RES_Y);
	abs_setup(ABS_MT_SLOT, 4, 0);
	abs_setup(ABS_MT_POSITION_X, MAX_X, RES_X);
	abs_setup(ABS_MT_POSITION_Y, MAX_Y, RES_Y);
	abs_setup(ABS_MT_TOOL_TYPE, 2, 0);
	abs_setup(ABS_MT_TRACKING_ID, 65535, 0);
	struct uinput_setup s = { .id = { .bustype = BUS_I2C, .vendor = 0x27c6, .product = 0x01e0, .version = 0x100 } };
	snprintf(s.name, sizeof(s.name), "%s", NAME);
	ioctl(ufd, UI_DEV_SETUP, &s);
	if (ioctl(ufd, UI_DEV_CREATE) < 0) {
		perror("UI_DEV_CREATE");
		exit(1);
	}
	char sys[64];
	ioctl(ufd, UI_GET_SYSNAME(sizeof(sys)), sys);
	char dir[128];
	snprintf(dir, sizeof(dir), "/sys/devices/virtual/input/%s", sys);
	for (int tries = 0; tries < 100; tries++) {
		DIR *d = opendir(dir);
		struct dirent *e;
		while (d && (e = readdir(d))) {
			if (!strncmp(e->d_name, "event", 5) && strlen(e->d_name) < 16) {
				snprintf(devnode, len, "/dev/input/%.15s", e->d_name);
				closedir(d);
				usleep(500000);	// udev rules (seat, input_id) must have run
				return;
			}
		}
		if (d)
			closedir(d);
		usleep(20000);
	}
	fprintf(stderr, "no event node for %s\n", sys);
	exit(1);
}

struct totals {
	double out;
	double finger_mm;	// finger travel of the frames that produced output
	int events;
};

static void drain(struct totals *t)
{
	libinput_dispatch(li);
	struct libinput_event *e;
	while ((e = libinput_get_event(li))) {
		if (libinput_event_get_type(e) == LIBINPUT_EVENT_POINTER_SCROLL_FINGER) {
			struct libinput_event_pointer *p = libinput_event_get_pointer_event(e);
			double out = 0;
			for (int a = 0; a < 2; a++) {
				if (libinput_event_pointer_has_axis(p, a)) {
					double o = libinput_event_pointer_get_scroll_value(p, a);
					out += o * o;
				}
			}
			out = sqrt(out);
			if (out > 0) {
				t->out += out;
				t->finger_mm += acc.mm;
				t->events++;
			}
			if (verbose)
				printf("    t %8.1f ms  finger %5.2f mm  out %7.2f  v %6.1f mm/s  gain %.2f%s\n",
				       libinput_event_pointer_get_time_usec(p) / 1000.0, acc.mm, out, acc.speed, acc.gain,
				       out > 0 ? "" : "  (stop)");
		}
		libinput_event_destroy(e);
	}
}

static void sleep_until(struct timespec *ts, double add_ms)
{
	ts->tv_nsec += (long)(add_ms * 1e6);
	while (ts->tv_nsec >= 1000000000) {
		ts->tv_nsec -= 1000000000;
		ts->tv_sec++;
	}
	clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, ts, NULL);
}

static int tracking;

// One two-finger vertical swipe of travel_mm over duration_ms: constant speed, or a
// minimum-jerk profile (bell-shaped speed, peak = 1.875 x mean) for flicks.
static struct totals swipe(double travel_mm, double duration_ms, int flick)
{
	struct totals t = { 0 };
	const double x0 = 40, x1 = 60, y0 = 10;	// mm: fingers 20 mm apart, start near the top
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);

	emit(EV_ABS, ABS_MT_SLOT, 0);
	emit(EV_ABS, ABS_MT_TRACKING_ID, ++tracking);
	emit(EV_ABS, ABS_MT_POSITION_X, x0 * RES_X);
	emit(EV_ABS, ABS_MT_POSITION_Y, y0 * RES_Y);
	emit(EV_ABS, ABS_MT_SLOT, 1);
	emit(EV_ABS, ABS_MT_TRACKING_ID, ++tracking);
	emit(EV_ABS, ABS_MT_POSITION_X, x1 * RES_X);
	emit(EV_ABS, ABS_MT_POSITION_Y, y0 * RES_Y);
	emit(EV_KEY, BTN_TOUCH, 1);
	emit(EV_KEY, BTN_TOOL_DOUBLETAP, 1);
	emit(EV_ABS, ABS_X, x0 * RES_X);
	emit(EV_ABS, ABS_Y, y0 * RES_Y);
	emit(EV_SYN, SYN_REPORT, 0);
	for (int i = 0; i < 4; i++) {	// fingers rest a few frames before they move
		sleep_until(&ts, frame_ms);
		emit(EV_SYN, SYN_REPORT, 0);
		drain(&t);
	}

	const int frames = (int)ceil(duration_ms / frame_ms);
	for (int i = 1; i <= frames; i++) {
		double f = (double)i / frames;
		double s = flick ? f * f * f * (10 - 15 * f + 6 * f * f) : f;
		int y = (int)lround((y0 + s * travel_mm) * RES_Y);
		sleep_until(&ts, frame_ms);
		emit(EV_ABS, ABS_MT_SLOT, 0);
		emit(EV_ABS, ABS_MT_POSITION_Y, y);
		emit(EV_ABS, ABS_MT_SLOT, 1);
		emit(EV_ABS, ABS_MT_POSITION_Y, y);
		emit(EV_ABS, ABS_Y, y);
		emit(EV_SYN, SYN_REPORT, 0);
		drain(&t);
	}
	sleep_until(&ts, frame_ms);
	emit(EV_ABS, ABS_MT_SLOT, 0);
	emit(EV_ABS, ABS_MT_TRACKING_ID, -1);
	emit(EV_ABS, ABS_MT_SLOT, 1);
	emit(EV_ABS, ABS_MT_TRACKING_ID, -1);
	emit(EV_KEY, BTN_TOUCH, 0);
	emit(EV_KEY, BTN_TOOL_DOUBLETAP, 0);
	emit(EV_SYN, SYN_REPORT, 0);
	for (int i = 0; i < 40; i++) {	// stop event, then a pause before the next swipe
		usleep(10000);
		drain(&t);
	}
	return t;
}

int main(int argc, char **argv)
{
	double travel = 30;
	int flick = -1;
	double speeds[64];
	int n = 0;
	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "-v"))
			verbose = 1;
		else if (!strcmp(argv[i], "-d") && i + 1 < argc)
			travel = atof(argv[++i]);
		else if (!strcmp(argv[i], "-f") && i + 1 < argc)
			frame_ms = atof(argv[++i]);
		else if (!strcmp(argv[i], "const"))
			flick = 0;
		else if (!strcmp(argv[i], "flick"))
			flick = 1;
		else if (n < 64)
			speeds[n++] = atof(argv[i]);
	}
	if (flick < 0 || n == 0) {
		fprintf(stderr, "usage: %s [-v] [-d mm] [-f frame_ms] const|flick <mm/s>...\n", argv[0]);
		return 2;
	}

	char devnode[64];
	create_device(devnode, sizeof(devnode));
	li = libinput_path_create_context(&iface, NULL);
	libinput_log_set_handler(li, log_handler);
	libinput_log_set_priority(li, LIBINPUT_LOG_PRIORITY_DEBUG);
	struct libinput_device *dev = libinput_path_add_device(li, devnode);
	if (!dev) {
		fprintf(stderr, "libinput did not take %s\n", devnode);
		return 1;
	}
	struct totals dummy = { 0 };
	drain(&dummy);
	printf("# %s on %s, frame %.1f ms, %s\n", NAME, devnode, frame_ms,
	       flick ? "minimum-jerk swipes (speed = peak)" : "constant speed");
	printf("# speed mm/s | travel mm | scrolled mm | out units | out/10.52 | gain | frames | vmax mm/s\n");

	for (int i = 0; i < n; i++) {
		double duration = travel / (flick ? speeds[i] / 1.875 : speeds[i]) * 1000;
		memset(&acc, 0, sizeof(acc));
		struct totals t = swipe(travel, duration, flick);
		const double out_mm = t.out / UNITS_PER_MM;
		printf("%-5s %6.0f  %5.1f  %5.1f  %8.1f  %7.1f  %5.2f  %3d  %6.1f\n", flick ? "flick" : "const", speeds[i],
		       travel, acc.sum_mm, t.out, out_mm, t.finger_mm > 0 ? out_mm / t.finger_mm : 0, acc.frames, acc.vmax);
	}
	libinput_unref(li);
	ioctl(ufd, UI_DEV_DESTROY);
	return 0;
}

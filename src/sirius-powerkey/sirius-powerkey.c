// sirius-powerkey: the power key means "lock the screen" on this phone.
//
// GNOME has no such action for the power key: gnome-settings-daemon's
// media-keys plugin swallows XF86PowerOff (it holds logind's
// handle-power-key inhibitor) and only offers nothing / suspend / hibernate /
// "interactive" — and interactive is not a menu, it calls
// gnome-session Shutdown, i.e. a shutdown confirmation dialog that powers
// the device off after its 60 s countdown. See docs/POWER.md.
//
// So this helper watches the pmic pwrkey *without* EVIOCGRAB and, per press:
//   - unlocked + panel awake  -> org.gnome.ScreenSaver.Lock (lock + native blank);
//   - locked + panel awake    -> PowerSaveMode=3 (instant blank, no SetActive(false)
//                                so the desktop never flashes and the shield stays up);
//   - panel blanked           -> PowerSaveMode=0 (guaranteed wake even when blanked
//                                directly via PowerSaveMode=3, while native gsd wake
//                                also runs in parallel).
// Everything else stays native:
//   - locking is the same path logind's Lock() takes, so LockedHint, the
//     shield and the idle timer behave as usual;
//   - no brightness/DPMS writes, no private idle timer, no grab.
// Long press is still the PMIC's own hard poweroff.
//
// Runs as a systemd --user unit (needs the input group to read event0).
// Build: gcc -O2 -Wall -Wextra -o sirius-powerkey sirius-powerkey.c
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define PWRKEY_NAME "pm8941_pwrkey"
#define KEY_POWER_CODE 116
#define SYS_DPMS "/sys/class/drm/card0-DSI-1/dpms"

static void gdbus_call(const char *dest, const char *path, const char *method,
		       const char *const args[], int capture,
		       char *out, size_t outsz)
{
	int fds[2] = { -1, -1 };
	pid_t pid;

	if (capture && out && outsz) {
		out[0] = 0;
		if (pipe(fds) < 0)
			return;
	}
	pid = fork();
	if (pid < 0) {
		fprintf(stderr, "sirius-powerkey: fork: %s\n", strerror(errno));
		if (capture) {
			close(fds[0]);
			close(fds[1]);
		}
		return;
	}
	if (pid == 0) {
		const char *argv[16];
		int i = 0, j;

		/* the user manager does not always export the session bus */
		if (!getenv("DBUS_SESSION_BUS_ADDRESS")) {
			char addr[64];

			snprintf(addr, sizeof(addr), "unix:path=/run/user/%u/bus",
				 (unsigned)getuid());
			setenv("DBUS_SESSION_BUS_ADDRESS", addr, 1);
		}
		if (capture) {
			dup2(fds[1], STDOUT_FILENO);
			close(fds[0]);
			close(fds[1]);
		}
		argv[i++] = "gdbus";
		argv[i++] = "call";
		argv[i++] = "--session";
		argv[i++] = "--dest";
		argv[i++] = dest;
		argv[i++] = "--object-path";
		argv[i++] = path;
		argv[i++] = "--method";
		argv[i++] = method;
		if (args) {
			for (j = 0; args[j] && i < 15; j++)
				argv[i++] = args[j];
		}
		argv[i] = NULL;
		execvp("gdbus", (char *const *)argv);
		_exit(127);
	}
	if (!capture)
		return;
	close(fds[1]);
	/* gdbus exits right after the reply, so reading to EOF is bounded and
	   fast; no waitpid needed (SIGCHLD is ignored). */
	if (out && outsz) {
		size_t got = 0;

		while (got + 1 < outsz) {
			ssize_t n = read(fds[0], out + got, outsz - 1 - got);

			if (n <= 0)
				break;
			got += (size_t)n;
		}
		out[got] = 0;
	}
	close(fds[0]);
}

static void set_power_save_mode(int mode)
{
	char val[16];
	const char *args[4];

	snprintf(val, sizeof(val), "<int32 %d>", mode);
	args[0] = "org.gnome.Mutter.DisplayConfig";
	args[1] = "PowerSaveMode";
	args[2] = val;
	args[3] = NULL;
	gdbus_call("org.gnome.Mutter.DisplayConfig",
		   "/org/gnome/Mutter/DisplayConfig",
		   "org.freedesktop.DBus.Properties.Set",
		   args, 0, NULL, 0);
}

/* The panel's DPMS state is what tells a wake-up press (locked + blanked)
   apart from a "lock screen is showing" press (locked + awake). mutter has
   no fast D-Bus query for it (the DisplayConfig PowerSaveMode property
   would need a three-argument Properties.Get), and the sysfs path is fixed
   on this device: one DSI panel, card0-DSI-1 (see docs/POWER.md). */
static int display_blank(void)
{
	char buf[8];
	int fd = open(SYS_DPMS, O_RDONLY);
	ssize_t n;

	if (fd < 0)
		return 1;	/* can't tell: assume blanked so wake presses
				   keep working and only locking degrades */
	n = read(fd, buf, sizeof(buf) - 1);
	close(fd);
	if (n <= 0)
		return 1;
	buf[n] = 0;
	return strncmp(buf, "Off", 3) == 0;
}

/* Lock() returns once the shield is up, but when the session is *already*
   locked gnome-shell leaves the call hanging until the 25 s D-Bus timeout.
   So never call it blindly: gate on the saver state, which answers in ~40 ms. */
static void on_power_press(void)
{
	static double last_action_ms;
	char buf[64];
	struct timespec now;
	double now_ms;
	int blank;

	clock_gettime(CLOCK_MONOTONIC, &now);
	now_ms = now.tv_sec * 1000.0 + now.tv_nsec / 1e6;
	if (last_action_ms && now_ms - last_action_ms < 400)
		return;
	last_action_ms = now_ms;

	/* Sample the panel state FIRST, before any D-Bus roundtrip: a press
	   on a blanked lock screen also wakes it natively (key -> gsd -> KMS
	   commit), and that commit lands within tens of ms. Reading dpms
	   after GetActive (~40 ms) races the wake and misclassifies the
	   press, re-blanking it right away. */
	blank = display_blank();

	if (blank) {
		fprintf(stderr, "sirius-powerkey: wake\n");
		set_power_save_mode(0);
		return;
	}

	gdbus_call("org.gnome.ScreenSaver", "/org/gnome/ScreenSaver",
		   "org.gnome.ScreenSaver.GetActive", NULL, 1,
		   buf, sizeof(buf));
	if (!strstr(buf, "(true,")) {
		/* unlocked: the press means lock */
		fprintf(stderr, "sirius-powerkey: lock\n");
		gdbus_call("org.gnome.ScreenSaver", "/org/gnome/ScreenSaver",
			   "org.gnome.ScreenSaver.Lock", NULL, 0, NULL, 0);
		return;
	}

	/* locked and awake: blank directly via mutter PowerSaveMode=3 without
	   calling SetActive(false), so the lock shield stays up and never
	   flashes the desktop. */
	fprintf(stderr, "sirius-powerkey: blank\n");
	set_power_save_mode(3);
}

/* event numbers move around; match the device by name instead. */
static int open_pwrkey(const char *want, char *path, size_t len)
{
	DIR *d = opendir("/dev/input");
	struct dirent *e;

	if (!d)
		return -1;
	while ((e = readdir(d))) {
		char name[64] = "";
		int fd;

		if (strncmp(e->d_name, "event", 5) ||
		    strlen(e->d_name) > 16)
			continue;
		snprintf(path, len, "/dev/input/%s", e->d_name);
		fd = open(path, O_RDONLY | O_NONBLOCK);
		if (fd < 0)
			continue;
		if (ioctl(fd, EVIOCGNAME(sizeof(name) - 1), name) < 0) {
			close(fd);
			continue;
		}
		if (strcmp(name, want)) {
			close(fd);
			continue;
		}
		closedir(d);
		return fd;
	}
	closedir(d);
	return -1;
}

int main(int argc, char **argv)
{
	const char *want = argc > 1 ? argv[1] : PWRKEY_NAME;
	char path[64];
	int fd;

	/* gdbus children are fire-and-forget */
	signal(SIGCHLD, SIG_IGN);

	for (;;) {
		struct pollfd pfd;

		fd = open_pwrkey(want, path, sizeof(path));
		if (fd < 0) {
			sleep(1);
			continue;
		}
		fprintf(stderr, "sirius-powerkey: watching %s\n", path);

		for (;;) {
			struct input_event ev[32];
			ssize_t n;
			size_t i, cnt;
			int r;

			pfd.fd = fd;
			pfd.events = POLLIN;
			pfd.revents = 0;
			r = poll(&pfd, 1, -1);
			if (r < 0) {
				if (errno == EINTR)
					continue;
				break;
			}
			if (pfd.revents & (POLLERR | POLLHUP | POLLNVAL))
				break;
			n = read(fd, ev, sizeof(ev));
			if (n <= 0) {
				if (n < 0 && (errno == EAGAIN || errno == EINTR))
					continue;
				break;
			}
			cnt = (size_t)n / sizeof(ev[0]);
			for (i = 0; i < cnt; i++) {
				if (ev[i].type != EV_KEY ||
				    ev[i].code != KEY_POWER_CODE ||
				    ev[i].value != 1)
					continue;
				on_power_press();
			}
		}
		close(fd);
		sleep(1);
	}
	return 0;
}

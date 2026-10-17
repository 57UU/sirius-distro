// sirius-powerd: own the pmic power key AND the panel (see docs/POWER.md).
//
// - EVIOCGRABs /dev/input/event0 (pm8941_pwrkey): the key never reaches
//   the logind/gsd suspend flap. A press flips the panel.
// - Watches (no grab) all other input nodes for activity and blanks the
//   panel after IDLE_SEC of quiet, replacing the GNOME idle blank.
// GNOME is kept out of the blank path on purpose (idle-activation off,
// idle-dim off): mutter KMS-disables the CRTC on saver activate, the
// panel driver powerdowns (~1s later, bl_power refuses sysfs writes in
// that state), and rapid blank/unblank then fails KMS commits.
// OLED needs none of that: brightness 0 = emitters off, instant restore.
// Runs as a system service (root) and drives brightness sysfs directly.
// Saver D-Bus calls exist only for the manual-lock wake path.
// Long-press hard poweroff is PMIC hardware, unaffected by the grab.
//
// Build: aarch64-linux-gnu-gcc -O2 -Wall -o sirius-powerd sirius-powerd.c
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define POWER_DEV "/dev/input/event0"
#define INPUT_DIR "/dev/input"
#define KEY_POWER_CODE 116
#define IDLE_SEC 60
static long idle_sec = IDLE_SEC;
static double last_cfg = 0;
#define BL_BRIGHTNESS "/sys/class/backlight/ae94000.dsi.0/brightness"
#define SESS_UID_FALLBACK 1000
#define MAXFDS 32

static double mono(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec / 1e9;
}

/* session owner = uid running gnome-shell (any username); human
   sessions (uid >= 1000) win over the login screen. */
static uid_t sess_uid(void)
{
	DIR *d = opendir("/proc");
	struct dirent *e;
	uid_t found = 0, human = 0;
	struct stat st;
	char path[64], comm[64];
	int fd;
	ssize_t n;
	if (!d)
		return SESS_UID_FALLBACK;
	while ((e = readdir(d))) {
		if (e->d_name[0] < '0' || e->d_name[0] > '9' ||
		    strlen(e->d_name) > 16)
			continue;
		snprintf(path, sizeof(path), "/proc/%s/comm", e->d_name);
		fd = open(path, O_RDONLY);
		if (fd < 0)
			continue;
		n = read(fd, comm, sizeof(comm) - 1);
		close(fd);
		if (n <= 0)
			continue;
		comm[n] = 0;
		if (strcmp(comm, "gnome-shell\n"))
			continue;
		snprintf(path, sizeof(path), "/proc/%s", e->d_name);
		if (stat(path, &st) < 0)
			continue;
		found = st.st_uid;
		if (found >= 1000) {
			human = found;
			break;
		}
	}
	closedir(d);
	if (human)
		return human;
	return found ? found : SESS_UID_FALLBACK;
}
static void ensure_bus(void)
{
	char addr[64];
	uid_t uid;
	if (getenv("DBUS_SESSION_BUS_ADDRESS"))
		return;
	uid = getuid();
	if (uid == 0)
		uid = sess_uid();
	snprintf(addr, sizeof(addr), "unix:path=/run/user/%u/bus",
		 (unsigned)uid);
	setenv("DBUS_SESSION_BUS_ADDRESS", addr, 1);
}

/* run gdbus, capture first outsz-1 bytes of stdout; returns 0 on exit 0 */
static int gdbus(const char *method, const char *arg, char *out,
		 size_t outsz)
{
	int fds[2], st = -1;
	pid_t pid;
	ssize_t n;
	size_t got = 0;
	if (out && outsz)
		out[0] = 0;
	if (pipe(fds) < 0)
		return -1;
	pid = fork();
	if (pid < 0) {
		close(fds[0]);
		close(fds[1]);
		return -1;
	}
	if (pid == 0) {
		dup2(fds[1], STDOUT_FILENO);
		close(fds[0]);
		close(fds[1]);
		if (arg)
			execlp("gdbus", "gdbus", "call", "--session",
				"--dest", "org.gnome.ScreenSaver",
				"--object-path", "/org/gnome/ScreenSaver",
				"--method", method, arg, (char *)NULL);
		else
			execlp("gdbus", "gdbus", "call", "--session",
				"--dest", "org.gnome.ScreenSaver",
				"--object-path", "/org/gnome/ScreenSaver",
				"--method", method, (char *)NULL);
		_exit(127);
	}
	close(fds[1]);
	while (out && got + 1 < outsz) {
		n = read(fds[0], out + got, outsz - 1 - got);
		if (n <= 0)
			break;
		got += (size_t)n;
	}
	close(fds[0]);
	while (waitpid(pid, &st, 0) < 0 && errno == EINTR)
		;
	if (st != 0)
		return -1;
	return 0;
}

static int saver_active(void)
{
	char buf[64];
	if (gdbus("org.gnome.ScreenSaver.GetActive", NULL, buf,
		  sizeof(buf)) < 0)
		return 0;
	return strstr(buf, "(true,") != NULL;
}

/* follow org.gnome.desktop.session idle-delay (Settings -> Screen Blank);
   0 means Never -> no auto blank. Re-read at most once a minute. */
static void read_idle_delay(void)
{
	int fds[2], st = -1;
	pid_t pid;
	char buf[64], addr[96], ubuf[32], *p;
	ssize_t n;
	size_t got = 0;
	long v;
		uid_t uid = sess_uid();
	snprintf(addr, sizeof(addr),
		 "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/%u/bus",
		 (unsigned)uid);
	snprintf(ubuf, sizeof(ubuf), "#%u", (unsigned)uid);
	if (pipe(fds) < 0)
		return;
	pid = fork();
	if (pid < 0) {
		close(fds[0]);
		close(fds[1]);
		return;
	}
	if (pid == 0) {
		dup2(fds[1], STDOUT_FILENO);
		close(fds[0]);
		close(fds[1]);
		execlp("sudo", "sudo", "-u", ubuf, addr, "gsettings",
			"get", "org.gnome.desktop.session", "idle-delay",
			(char *)NULL);
		_exit(127);
	}
	close(fds[1]);
	while (got + 1 < sizeof(buf)) {
		n = read(fds[0], buf + got, sizeof(buf) - 1 - got);
		if (n <= 0)
			break;
		got += (size_t)n;
	}
	close(fds[0]);
	while (waitpid(pid, &st, 0) < 0 && errno == EINTR)
		;
	if (st != 0)
		return;
	buf[got] = 0;
	p = strstr(buf, "uint32");
	if (!p || sscanf(p + 6, "%ld", &v) != 1)
		return;
	if (v <= 0)
		v = -1;
	if (v > 86400)
		v = 86400;
	if (v != idle_sec) {
		fprintf(stderr, "sirius-powerd: idle timeout %lds (uid %u)\n", v, (unsigned)uid);
		idle_sec = v;
	}
}
static int bl_read(void)
{
	char buf[32];
	ssize_t n;
	int fd = open(BL_BRIGHTNESS, O_RDONLY);
	if (fd < 0)
		return 0;
	n = read(fd, buf, sizeof(buf) - 1);
	close(fd);
	if (n <= 0)
		return 0;
	buf[n] = 0;
	return atoi(buf);
}

static void bl_write(int v)
{
	char buf[32];
	int fd, len;
	ssize_t n;
	fd = open(BL_BRIGHTNESS, O_WRONLY);
	if (fd < 0) {
		fprintf(stderr, "sirius-powerd: open brightness: %s\n",
			strerror(errno));
		return;
	}
	len = snprintf(buf, sizeof(buf), "%d", v);
	n = write(fd, buf, (size_t)len);
	if (n != len)
		fprintf(stderr, "sirius-powerd: write brightness: %s\n",
			strerror(errno));
	close(fd);
}

struct panel {
	int saved;
	int off;
};

static void panel_set(struct panel *p, int on)
{
	if (on) {
		bl_write(p->saved);
		p->off = 0;
	} else {
		int cur = bl_read();
		if (cur > 0)
			p->saved = cur;
		bl_write(0);
		p->off = 1;
	}
}

static void on_power(struct panel *p)
{
	if (saver_active()) {
		fprintf(stderr, "sirius-powerd: power: saver wake\n");
		panel_set(p, 1);
		gdbus("org.gnome.ScreenSaver.SetActive", "false",
		      NULL, 0);
	} else if (p->off) {
		fprintf(stderr, "sirius-powerd: power: panel on\n");
		panel_set(p, 1);
	} else {
		fprintf(stderr, "sirius-powerd: power: panel off\n");
		panel_set(p, 0);
	}
}

struct dev {
	char path[64];
	int fd;
	int is_power;
};

int main(void)
{
	struct dev devs[MAXFDS];
	struct pollfd pfds[MAXFDS];
	struct panel pnl;
	int b, ndev, i;
	double last_activity;
	ensure_bus();
	b = bl_read();
	pnl.saved = b > 0 ? b : 200;
	pnl.off = b == 0;
	for (;;) {
		DIR *d;
		struct dirent *e;
		ndev = 0;
		d = opendir(INPUT_DIR);
		if (!d) {
			sleep(2);
			continue;
		}
		while ((e = readdir(d)) && ndev < MAXFDS) {
			int fd;
			if (strncmp(e->d_name, "event", 5) ||
			    strlen(e->d_name) > 16)
				continue;
			snprintf(devs[ndev].path, sizeof(devs[ndev].path),
				 "%s/%s", INPUT_DIR, e->d_name);
			fd = open(devs[ndev].path, O_RDONLY | O_NONBLOCK);
			if (fd < 0)
				continue;
			devs[ndev].fd = fd;
			devs[ndev].is_power =
				!strcmp(devs[ndev].path, POWER_DEV);
			if (devs[ndev].is_power) {
				if (ioctl(fd, EVIOCGRAB, 1) < 0) {
					fprintf(stderr,
						"sirius-powerd: grab %s: %s\n",
						devs[ndev].path,
						strerror(errno));
					close(fd);
					continue;
				}
				fprintf(stderr, "sirius-powerd: grabbed %s\n",
					devs[ndev].path);
			}
			ndev++;
		}
		closedir(d);
		last_activity = mono();
		for (;;) {
			int r, dead = 0;
			for (i = 0; i < ndev; i++) {
				pfds[i].fd = devs[i].fd;
				pfds[i].events = POLLIN;
				pfds[i].revents = 0;
			}
			r = poll(pfds, (nfds_t)ndev, 50);
			if (r < 0 && errno == EINTR)
				continue;
			for (i = 0; i < ndev; i++) {
				if (pfds[i].revents & (POLLERR | POLLHUP | POLLNVAL)) {
					dead = 1;
					break;
				}
				if (!(pfds[i].revents & POLLIN))
					continue;
				for (;;) {
					struct input_event ev[32];
					ssize_t n = read(devs[i].fd, ev,
							 sizeof(ev));
					size_t k, cnt;
					if (n < 0) {
						if (errno == EAGAIN)
							break;
						dead = 1;
						break;
					}
					if (n == 0) {
						dead = 1;
						break;
					}
					cnt = (size_t)n / sizeof(ev[0]);
					for (k = 0; k < cnt; k++) {
						if (ev[k].type != EV_KEY &&
						    ev[k].type != EV_ABS &&
						    ev[k].type != EV_REL)
							continue;
						last_activity = mono();
						if (devs[i].is_power &&
						    ev[k].type == EV_KEY &&
						    ev[k].code == KEY_POWER_CODE &&
						    ev[k].value == 1)
							on_power(&pnl);
					}
				}
				if (dead)
					break;
			}
			if (dead)
				break;
			if (mono() - last_cfg > 60) {
				read_idle_delay();
				last_cfg = mono();
			}
			if (idle_sec >= 0 &&
			    mono() - last_activity >= idle_sec && !pnl.off) {
				fprintf(stderr, "sirius-powerd: idle blank\n");
				panel_set(&pnl, 0);
			}
		}
		for (i = 0; i < ndev; i++)
			close(devs[i].fd);
		sleep(1);
	}
	return 0;
}
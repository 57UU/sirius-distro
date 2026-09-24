/* sirius-idle-watch: backlight auto-off on local-input idle.
 *
 * Watches /dev/input/event* and runs `sirius-screen auto-off` after
 * TIMEOUT seconds without any local input. Wake is owned by triggerhappy,
 * this daemon never turns the screen on, so the two can never fight.
 *
 * No polling loop: the process sleeps inside select() until input arrives
 * or the timeout expires (0% CPU while idle, ~100KB RSS).
 *
 * Usage: sirius-idle-watch [timeout_seconds]   (default 120)
 * Build: aarch64-linux-gnu-gcc -O2 -Wall -o sirius-idle-watch idle-watch.c
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <dirent.h>
#include <sys/select.h>
#include <sys/wait.h>

#define MAXDEVS 32
#define SCREEN_CTL "/usr/local/sbin/sirius-screen"

static char devnames[MAXDEVS][32];
static int devfds[MAXDEVS];
static int ndev = 0;

static int known_device(const char *name)
{
    int i;
    for (i = 0; i < ndev; i++) {
        if (strcmp(devnames[i], name) == 0)
            return 1;
    }
    return 0;
}

/* Open any event* nodes we do not already hold (covers hotplug). */
static void scan_devices(void)
{
    DIR *d = opendir("/dev/input");
    struct dirent *e;
    char path[64];
    int fd;
    if (!d)
        return;
    while ((e = readdir(d)) != NULL) {
        if (strncmp(e->d_name, "event", 5) != 0)
            continue;
        if (known_device(e->d_name))
            continue;
        if (ndev >= MAXDEVS)
            break;
        snprintf(path, sizeof(path), "/dev/input/%.20s", e->d_name);
        fd = open(path, O_RDONLY | O_NONBLOCK);
        if (fd < 0)
            continue;
        snprintf(devnames[ndev], sizeof(devnames[ndev]), "%.31s", e->d_name);
        devfds[ndev] = fd;
        ndev++;
    }
    closedir(d);
}

static void drop_device(int idx)
{
    int j;
    close(devfds[idx]);
    for (j = idx; j + 1 < ndev; j++) {
        devfds[j] = devfds[j + 1];
        memcpy(devnames[j], devnames[j + 1], sizeof(devnames[j]));
    }
    ndev--;
}

static void run_auto_off(void)
{
    pid_t pid = fork();
    int st;
    if (pid < 0)
        return;
    if (pid == 0) {
        execl(SCREEN_CTL, "sirius-screen", "auto-off", (char *)NULL);
        _exit(127);
    }
    while (waitpid(pid, &st, 0) < 0 && errno == EINTR)
        ;
}

/* Drain one fd; return 1 if the device is gone. */
static int drain_fd(int fd)
{
    char buf[4096];
    ssize_t n;
    for (;;) {
        n = read(fd, buf, sizeof(buf));
        if (n > 0)
            continue;
        if (n == 0)
            return 1;
        if (errno == ENODEV)
            return 1;
        return 0; /* EAGAIN: drained */
    }
}

int main(int argc, char **argv)
{
    int timeout = argc > 1 ? atoi(argv[1]) : 120;
    if (timeout <= 0)
        timeout = 120;
    fprintf(stderr, "sirius-idle-watch: timeout %ds\n", timeout);
    scan_devices();
    for (;;) {
        fd_set rfds;
        struct timeval tv;
        int maxfd = -1;
        int i, r;
        FD_ZERO(&rfds);
        for (i = 0; i < ndev; i++) {
            FD_SET(devfds[i], &rfds);
            if (devfds[i] > maxfd)
                maxfd = devfds[i];
        }
        if (maxfd < 0) {
            /* No input devices at all: sleep, rescan, stay safe. */
            sleep(timeout);
            scan_devices();
            run_auto_off();
            continue;
        }
        tv.tv_sec = timeout;
        tv.tv_usec = 0;
        r = select(maxfd + 1, &rfds, NULL, NULL, &tv);
        if (r < 0) {
            if (errno == EINTR)
                continue;
            sleep(5);
            continue;
        }
        if (r == 0) {
            /* Idle timeout expired: rescan (hotplug) + auto-off. */
            scan_devices();
            run_auto_off();
            continue;
        }
        for (i = ndev - 1; i >= 0; i--) {
            if (FD_ISSET(devfds[i], &rfds)) {
                if (drain_fd(devfds[i]))
                    drop_device(i);
            }
        }
    }
    return 0;
}
/* sirius-remodeset: force one full DRM modeset on the internal DSI panel,
 * then exit. Exit triggers drm_lastclose -> fbdev restore, which flushes
 * the pending console framebuffer to the panel. This un-bricks the display
 * on headless sirius boots, where nothing ever modesets and fbcon commits
 * stall (fb blank writes return EIO).
 *
 * No libdrm needed: raw DRM ioctl ABI only. Build:
 *   aarch64-linux-gnu-gcc -O2 -Wall -o sirius-remodeset sirius-remodeset.c
 * Run as root: sirius-remodeset [/dev/dri/card0]
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <sys/ioctl.h>

typedef uint32_t u32;
typedef uint64_t u64;
typedef int32_t s32;

/* ---- drm_mode.h subset (LP64 ABI, stable) ---- */
struct drm_mode_modeinfo {
	u32 clock;
	uint16_t hdisplay, hsync_start, hsync_end, htotal, hskew;
	uint16_t vdisplay, vsync_start, vsync_end, vtotal, vscan;
	u32 vrefresh;
	u32 flags;
	u32 type;
	char name[32];
};

struct drm_mode_card_res {
	u64 fb_list_ptr;
	u64 crtc_list_ptr;
	u64 connector_list_ptr;
	u64 encoder_list_ptr;
	u32 count_fbs;
	u32 count_crtcs;
	u32 count_connectors;
	u32 count_encoders;
	u32 min_width, max_width;
	u32 min_height, max_height;
};

struct drm_mode_get_connector {
	u64 encoders_ptr;
	u64 modes_ptr;
	u64 props_ptr;
	u64 prop_values_ptr;
	u32 count_modes;
	u32 count_props;
	u32 count_encoders;
	u32 encoder_id;
	u32 connector_id;
	u32 connector_type;
	u32 connector_type_id;
	u32 connection;
	u32 mm_width, mm_height;
	u32 subpixel;
	u32 pad;
};

struct drm_mode_get_encoder {
	u32 encoder_id, encoder_type, crtc_id;
	u32 possible_crtcs, possible_clones;
};

struct drm_mode_crtc_l {
	u64 set_connectors_ptr;
	u32 count_connectors;
	u32 crtc_id;
	u32 fb_id;
	u32 x, y;
	u32 gamma_size;
	u32 mode_valid;
	struct drm_mode_modeinfo mode;
};

#define DRM_IOCTL_BASE 'd'
#define DRM_IOWR_NR(nr, type) _IOWR(DRM_IOCTL_BASE, nr, type)
#define DRM_IOCTL_MODE_GETRESOURCES DRM_IOWR_NR(0xA0, struct drm_mode_card_res)
#define DRM_IOCTL_MODE_GETCONNECTOR DRM_IOWR_NR(0xA7, struct drm_mode_get_connector)
#define DRM_IOCTL_MODE_GETENCODER   DRM_IOWR_NR(0xA6, struct drm_mode_get_encoder)
#define DRM_IOCTL_MODE_SETCRTC      DRM_IOWR_NR(0xA2, struct drm_mode_crtc_l)

#define DRM_MODE_CONNECTED 1

static int xioctl(int fd, unsigned long req, void *arg)
{
	int r, tries = 0;
	do {
		r = ioctl(fd, req, arg);
	} while (r == -1 && (errno == EINTR || errno == EAGAIN) && tries++ < 5);
	return r;
}

int main(int argc, char **argv)
{
	const char *dev = argc > 1 ? argv[1] : "/dev/dri/card0";
	int fd = open(dev, O_RDWR);
	if (fd < 0) { perror("open"); return 1; }

	struct drm_mode_card_res res;
	memset(&res, 0, sizeof(res));
	if (xioctl(fd, DRM_IOCTL_MODE_GETRESOURCES, &res) < 0) {
		perror("GETRESOURCES"); return 1;
	}
	u32 *conns = calloc(res.count_connectors ? res.count_connectors : 1, sizeof(u32));
	u32 *crtcs = calloc(res.count_crtcs ? res.count_crtcs : 1, sizeof(u32));
	if (!conns || !crtcs) { fprintf(stderr, "oom\n"); return 1; }
	res.connector_list_ptr = (u64)(uintptr_t)conns;
	/* we only need crtcs+connectors: skip fb/encoder lists
	 * (their pointers would be NULL -> EFAULT) */
	res.count_fbs = 0;
	res.count_encoders = 0;
	res.crtc_list_ptr = (u64)(uintptr_t)crtcs;
	if (xioctl(fd, DRM_IOCTL_MODE_GETRESOURCES, &res) < 0) {
		perror("GETRESOURCES2"); return 1;
	}

	u32 want_conn = 0, want_crtc = 0;
	struct drm_mode_modeinfo want_mode;
	memset(&want_mode, 0, sizeof(want_mode));
	int have_mode = 0;

	for (u32 i = 0; i < res.count_connectors; i++) {
		struct drm_mode_get_connector c;
		memset(&c, 0, sizeof(c));
		c.connector_id = conns[i];
		if (xioctl(fd, DRM_IOCTL_MODE_GETCONNECTOR, &c) < 0)
			continue;
		if (c.connection != DRM_MODE_CONNECTED || c.count_modes == 0)
			continue;
		struct drm_mode_modeinfo *modes =
			calloc(c.count_modes, sizeof(*modes));
		if (!modes)
			continue;
		/* only modes needed: skip encoder/prop lists (NULL -> EFAULT) */
		c.count_encoders = 0;
		c.count_props = 0;
		c.modes_ptr = (u64)(uintptr_t)modes;
		if (xioctl(fd, DRM_IOCTL_MODE_GETCONNECTOR, &c) < 0) {
			free(modes);
			continue;
		}
		u32 crtc = 0;
		if (c.encoder_id) {
			struct drm_mode_get_encoder e;
			memset(&e, 0, sizeof(e));
			e.encoder_id = c.encoder_id;
			if (xioctl(fd, DRM_IOCTL_MODE_GETENCODER, &e) == 0)
				crtc = e.crtc_id;
		}
		if (!crtc && res.count_crtcs)
			crtc = crtcs[0];
		if (crtc) {
			want_conn = c.connector_id;
			want_crtc = crtc;
			want_mode = modes[0];
			have_mode = 1;
			free(modes);
			break;
		}
		free(modes);
	}
	free(conns);
	free(crtcs);

	if (!have_mode) {
		fprintf(stderr, "no connected connector with modes\n");
		return 1;
	}
	fprintf(stderr, "modeset conn=%u crtc=%u mode=%s\n",
		want_conn, want_crtc, want_mode.name);

	struct drm_mode_crtc_l sc;
	memset(&sc, 0, sizeof(sc));
	sc.set_connectors_ptr = (u64)(uintptr_t)&want_conn;
	sc.count_connectors = 1;
	sc.crtc_id = want_crtc;
	/* fb -1: re-apply mode on the currently bound fb (fbcon keeps content) */
	sc.fb_id = (u32)0xFFFFFFFFu;
	sc.x = 0;
	sc.y = 0;
	sc.mode_valid = 1;
	sc.mode = want_mode;
	if (xioctl(fd, DRM_IOCTL_MODE_SETCRTC, &sc) < 0) {
		perror("SETCRTC");
		close(fd);
		return 1;
	}
	fprintf(stderr, "SETCRTC-OK\n");
	close(fd);
	return 0;
}
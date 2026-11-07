#include "NDIShim.h"
#include <dlfcn.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <pthread.h>
#include <libgen.h>
#include <limits.h>
#include <mach-o/dyld.h>

// NDI SDK と同じ並びの構造体（必要なものだけ）
typedef struct { const char *p_ndi_name; const char *p_groups; bool clock_video; bool clock_audio; } send_create_t;
typedef struct { bool show_local_sources; const char *p_groups; const char *p_extra_ips; } find_create_t;
typedef struct { const char *p_ndi_name; const char *p_url_address; } source_t;
typedef struct {
    source_t source_to_connect_to;
    int color_format;      // 0 = BGRX_BGRA
    int bandwidth;         // 100 = highest
    bool allow_video_fields;
    const char *p_ndi_recv_name;
} recv_create_v3_t;
typedef struct {
    int xres, yres;
    int FourCC;
    int frame_rate_N, frame_rate_D;
    float picture_aspect_ratio;
    int frame_format_type;  // 1 = progressive
    int64_t timecode;
    uint8_t *p_data;
    int line_stride_in_bytes;
    const char *p_metadata;
    int64_t timestamp;
} video_frame_v2_t;

#define FOURCC(a, b, c, d) ((int)((uint32_t)(a) | ((uint32_t)(b) << 8) | ((uint32_t)(c) << 16) | ((uint32_t)(d) << 24)))

static bool (*p_initialize)(void);
static const char *(*p_version)(void);
static void *(*p_send_create)(const send_create_t *);
static void (*p_send_destroy)(void *);
static void (*p_send_video_v2)(void *, const video_frame_v2_t *);
static int (*p_send_get_no_connections)(void *, uint32_t);
static void *(*p_find_create_v2)(const find_create_t *);
static void (*p_find_destroy)(void *);
static const source_t *(*p_find_get_current_sources)(void *, uint32_t *);
static void *(*p_recv_create_v3)(const recv_create_v3_t *);
static void (*p_recv_destroy)(void *);
static int (*p_recv_capture_v2)(void *, video_frame_v2_t *, void *, void *, uint32_t);
static void (*p_recv_free_video_v2)(void *, const video_frame_v2_t *);

static int loaded = -1;
static char lib_path[1024];
static pthread_mutex_t load_lock = PTHREAD_MUTEX_INITIALIZER;

static void *try_open(const char *path) {
    if (!path || !*path) return NULL;
    void *h = dlopen(path, RTLD_LOCAL | RTLD_NOW);
    if (h) snprintf(lib_path, sizeof lib_path, "%s", path);
    return h;
}

static void *open_lib(void) {
    char buf[1024];
    // 1. アプリに同梱したもの（Contents/Frameworks）
    char exe[1024];
    uint32_t n = sizeof exe;
    if (_NSGetExecutablePath(exe, &n) == 0) {
        char real[PATH_MAX];
        if (realpath(exe, real)) {
            snprintf(buf, sizeof buf, "%s/../Frameworks/libndi.dylib", dirname(real));
            char lib[PATH_MAX];
            if (realpath(buf, lib)) { void *h = try_open(lib); if (h) return h; }
        }
    }
    // 2. NDI ランタイム・SDK・ほかのアプリに入っているもの
    const char *envs[] = { "NDI_RUNTIME_DIR_V6", "NDI_RUNTIME_DIR_V5" };
    for (int i = 0; i < 2; i++) {
        const char *d = getenv(envs[i]);
        if (d && *d) { snprintf(buf, sizeof buf, "%s/libndi.dylib", d); void *h = try_open(buf); if (h) return h; }
    }
    const char *paths[] = {
        "/usr/local/lib/libndi.dylib",
        "/Library/NDI SDK for Apple/lib/macOS/libndi.dylib",
        "/Library/NDI SDK for macOS/lib/macOS/libndi.dylib",
        "/Applications/NDI Video Monitor.app/Contents/Frameworks/libndi.dylib",
        "/Applications/NDI Tools/NDI Video Monitor.app/Contents/Frameworks/libndi.dylib",
        "/Library/Application Support/NewTek/NDI/libndi.dylib",
        "/Library/Application Support/Resolume/lib/libndi.dylib",
        "/Applications/Resolume Arena/libndi.dylib",
        "/Applications/Resolume Avenue/libndi.dylib",
        "/opt/homebrew/lib/libndi.dylib",
        NULL,
    };
    for (int i = 0; paths[i]; i++) { void *h = try_open(paths[i]); if (h) return h; }
    return try_open("libndi.dylib");
}

int ndi_load(void) {
    pthread_mutex_lock(&load_lock);
    if (loaded < 0) {
        loaded = 0;
        void *h = open_lib();
        if (h) {
#define SYM(var, name) var = dlsym(h, name)
            SYM(p_initialize, "NDIlib_initialize");
            SYM(p_version, "NDIlib_version");
            SYM(p_send_create, "NDIlib_send_create");
            SYM(p_send_destroy, "NDIlib_send_destroy");
            SYM(p_send_video_v2, "NDIlib_send_send_video_v2");
            SYM(p_send_get_no_connections, "NDIlib_send_get_no_connections");
            SYM(p_find_create_v2, "NDIlib_find_create_v2");
            SYM(p_find_destroy, "NDIlib_find_destroy");
            SYM(p_find_get_current_sources, "NDIlib_find_get_current_sources");
            SYM(p_recv_create_v3, "NDIlib_recv_create_v3");
            SYM(p_recv_destroy, "NDIlib_recv_destroy");
            SYM(p_recv_capture_v2, "NDIlib_recv_capture_v2");
            SYM(p_recv_free_video_v2, "NDIlib_recv_free_video_v2");
#undef SYM
            bool ok = p_initialize && p_send_create && p_send_destroy && p_send_video_v2 && p_send_get_no_connections
                && p_find_create_v2 && p_find_destroy && p_find_get_current_sources && p_recv_create_v3
                && p_recv_destroy && p_recv_capture_v2 && p_recv_free_video_v2;
            if (ok && p_initialize()) loaded = 1; else lib_path[0] = 0;
        }
    }
    int r = loaded;
    pthread_mutex_unlock(&load_lock);
    return r;
}

const char *ndi_lib_path(void) { return loaded == 1 ? lib_path : ""; }
const char *ndi_version_string(void) { return (loaded == 1 && p_version) ? p_version() : ""; }

void *ndi_send_create(const char *name) {
    if (ndi_load() != 1) return NULL;
    send_create_t c = { name, NULL, false, false };
    return p_send_create(&c);
}
void ndi_send_destroy(void *s) { if (s && loaded == 1) p_send_destroy(s); }

void ndi_send_bgrx(void *s, int w, int h, int stride, const uint8_t *data, int fpsN, int fpsD) {
    if (!s || loaded != 1) return;
    video_frame_v2_t f;
    memset(&f, 0, sizeof f);
    f.xres = w; f.yres = h;
    f.FourCC = FOURCC('B', 'G', 'R', 'X');
    f.frame_rate_N = fpsN; f.frame_rate_D = fpsD;
    f.picture_aspect_ratio = 0;   // 0 = 縦横の画素数どおり
    f.frame_format_type = 1;
    f.timecode = INT64_MAX;       // NDI に決めてもらう
    f.p_data = (uint8_t *)data;
    f.line_stride_in_bytes = stride;
    p_send_video_v2(s, &f);
}

int ndi_send_connections(void *s, uint32_t t) { return (s && loaded == 1) ? p_send_get_no_connections(s, t) : 0; }

void *ndi_find_create(void) {
    if (ndi_load() != 1) return NULL;
    find_create_t c = { true, NULL, NULL };
    return p_find_create_v2(&c);
}
void ndi_find_destroy(void *f) { if (f && loaded == 1) p_find_destroy(f); }

int ndi_find_sources(void *f, char *out, int cap) {
    if (cap > 0) out[0] = 0;
    if (!f || loaded != 1) return 0;
    uint32_t n = 0;
    const source_t *s = p_find_get_current_sources(f, &n);
    int len = 0;
    for (uint32_t i = 0; i < n; i++) {
        const char *nm = s[i].p_ndi_name ? s[i].p_ndi_name : "";
        int l = (int)strlen(nm);
        if (len + l + 2 > cap) break;
        if (len > 0) out[len++] = '\n';
        memcpy(out + len, nm, l);
        len += l;
        out[len] = 0;
    }
    return (int)n;
}

void *ndi_recv_create(const char *name) {
    if (ndi_load() != 1) return NULL;
    recv_create_v3_t c;
    memset(&c, 0, sizeof c);
    c.source_to_connect_to.p_ndi_name = name;
    c.color_format = 0;
    c.bandwidth = 100;
    c.allow_video_fields = false;
    c.p_ndi_recv_name = "Halo VJ";
    return p_recv_create_v3(&c);
}
void ndi_recv_destroy(void *r) { if (r && loaded == 1) p_recv_destroy(r); }

int ndi_recv_capture(void *r, uint32_t timeout, ndi_video_t *out) {
    if (!r || loaded != 1) return 0;
    _Static_assert(sizeof(video_frame_v2_t) <= sizeof(out->raw), "frame storage");
    video_frame_v2_t *f = (video_frame_v2_t *)out->raw;
    memset(f, 0, sizeof *f);
    int type = p_recv_capture_v2(r, f, NULL, NULL, timeout);
    if (type != 1) return 0;   // 1 = 映像
    if (f->FourCC != FOURCC('B', 'G', 'R', 'A') && f->FourCC != FOURCC('B', 'G', 'R', 'X')) {
        p_recv_free_video_v2(r, f);
        return 0;
    }
    out->width = f->xres; out->height = f->yres;
    out->stride = f->line_stride_in_bytes > 0 ? f->line_stride_in_bytes : f->xres * 4;
    out->has_alpha = f->FourCC == FOURCC('B', 'G', 'R', 'A');
    out->data = f->p_data;
    return 1;
}

void ndi_recv_free(void *r, ndi_video_t *out) {
    if (!r || loaded != 1) return;
    p_recv_free_video_v2(r, (video_frame_v2_t *)out->raw);
    out->data = NULL;
}

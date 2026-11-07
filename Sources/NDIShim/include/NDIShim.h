// NDI を、入っている NDI ランタイム（libndi.dylib）から実行時に読み込んで使う小さな補助。
// NDI の SDK のヘッダーは使わず、必要な構造体だけ同じ並びで書いている（NDI SDK 5 / 6 の C の API）。
#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// libndi を探して読み込む（何度呼んでもよい）。読めたら 1
int ndi_load(void);
/// 読み込んだ libndi の場所（読めていなければ空）
const char *ndi_lib_path(void);
/// NDI の版（読めていなければ空）
const char *ndi_version_string(void);

// 送る
void *ndi_send_create(const char *name);
void ndi_send_destroy(void *sender);
/// BGRX（不透明）で 1 枚送る（送り終わるまで待つ）
void ndi_send_bgrx(void *sender, int width, int height, int stride, const uint8_t *data, int fpsN, int fpsD);
/// 受け取っている相手の数
int ndi_send_connections(void *sender, uint32_t timeout_ms);

// 探す
void *ndi_find_create(void);
void ndi_find_destroy(void *finder);
/// 見つかっている送り手の名前を、改行でつないで out に入れる。戻りは数
int ndi_find_sources(void *finder, char *out, int capacity);

// 受け取る
void *ndi_recv_create(const char *source_name);
void ndi_recv_destroy(void *receiver);

typedef struct {
    int width, height, stride;
    int has_alpha;       // BGRA なら 1、BGRX なら 0
    const uint8_t *data;
    unsigned char raw[128]; // NDI の映像の枠（返すときに使う）
} ndi_video_t;

/// 映像を 1 枚待つ（来たら 1。使い終わったら ndi_recv_free で返す）
int ndi_recv_capture(void *receiver, uint32_t timeout_ms, ndi_video_t *out);
void ndi_recv_free(void *receiver, ndi_video_t *frame);

#ifdef __cplusplus
}
#endif

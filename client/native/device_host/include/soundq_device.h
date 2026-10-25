#ifndef SOUNDQ_DEVICE_H
#define SOUNDQ_DEVICE_H
#include "soundq_mix.h"
#ifdef __cplusplus
extern "C" {
#endif

#define SQ_DEVICE_ABI_VERSION 1u

typedef struct sq_device sq_device;
typedef enum sq_device_result {
  SQ_DEVICE_OK = 0,
  SQ_DEVICE_INVALID = 1,
  SQ_DEVICE_NO_MEMORY = 2,
  SQ_DEVICE_OPEN_FAILED = 3,
  SQ_DEVICE_FORMAT_MISMATCH = 4,
  SQ_DEVICE_START_FAILED = 5,
  SQ_DEVICE_PAUSE_FAILED = 6,
  SQ_DEVICE_CLOSE_FAILED = 7,
  SQ_DEVICE_RENDER_FAILED = 8,
  SQ_DEVICE_DISCONNECTED = 9,
  SQ_DEVICE_CALLBACK_FAILED = 10
} sq_device_result;

/* One control/producer thread owns open/start/pause/close and sq_submit.
 * Engine is borrowed. sample_rate and max_block_frames MUST equal its sq_config;
 * opaque mixer ABI v1 has no configuration query, so host cannot verify equality.
 * Bounds: sample_rate 8000..192000, max_block_frames 1..65536.
 * Open configures one native float32 stereo device but DOES NOT start output or
 * render. No Dart callbacks. Rate exactly 1; frames are engine/source PCM frames.
 * Engine PCM must already be decoded, aligned and at the requested sample rate.
 * Do not call sq_render yourself while a device owns the engine. At most one
 * device per engine; caller enforces this ownership across shared libraries.
 * Host/PCM must outlive every callback. Close successfully BEFORE sq_destroy.
 * Open failure returns NULL; sq_device_error(NULL) gives this thread's last open
 * error, sq_device_native_error(NULL) its OS code. Neither allocates strings. */
SQ_API sq_device *sq_device_open(sq_engine *engine, uint32_t sample_rate,
                                  uint32_t max_block_frames);
/* Start resumes the same engine cursor; repeated start/pause is idempotent.
 * Callback alone advances cursor. Paused callbacks write silence, consume no
 * frames or queued revisions. Pause gates rendering then drains active renders
 * before returning, including on OS stop failure. In-flight hardware audio is
 * not retracted. Start after a sticky asynchronous failure requires close/open. */
SQ_API sq_device_result sq_device_start(sq_device *device);
SQ_API sq_device_result sq_device_pause(sq_device *device);
/* Successful close stops/quiesces callbacks and frees the handle. On failure
 * handle remains valid, rendering is gated off; retry close, do not destroy the
 * engine or release host. close(NULL) succeeds. Never close from a callback. */
SQ_API sq_device_result sq_device_close(sq_device *device);
/* First sticky failure since open (control or callback/route error), zero on
 * healthy handle. Independent atomic snapshots, not an atomic result/code pair.
 * Native code is OSStatus on Apple, aaudio_result_t on Android; zero for host
 * validation/render errors. No automatic route recovery or alternate player. */
SQ_API sq_device_result sq_device_error(const sq_device *device);
SQ_API int32_t sq_device_native_error(const sq_device *device);
SQ_API uint32_t sq_device_sample_rate(const sq_device *device);
SQ_API uint32_t sq_device_max_block_frames(const sq_device *device);
#ifdef __cplusplus
}
#endif
#endif

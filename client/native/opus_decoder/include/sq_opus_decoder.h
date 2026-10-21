#ifndef SQ_OPUS_DECODER_H
#define SQ_OPUS_DECODER_H
#include <stddef.h>
#include <stdint.h>
#if defined(__GNUC__)
#define SQ_OPUS_API __attribute__((visibility("default")))
#else
#define SQ_OPUS_API
#endif
#ifdef __cplusplus
extern "C" {
#endif

typedef struct sq_opus_decoder sq_opus_decoder;
typedef enum sq_opus_status {
  SQ_OPUS_OK = 0,
  SQ_OPUS_INVALID_ARGUMENT = -1,
  SQ_OPUS_IO = -2,
  SQ_OPUS_INVALID_STREAM = -3,
  SQ_OPUS_UNSUPPORTED = -4,
  SQ_OPUS_LIMIT = -5,
  SQ_OPUS_DECODE = -6,
  SQ_OPUS_OUT_OF_MEMORY = -7
} sq_opus_status;

/* Hard limits: compressed file <=512 MiB; pending encoded packet <=256 KiB;
 * one read <=48,000 stereo frames (384,000 output bytes). No full PCM cache.
 * All functions are worker-only, single owner, non-concurrent, non-reentrant.
 * Caller verifies byte hash, expected timeline and private path ownership before
 * open, and holds the immutable file/cache lease until destroy completes.
 * Absolute local regular path only; final-component symlinks rejected. */
#define SQ_OPUS_MAX_FILE_BYTES UINT64_C(536870912)
#define SQ_OPUS_MAX_WINDOW_FRAMES UINT32_C(48000)
SQ_OPUS_API int sq_opus_decoder_open(const char *absolute_path,
  uint64_t max_file_bytes, sq_opus_decoder **out_decoder);
SQ_OPUS_API uint32_t sq_opus_decoder_sample_rate(const sq_opus_decoder *decoder);
SQ_OPUS_API uint32_t sq_opus_decoder_channels(const sq_opus_decoder *decoder);
/* Trimmed 48k frames: pre-skip and EOS end trim already excluded. */
SQ_OPUS_API int64_t sq_opus_decoder_frame_count(const sq_opus_decoder *decoder);
SQ_OPUS_API uint32_t sq_opus_decoder_pre_skip(const sq_opus_decoder *decoder);
/* [start,start+count), interleaved float stereo, caller-owned aligned buffer.
 * max_bytes is buffer capacity, NOT sample count. Validates capacity for the
 * requested count even at EOF; count=0 permits NULL. start==length is EOF;
 * start>length is invalid. OK may return fewer frames only at trimmed EOF.
 * Never writes beyond frames_read*2 floats, never zero-fills unused capacity.
 * On failure frames_read=0; output may be partially written and MUST be ignored.
 * Upstream header gain is applied; R128 track/album tags are not applied. */
SQ_OPUS_API int sq_opus_decoder_read_window(sq_opus_decoder *decoder,
  int64_t start_frame, uint32_t frame_count, float *stereo,
  size_t max_bytes, uint32_t *frames_read);
SQ_OPUS_API void sq_opus_decoder_destroy(sq_opus_decoder *decoder);
SQ_OPUS_API const char *sq_opus_status_string(int status);
#ifdef __cplusplus
}
#endif
#endif

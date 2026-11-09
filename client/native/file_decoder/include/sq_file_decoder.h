#ifndef SQ_FILE_DECODER_H
#define SQ_FILE_DECODER_H
#include <stddef.h>
#include <stdint.h>
#if defined(__GNUC__)
#define SQ_FILE_API __attribute__((visibility("default")))
#else
#define SQ_FILE_API
#endif
#ifdef __cplusplus
extern "C" {
#endif

typedef struct sq_file_decoder sq_file_decoder;
typedef enum sq_file_status {
  SQ_FILE_OK = 0,
  SQ_FILE_INVALID_ARGUMENT = -1,
  SQ_FILE_IO = -2,
  SQ_FILE_INVALID_STREAM = -3,
  SQ_FILE_UNSUPPORTED = -4,
  SQ_FILE_LIMIT = -5,
  SQ_FILE_DECODE = -6,
  SQ_FILE_OUT_OF_MEMORY = -7
} sq_file_status;
#define SQ_FILE_MAX_FILE_BYTES UINT64_C(17179869216)
#define SQ_FILE_MAX_ENCODED_BYTES UINT64_C(134217728)
#define SQ_FILE_MAX_WINDOW_FRAMES UINT32_C(48000)

/* Worker-only, single owner, non-concurrent, non-reentrant; never call from an
 * audio callback. No renderer/output. Byte-sniffed MP3 Layer III, PCM16/float32
 * RIFF WAVE (mono/stereo), existing single-link 48k stereo Ogg Opus, or SQP1
 * immutable platform-decoded stereo float PCM with exact 64-bit frame extent.
 * Encoded formats retain the 128MiB portable limit. SQP1 admits up to 16GiB PCM
 * plus its 32-byte header. All reads/seeks remain bounded worker operations.
 * Caller holds an immutable regular-file/cache lease through destroy, verifies
 * expected hash/timeline, and owns parent-directory trust. Absolute local path;
 * O_NOFOLLOW rejects final-component symlinks, not ancestor symlinks.
 * max_file_bytes is required, positive, and <= SQ_FILE_MAX_FILE_BYTES.
 * Success returns a new owned handle; every failure clears *out_decoder. */
SQ_FILE_API int sq_file_decoder_open(const char *absolute_path,
  uint64_t max_file_bytes, sq_file_decoder **out_decoder);
/* Source rate (no resampling); output is always interleaved float stereo.
 * Mono is duplicated, not attenuated. Normalized float units (PCM16 /32768);
 * codec overshoots are preserved, not clipped. Float WAV must be finite.
 * NULL handle getters return 0, 0, -1 respectively. */
SQ_FILE_API uint32_t sq_file_decoder_sample_rate(const sq_file_decoder *decoder);
SQ_FILE_API uint32_t sq_file_decoder_channels(const sq_file_decoder *decoder);
/* Source-rate frames; codec priming/end padding already excluded once. WAV uses
 * exact data-byte extent, never duration/fact metadata. */
SQ_FILE_API int64_t sq_file_decoder_frame_count(const sq_file_decoder *decoder);
/* [start,start+count); <=48000 frames. max_bytes is capacity in BYTES, checked
 * for the full requested count even at EOF. start==length is valid EOF;
 * start>length invalid. count=0 permits NULL output. Aligned caller-owned
 * buffer; only frames_read*2 floats are written, unused tail untouched.
 * OK may be short only at EOF. Failure sets frames_read=0; any partial output
 * MUST be ignored. Seeking/decoding/file I/O and bounded caches are worker-only. */
SQ_FILE_API int sq_file_decoder_read_window(sq_file_decoder *decoder,
  int64_t start_frame, uint32_t frame_count, float *stereo,
  size_t max_bytes, uint32_t *frames_read);
SQ_FILE_API void sq_file_decoder_destroy(sq_file_decoder *decoder);
SQ_FILE_API const char *sq_file_decoder_status_string(int status);
#ifdef __cplusplus
}
#endif
#endif

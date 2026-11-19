#pragma once
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Worker-only, single owner; callbacks synchronous, must not reenter. No URL,
// file, player or audio device ownership. Caller must fence request generation
// at publication. Interleaved stereo float, source rate, origin in PCM frames.
// Callback data is borrowed only until return; return 0 to retire the decoder.
// `expected_frames` is an admitted source-relative extent, not catalog duration.
typedef struct sq_preview_mp3 sq_preview_mp3;
typedef int (*sq_preview_pcm)(void*, const float*, uint64_t first, uint32_t frames, uint32_t rate);
enum {
    SQ_PREVIEW_OK = 0, SQ_PREVIEW_FORMAT = -1, SQ_PREVIEW_LIMIT = -2,
    SQ_PREVIEW_RETIRED = -3, SQ_PREVIEW_TRUNCATED = -4, SQ_PREVIEW_CLOSED = -5
};
sq_preview_mp3* sq_preview_create(size_t content_length, uint64_t expected_frames,
                                 sq_preview_pcm sink, void* context);
int sq_preview_feed(sq_preview_mp3*, const uint8_t*, size_t);
// Call only on clean HTTP body completion. The terminal decoded packet is not
// published before this succeeds. Errors are sticky; failure is not EOS.
int sq_preview_finish(sq_preview_mp3*);
void sq_preview_destroy(sq_preview_mp3*);
size_t sq_preview_state_bytes(void);

#ifdef __cplusplus
}
#endif

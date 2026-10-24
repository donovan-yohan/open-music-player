#include "sq_opus_decoder.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <sys/resource.h>

int main(int argc, char **argv) {
  if (argc != 2) return 2;
  sq_opus_decoder *d = NULL;
  assert(sq_opus_decoder_open(argv[1], SQ_OPUS_MAX_FILE_BYTES, &d) == 0);
  int64_t frames = sq_opus_decoder_frame_count(d);
  assert(frames == INT64_C(172800000)); /* one hour, not a PCM allocation */
  float buffer[512];
  for (int i = 0; i < 16; ++i) {
    int64_t start = frames-100000-(int64_t)i*27191;
    uint32_t got = 0;
    assert(sq_opus_decoder_read_window(d, start, 256, buffer, sizeof(buffer), &got) == 0);
    assert(got == 256);
    for (unsigned j = 0; j < 512; ++j) assert(isfinite(buffer[j]) && fabsf(buffer[j]) < 0.001f);
  }
  sq_opus_decoder_destroy(d);
  struct rusage usage;
  assert(getrusage(RUSAGE_SELF, &usage) == 0);
#if defined(__APPLE__)
  long rss_bytes = usage.ru_maxrss;
#else
  long rss_bytes = usage.ru_maxrss * 1024;
#endif
  assert(rss_bytes < 64*1024*1024);
  printf("{\"hour_frames\":%lld,\"windows\":16,\"max_rss_bytes\":%ld,\"rss_limit_bytes\":67108864}\n",
    (long long)frames, rss_bytes);
  return 0;
}

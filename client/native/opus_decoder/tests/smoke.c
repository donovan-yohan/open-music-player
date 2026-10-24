#include "sq_opus_decoder.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dirent.h>

int main(int argc, char **argv) {
  if (argc != 2) return 2;
  char path[4096];
  snprintf(path, sizeof(path), "%s/stereo.opus", argv[1]);
  sq_opus_decoder *d = NULL;
  assert(sq_opus_decoder_open(path, SQ_OPUS_MAX_FILE_BYTES, &d) == SQ_OPUS_OK);
  assert(sq_opus_decoder_frame_count(d) == 336137);
  assert(sq_opus_decoder_sample_rate(d) == 48000);
  assert(sq_opus_decoder_channels(d) == 2);
  assert(sq_opus_decoder_pre_skip(d) == 312);
  snprintf(path, sizeof(path), "%s/reference.f32", argv[1]);
  FILE *ref = fopen(path, "rb");
  assert(ref);
  float buffer[8192*2+4], oracle[8192*2];
  const int64_t positions[] = {0, 1, 311, 312, 959, 48001, 200001, 335999, 128, 311};
  for (size_t j = 0; j < sizeof(positions)/sizeof(*positions); ++j) {
    for (size_t i = 0; i < sizeof(buffer)/sizeof(*buffer); ++i) buffer[i] = 91;
    uint32_t got = 999;
    assert(sq_opus_decoder_read_window(d, positions[j], 8192, buffer, 8192*8, &got) == 0);
    assert(got == (uint32_t)(336137-positions[j] < 8192 ? 336137-positions[j] : 8192));
    assert(fseek(ref, (long)positions[j]*8, SEEK_SET) == 0);
    assert(fread(oracle, 8, got, ref) == got);
    for (size_t i = 0; i < got*2; ++i) assert(fabsf(buffer[i]-oracle[i]) < 0.003f);
    for (size_t i = got*2; i < sizeof(buffer)/sizeof(*buffer); ++i) assert(buffer[i] == 91);
  }
  uint32_t got = 123;
  assert(sq_opus_decoder_read_window(d, 0, UINT32_MAX, buffer, SIZE_MAX, &got) == SQ_OPUS_LIMIT);
  assert(got == 0);
  assert(sq_opus_decoder_read_window(d, -1, 1, buffer, 8, &got) == SQ_OPUS_INVALID_ARGUMENT);
  assert(sq_opus_decoder_read_window(d, 336137, 1, buffer, 8, &got) == 0 && got == 0);
  assert(sq_opus_decoder_read_window(d, 0, 1, NULL, 8, &got) == SQ_OPUS_INVALID_ARGUMENT);
  assert(sq_opus_decoder_read_window(d, 0, 1, buffer, 7, &got) == SQ_OPUS_LIMIT);
  fclose(ref);
  sq_opus_decoder_destroy(d);
  DIR *dir = opendir(argv[1]);
  assert(dir);
  struct dirent *entry;
  unsigned rejected = 0;
  while ((entry = readdir(dir))) {
    if (!strstr(entry->d_name, ".opus") || !strcmp(entry->d_name, "stereo.opus") ||
        !strcmp(entry->d_name, "hour.opus")) continue;
    snprintf(path, sizeof(path), "%s/%s", argv[1], entry->d_name);
    d = (sq_opus_decoder *)(uintptr_t)1;
    assert(sq_opus_decoder_open(path, SQ_OPUS_MAX_FILE_BYTES, &d) < 0);
    assert(d == NULL);
    ++rejected;
  }
  closedir(dir);
  assert(rejected >= 12);
  sq_opus_decoder_destroy(NULL);
  printf("native smoke passed; rejected=%u\n", rejected);
  return 0;
}

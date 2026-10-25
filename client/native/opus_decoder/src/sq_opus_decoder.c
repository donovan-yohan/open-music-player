#define _FILE_OFFSET_BITS 64
#include "sq_opus_decoder.h"
#include <opusfile.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>

struct sq_opus_decoder {
  OggOpusFile *opus;
  FILE *file;
  int64_t frames;
  uint32_t pre_skip;
};

/* Validate framing with libogg, NOT a home-grown Ogg parser. This streaming
 * compressed-byte scan catches CRC, page holes, trailing junk and missing EOS
 * that tolerant libopusfile would otherwise recover/conceal. Cap incomplete
 * packets BEFORE ogg_stream_pagein can grow its packet buffer. No PCM decoded. */
static int validate_container(FILE *file, uint64_t size) {
  ogg_sync_state sync;
  ogg_stream_state stream;
  ogg_page page;
  ogg_packet packet;
  int initialized = 0, saw_eos = 0, status = SQ_OPUS_INVALID_STREAM;
  long serial = 0, sequence = 0;
  uint64_t accounted = 0, pending = 0, consumed = 0;
  if (ogg_sync_init(&sync) != 0) return SQ_OPUS_OUT_OF_MEMORY;
  for (;;) {
    int result = ogg_sync_pageout(&sync, &page);
    if (result < 0) break;
    if (result == 0) {
      char *buffer = ogg_sync_buffer(&sync, 16384);
      if (!buffer) { status = SQ_OPUS_OUT_OF_MEMORY; break; }
      size_t got = fread(buffer, 1, 16384, file);
      if (!got) {
        status = ferror(file) ? SQ_OPUS_IO :
          (initialized && saw_eos && !pending && accounted == size ?
           SQ_OPUS_OK : SQ_OPUS_INVALID_STREAM);
        break;
      }
      consumed += got;
      if (consumed > size) { status = SQ_OPUS_IO; break; }
      if (ogg_sync_wrote(&sync, (long)got) != 0) break;
      continue;
    }
    if (saw_eos) { status = SQ_OPUS_UNSUPPORTED; break; }
    if (ogg_page_version(&page) != 0) break;
    if (!initialized) {
      if (!ogg_page_bos(&page) || ogg_page_continued(&page)) break;
      serial = ogg_page_serialno(&page);
      if (ogg_stream_init(&stream, (int)serial) != 0) {
        status = SQ_OPUS_OUT_OF_MEMORY; break;
      }
      initialized = 1;
    } else if (ogg_page_bos(&page) || ogg_page_serialno(&page) != serial) {
      status = SQ_OPUS_UNSUPPORTED; break;
    }
    if (ogg_page_pageno(&page) != sequence++) break;
    accounted += (uint64_t)page.header_len + (uint64_t)page.body_len;
    pending += (uint64_t)page.body_len;
    if (pending > 262144) { status = SQ_OPUS_LIMIT; break; }
    if (ogg_stream_pagein(&stream, &page) != 0) break;
    while ((result = ogg_stream_packetout(&stream, &packet)) > 0) {
      if (packet.bytes < 0 || (uint64_t)packet.bytes > pending) break;
      pending -= (uint64_t)packet.bytes;
    }
    if (result != 0) break;
    if (ogg_page_eos(&page)) saw_eos = 1;
  }
  if (initialized) ogg_stream_clear(&stream);
  ogg_sync_clear(&sync);
  if (fseeko(file, 0, SEEK_SET) != 0) return SQ_OPUS_IO;
  return status;
}

static int local_read(void *source, unsigned char *data, int bytes) {
  FILE *file = source;
  size_t got = fread(data, 1, (size_t)bytes, file);
  return ferror(file) ? -1 : (int)got;
}
static int local_seek(void *source, opus_int64 offset, int whence) {
  return fseeko(source, (off_t)offset, whence);
}
static opus_int64 local_tell(void *source) { return (opus_int64)ftello(source); }

int sq_opus_decoder_open(const char *path, uint64_t max_bytes,
                         sq_opus_decoder **out) {
  if (!out) return SQ_OPUS_INVALID_ARGUMENT;
  *out = NULL;
  if (!path || path[0] != '/' || max_bytes == 0 ||
      max_bytes > SQ_OPUS_MAX_FILE_BYTES) return SQ_OPUS_INVALID_ARGUMENT;
  int fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
  if (fd < 0) return SQ_OPUS_IO;
  struct stat st;
  if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) || st.st_size <= 0) {
    close(fd); return SQ_OPUS_IO;
  }
  if ((uint64_t)st.st_size > max_bytes) { close(fd); return SQ_OPUS_LIMIT; }
  FILE *file = fdopen(fd, "rb");
  if (!file) { close(fd); return SQ_OPUS_IO; }
  int status = validate_container(file, (uint64_t)st.st_size);
  if (status != SQ_OPUS_OK) { fclose(file); return status; }
  const OpusFileCallbacks callbacks = {local_read, local_seek, local_tell, NULL};
  int upstream_error = 0;
  OggOpusFile *opus = op_open_callbacks(file, &callbacks, NULL, 0, &upstream_error);
  if (!opus) { fclose(file); return SQ_OPUS_INVALID_STREAM; }
  const OpusHead *head = op_head(opus, 0);
  int64_t frames = op_pcm_total(opus, -1);
  if (!op_seekable(opus) || op_link_count(opus) != 1 || !head ||
      head->channel_count != 2 || head->input_sample_rate != 48000 ||
      head->mapping_family != 0 || frames <= 0) {
    op_free(opus); fclose(file); return SQ_OPUS_UNSUPPORTED;
  }
  sq_opus_decoder *decoder = calloc(1, sizeof(*decoder));
  if (!decoder) { op_free(opus); fclose(file); return SQ_OPUS_OUT_OF_MEMORY; }
  decoder->opus = opus;
  decoder->file = file;
  decoder->frames = frames;
  decoder->pre_skip = head->pre_skip;
  *out = decoder;
  return SQ_OPUS_OK;
}

uint32_t sq_opus_decoder_sample_rate(const sq_opus_decoder *d) { return d ? 48000 : 0; }
uint32_t sq_opus_decoder_channels(const sq_opus_decoder *d) { return d ? 2 : 0; }
int64_t sq_opus_decoder_frame_count(const sq_opus_decoder *d) { return d ? d->frames : -1; }
uint32_t sq_opus_decoder_pre_skip(const sq_opus_decoder *d) { return d ? d->pre_skip : 0; }

int sq_opus_decoder_read_window(sq_opus_decoder *d, int64_t start,
  uint32_t count, float *stereo, size_t bytes, uint32_t *read_frames) {
  if (!read_frames) return SQ_OPUS_INVALID_ARGUMENT;
  *read_frames = 0;
  if (!d || start < 0 || start > d->frames ||
      (count && !stereo)) return SQ_OPUS_INVALID_ARGUMENT;
  if (count > SQ_OPUS_MAX_WINDOW_FRAMES || bytes < (size_t)count * 2 * sizeof(float))
    return SQ_OPUS_LIMIT;
  uint32_t target = (uint32_t)((d->frames-start) < count ? d->frames-start : count);
  if (!target) return SQ_OPUS_OK;
  if (op_pcm_tell(d->opus) != start) {
    /* Upstream supplies mandatory 80ms preroll. Add at most one second for
     * closer waveform convergence of highly tonal material after random seeks.
     * Never decode from origin for distant seeks; scratch is a fixed 20ms. */
    int64_t warm_start = start > 48000 ? start - 48000 : 0;
    if (op_pcm_seek(d->opus, warm_start) != 0) return SQ_OPUS_DECODE;
    float discard[960 * 2];
    while (warm_start < start) {
      int remaining = (int)(start - warm_start);
      int chunk = remaining < 960 ? remaining : 960;
      int link = -1;
      int got = op_read_float(d->opus, discard, chunk * 2, &link);
      if (got <= 0 || got > chunk || link != 0) return SQ_OPUS_DECODE;
      warm_start += got;
    }
  }
  uint32_t done = 0;
  while (done < target) {
    int link = -1;
    int got = op_read_float(d->opus, stereo + done*2, (int)((target-done)*2), &link);
    if (got <= 0 || link != 0 || (uint32_t)got > target-done)
      return SQ_OPUS_DECODE; /* Do not hide OP_HOLE or premature EOF. */
    done += (uint32_t)got;
  }
  *read_frames = done;
  return SQ_OPUS_OK;
}

void sq_opus_decoder_destroy(sq_opus_decoder *d) {
  if (!d) return;
  op_free(d->opus);
  fclose(d->file);
  free(d);
}

const char *sq_opus_status_string(int status) {
  switch (status) {
    case SQ_OPUS_OK: return "ok";
    case SQ_OPUS_INVALID_ARGUMENT: return "invalid argument";
    case SQ_OPUS_IO: return "local file I/O failure";
    case SQ_OPUS_INVALID_STREAM: return "invalid, corrupt or truncated Ogg Opus stream";
    case SQ_OPUS_UNSUPPORTED: return "requires single-link 48k stereo mapping-family-0 Opus";
    case SQ_OPUS_LIMIT: return "encoded file, packet or decoded window limit exceeded";
    case SQ_OPUS_DECODE: return "seek/decode failed or premature EOF";
    case SQ_OPUS_OUT_OF_MEMORY: return "out of memory";
    default: return "unknown decoder status";
  }
}

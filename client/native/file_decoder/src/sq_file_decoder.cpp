#define _FILE_OFFSET_BITS 64
#include "sq_file_decoder.h"
#include "sq_opus_decoder.h"
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <fcntl.h>
#include <new>
#include <cstdlib>
#define DR_MP3_IMPLEMENTATION
#define DR_MP3_NO_STDIO
#define DR_MP3_NO_SIMD
#define DR_MP3_ONLY_MP3
#define DR_MP3_FLOAT_OUTPUT
#include "../third_party/dr_mp3.h"
#include <sys/stat.h>

struct Mp3State {
  FILE *file=nullptr;
  uint64_t read_budget=UINT64_MAX;
  uint32_t seek_budget=UINT32_MAX;
  drmp3 codec{};
  bool initialized=false;
  drmp3_seek_point points[65536]{};
  uint32_t point_count=0;
  float page[16384*2];
  int64_t page_start=-1, cursor=0;
  uint32_t page_count=0;
};
#include <unistd.h>

struct sq_file_decoder {
  FILE *file = nullptr;
  sq_opus_decoder *opus = nullptr;
  Mp3State *mp3 = nullptr;
  uint32_t rate = 0, source_channels = 0, format = 0, block = 0;
  uint64_t data_offset = 0;
  int64_t frames = 0;
};
namespace {
uint16_t le16(const unsigned char *b) { return uint16_t(b[0] | uint16_t(b[1])<<8); }
uint32_t le32(const unsigned char *b) { return uint32_t(b[0]) | uint32_t(b[1])<<8 | uint32_t(b[2])<<16 | uint32_t(b[3])<<24; }
bool at(FILE *f, uint64_t offset, void *b, size_t n) {
  return fseeko(f, static_cast<off_t>(offset), SEEK_SET)==0 && fread(b,1,n,f)==n;
}
size_t mp_read(void *p,void *b,size_t n) {
  auto &m=*static_cast<Mp3State*>(p); n=std::min<uint64_t>(n,m.read_budget);
  size_t got=fread(b,1,n,m.file); m.read_budget-=got; return got;
}
drmp3_bool32 mp_seek(void *p,int off,drmp3_seek_origin whence) {
  auto &m=*static_cast<Mp3State*>(p);
  if (!m.seek_budget) return DRMP3_FALSE;
  --m.seek_budget;
  const int w=whence==DRMP3_SEEK_SET?SEEK_SET:(whence==DRMP3_SEEK_CUR?SEEK_CUR:SEEK_END);
  return fseeko(m.file,off,w)==0;
}
drmp3_bool32 mp_tell(void *p,drmp3_int64 *pos) { auto n=ftello(static_cast<Mp3State*>(p)->file); *pos=n; return n>=0; }
void *mp_malloc(size_t n,void*) { return n<=65536?std::malloc(n):nullptr; }
void *mp_realloc(void *p,size_t n,void*) { return n<=65536?std::realloc(p,n):nullptr; }
void mp_free(void *p,void*) { std::free(p); }
int mp3_open(sq_file_decoder *d,uint64_t size) {
  // Strict header-only scan: exact complete Layer III frames, constant rate and
  // channel count. No compressed-file or full-song PCM allocation. Metadata
  // Xing frame is removed by dr_mp3; its advertised duration is NOT authoritative.
  unsigned char h[128]; uint64_t offset=0,end=size;
  if (!at(d->file,0,h,10)) return SQ_FILE_INVALID_STREAM;
  if (!memcmp(h,"ID3",3)) {
    if (h[3]<2 || h[3]>4 || h[4]==255 || (h[6]|h[7]|h[8]|h[9])&128) return SQ_FILE_INVALID_STREAM;
    uint32_t n=uint32_t(h[6])<<21 | uint32_t(h[7])<<14 | uint32_t(h[8])<<7 | h[9];
    offset=10+uint64_t(n)+((h[5]&16)?10:0);
    if (offset>end) return SQ_FILE_INVALID_STREAM;
  }
  if (end>=128 && at(d->file,end-128,h,3) && !memcmp(h,"TAG",3)) end-=128;
  const uint64_t first=offset;
  uint64_t total=0; uint32_t scanned=0; unsigned char first_header[4]{};
  while (offset<end) {
    if (end-offset<4 || !at(d->file,offset,h,4) || !drmp3_hdr_valid(h) || DRMP3_HDR_GET_LAYER(h)!=1) return SQ_FILE_INVALID_STREAM;
    if (DRMP3_HDR_GET_BITRATE(h)==0) return SQ_FILE_UNSUPPORTED;
    uint32_t rate=drmp3_hdr_sample_rate_hz(h),channels=DRMP3_HDR_IS_MONO(h)?1:2;
    if (!scanned) { d->rate=rate; d->source_channels=channels; memcpy(first_header,h,4); }
    else if (d->rate!=rate || d->source_channels!=channels || !drmp3_hdr_compare(first_header,h)) return SQ_FILE_UNSUPPORTED;
    uint32_t bytes=uint32_t(drmp3_hdr_frame_bytes(h,0)+drmp3_hdr_padding(h));
    if (bytes<4 || bytes>end-offset) return SQ_FILE_INVALID_STREAM;
    total+=drmp3_hdr_frame_samples(h); offset+=bytes;
    if (++scanned>4000000) return SQ_FILE_LIMIT;
  }
  if (!scanned) return SQ_FILE_INVALID_STREAM;
  d->mp3=new(std::nothrow) Mp3State;
  if (!d->mp3) return SQ_FILE_OUT_OF_MEMORY;
  auto &m=*d->mp3; m.file=d->file;
  drmp3_allocation_callbacks alloc{nullptr,mp_malloc,mp_realloc,mp_free};
  if (fseeko(d->file,0,SEEK_SET)!=0 || !drmp3_init(&m.codec,mp_read,mp_seek,mp_tell,nullptr,&m,&alloc)) return SQ_FILE_INVALID_STREAM;
  m.initialized=true;
  if (m.codec.channels!=d->source_channels || m.codec.sampleRate!=d->rate) return SQ_FILE_INVALID_STREAM;
  if (m.codec.streamStartOffset!=first) {
    uint32_t first_bytes=uint32_t(drmp3_hdr_frame_bytes(first_header,0)+drmp3_hdr_padding(first_header));
    if (m.codec.streamStartOffset!=first+first_bytes) return SQ_FILE_INVALID_STREAM;
    total-=drmp3_hdr_frame_samples(first_header);
  }
  if (uint64_t(m.codec.delayInPCMFrames)+m.codec.paddingInPCMFrames>=total) return SQ_FILE_INVALID_STREAM;
  m.codec.totalPCMFrameCount=total;
  d->frames=static_cast<int64_t>(total-m.codec.delayInPCMFrames-m.codec.paddingInPCMFrames);
  // Each upstream seek point plus 16-frame preroll is bounded. The scanner
  // above admits the same fixed-rate complete frame sequence upstream indexes.
  // Refuse any disagreement instead of indexing a tolerated malformed stream.
  drmp3_uint64 indexed_mp3=0,indexed_pcm=0;
  if (!drmp3_get_mp3_and_pcm_frame_count(&m.codec,&indexed_mp3,&indexed_pcm) || indexed_pcm!=total) return SQ_FILE_INVALID_STREAM;
  uint64_t points=total/d->rate+1;
  if (points>65536) return SQ_FILE_LIMIT;
  m.point_count=uint32_t(points);
  if (!drmp3_calculate_seek_points(&m.codec,&m.point_count,m.points) ||
      !drmp3_bind_seek_table(&m.codec,m.point_count,m.points) || !drmp3_seek_to_pcm_frame(&m.codec,0)) return SQ_FILE_DECODE;
  return SQ_FILE_OK;
}
int mp3_window(sq_file_decoder *d,int64_t start,uint32_t count,float *out) {
  auto &m=*d->mp3; uint32_t done=0;
  // Bound tolerant-upstream fallback work too: malformed reservoirs must not
  // turn a random page read into a full-song brute-force decode.
  m.read_budget=UINT64_C(2097152); m.seek_budget=128;
  while (done<count) {
    int64_t pos=start+done;
    if (m.page_start<0 || pos<m.page_start || pos>=m.page_start+m.page_count) {
      int64_t page=(pos/16384)*16384;
      if (m.cursor!=page) {
        m.cursor=-1; m.page_start=-1;
        if (!drmp3_seek_to_pcm_frame(&m.codec,uint64_t(page))) return SQ_FILE_DECODE;
      }
      uint32_t want=uint32_t(std::min<int64_t>(16384,d->frames-page));
      uint64_t n=drmp3_read_pcm_frames_f32(&m.codec,want,m.page);
      if (n!=want) { m.page_start=-1; m.cursor=-1; return SQ_FILE_DECODE; }
      if (d->source_channels==1) for (uint32_t i=want;i>0;--i) m.page[(i-1)*2]=m.page[(i-1)*2+1]=m.page[i-1];
      m.page_start=page; m.page_count=want; m.cursor=page+want;
    }
    uint32_t at_frame=uint32_t(pos-m.page_start),n=std::min(count-done,m.page_count-at_frame);
    memcpy(out+done*2,m.page+at_frame*2,size_t(n)*8); done+=n;
  }
  return SQ_FILE_OK;
}
int wav_open(sq_file_decoder *d, uint64_t size) {
  unsigned char h[16];
  if (!at(d->file,0,h,12) || memcmp(h,"RIFF",4) || memcmp(h+8,"WAVE",4) || uint64_t(le32(h+4))+8!=size) return SQ_FILE_INVALID_STREAM;
  bool fmt=false, data=false;
  uint64_t length=0, offset=12; uint32_t chunks=0;
  while (offset<size) {
    if (++chunks>65536) return SQ_FILE_LIMIT;
    if (size-offset<8 || !at(d->file,offset,h,8)) return SQ_FILE_INVALID_STREAM;
    const uint32_t n=le32(h+4); offset+=8;
    const uint64_t padded=uint64_t(n)+(n&1U);
    if (padded>size-offset) return SQ_FILE_INVALID_STREAM;
    if (!memcmp(h,"fmt ",4)) {
      if (fmt || n<16 || !at(d->file,offset,h,16)) return SQ_FILE_INVALID_STREAM;
      fmt=true; d->format=le16(h); d->source_channels=le16(h+2); d->rate=le32(h+4); d->block=le16(h+12);
      const uint32_t bits=le16(h+14);
      if (d->source_channels<1 || d->source_channels>2 || !d->rate ||
          !((d->format==1 && bits==16) || (d->format==3 && bits==32))) return SQ_FILE_UNSUPPORTED;
      if (d->block!=d->source_channels*(bits/8) || uint64_t(d->rate)*d->block!=le32(h+8)) return SQ_FILE_INVALID_STREAM;
    } else if (!memcmp(h,"data",4)) {
      if (data) return SQ_FILE_INVALID_STREAM;
      data=true; d->data_offset=offset; length=n;
    }
    offset+=padded;
  }
  if (!fmt || !data || !length || length%d->block) return SQ_FILE_INVALID_STREAM;
  d->frames=static_cast<int64_t>(length/d->block); return SQ_FILE_OK;
}
}
extern "C" {
int sq_file_decoder_open(const char *path, uint64_t max_bytes, sq_file_decoder **out) {
  if (!out) return SQ_FILE_INVALID_ARGUMENT;
  *out=nullptr;
  if (!path || path[0]!='/' || !max_bytes || max_bytes>SQ_FILE_MAX_FILE_BYTES) return SQ_FILE_INVALID_ARGUMENT;
  int fd=open(path,O_RDONLY|O_CLOEXEC|O_NOFOLLOW|O_NONBLOCK);
  if (fd<0) return SQ_FILE_IO;
  struct stat st{};
  if (fstat(fd,&st)!=0 || !S_ISREG(st.st_mode) || st.st_size<=0) { close(fd); return SQ_FILE_IO; }
  if (uint64_t(st.st_size)>max_bytes) { close(fd); return SQ_FILE_LIMIT; }
  FILE *file=fdopen(fd,"rb"); if (!file) { close(fd); return SQ_FILE_IO; }
  auto *d=new(std::nothrow) sq_file_decoder;
  if (!d) { fclose(file); return SQ_FILE_OUT_OF_MEMORY; }
  d->file=file;
  unsigned char magic[4]{};
  int status=SQ_FILE_INVALID_STREAM;
  if (at(file,0,magic,4)) {
    if (!memcmp(magic,"RIFF",4)) status=wav_open(d,uint64_t(st.st_size));
    else if (!memcmp(magic,"OggS",4)) {
      status=sq_opus_decoder_open(path,max_bytes,&d->opus);
      if (!status) { d->rate=sq_opus_decoder_sample_rate(d->opus); d->source_channels=2; d->frames=sq_opus_decoder_frame_count(d->opus); }
    } else if (!memcmp(magic,"ID3",3) || (magic[0]==255 && (magic[1]&224)==224)) status=mp3_open(d,uint64_t(st.st_size));
  }
  if (status) { sq_file_decoder_destroy(d); return status; }
  *out=d; return SQ_FILE_OK;
}
uint32_t sq_file_decoder_sample_rate(const sq_file_decoder *d) { return d?d->rate:0; }
uint32_t sq_file_decoder_channels(const sq_file_decoder *d) { return d?2:0; }
int64_t sq_file_decoder_frame_count(const sq_file_decoder *d) { return d?d->frames:-1; }
int sq_file_decoder_read_window(sq_file_decoder *d,int64_t start,uint32_t count,float *out,size_t bytes,uint32_t *got) {
  if (!got) return SQ_FILE_INVALID_ARGUMENT;
  *got=0;
  if (!d || start<0 || start>d->frames || (count && !out)) return SQ_FILE_INVALID_ARGUMENT;
  if (count>SQ_FILE_MAX_WINDOW_FRAMES || bytes<size_t(count)*8) return SQ_FILE_LIMIT;
  uint32_t target=uint32_t(std::min<int64_t>(count,d->frames-start));
  if (!target) return SQ_FILE_OK;
  if (d->opus) return sq_opus_decoder_read_window(d->opus,start,count,out,bytes,got);
  if (d->mp3) { int status=mp3_window(d,start,target,out); if (!status) *got=target; return status; }
  unsigned char buffer[4096*8]; uint32_t done=0;
  while (done<target) {
    uint32_t n=std::min<uint32_t>(4096,target-done);
    if (!at(d->file,d->data_offset+uint64_t(start+done)*d->block,buffer,size_t(n)*d->block)) return SQ_FILE_IO;
    for (uint32_t i=0;i<n;++i) {
      float v[2];
      for (uint32_t c=0;c<d->source_channels;++c) {
        const auto *b=buffer+i*d->block+c*(d->block/d->source_channels);
        if (d->format==1) { const uint32_t u=le16(b); v[c]=float(u<32768?int32_t(u):int32_t(u)-65536)/32768.0f; }
        else { uint32_t u=le32(b); memcpy(&v[c],&u,4); if (!std::isfinite(v[c])) return SQ_FILE_DECODE; }
      }
      out[(done+i)*2]=v[0]; out[(done+i)*2+1]=v[d->source_channels-1];
    }
    done+=n;
  }
  *got=target; return SQ_FILE_OK;
}
void sq_file_decoder_destroy(sq_file_decoder *d) {
  if (!d) return;
  if (d->mp3) { if (d->mp3->initialized) drmp3_uninit(&d->mp3->codec); delete d->mp3; }
  if (d->opus) sq_opus_decoder_destroy(d->opus);
  if (d->file) fclose(d->file);
  delete d;
}
const char *sq_file_decoder_status_string(int status) {
  switch (status) {
    case SQ_FILE_OK:return "ok";
    case SQ_FILE_INVALID_ARGUMENT:return "invalid argument";
    case SQ_FILE_IO:return "local file I/O failure";
    case SQ_FILE_INVALID_STREAM:return "invalid, corrupt or truncated audio stream";
    case SQ_FILE_UNSUPPORTED:return "unsupported audio format";
    case SQ_FILE_LIMIT:return "file, structure or window limit exceeded";
    case SQ_FILE_DECODE:return "seek/decode failed or premature EOF";
    case SQ_FILE_OUT_OF_MEMORY:return "out of memory";
    default:return "unknown decoder status";
  }
}
}

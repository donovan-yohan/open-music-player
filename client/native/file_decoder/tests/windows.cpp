#include "sq_file_decoder.h"
#include <algorithm>
#include <cassert>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <random>
#include <vector>
int main(int argc,char **argv) {
  assert(argc>1); unsigned files=0,rejected=0;
  for (int arg=1;arg<argc;++arg) {
    bool reject=!std::strcmp(argv[arg],"--reject");
    if (reject) { assert(++arg<argc); }
    sq_file_decoder *d=nullptr;
    int code=sq_file_decoder_open(argv[arg],SQ_FILE_MAX_FILE_BYTES,&d);
    if (reject) { assert(code!=0 && !d); ++rejected; continue; }
    if (code) std::fprintf(stderr,"open failed %s %d\n",argv[arg],code);
    assert(code==0 && d);
    int64_t frames=sq_file_decoder_frame_count(d); assert(frames>0);
    std::vector<float> continuous;
    // Whole PCM is only the test oracle, never production storage.
    continuous.reserve(size_t(frames)*2);
    float b[48000*2+4]; uint32_t n=0;
    for (int64_t start=0;start<frames;start+=4093) {
      std::fill(std::begin(b),std::end(b),91.0f);
      assert(sq_file_decoder_read_window(d,start,4093,b,4093*8,&n)==0);
      assert(n==std::min<int64_t>(4093,frames-start));
      for (uint32_t i=n*2;i<48000*2+4;++i) assert(b[i]==91.0f);
      continuous.insert(continuous.end(),b,b+n*2);
    }
    std::mt19937 rng(179); float worst=0;
    for (unsigned i=0;i<96;++i) {
      int64_t start=i==0?frames:static_cast<int64_t>(rng()%uint64_t(frames));
      uint32_t count=i==1?48000:1+rng()%48000;
      std::fill(std::begin(b),std::end(b),91.0f);
      assert(sq_file_decoder_read_window(d,start,count,b,size_t(count)*8,&n)==0);
      assert(n==std::min<int64_t>(count,frames-start));
      for (uint32_t j=0;j<n*2;++j) { assert(std::isfinite(b[j])); worst=std::max(worst,std::abs(b[j]-continuous[size_t(start)*2+j])); }
      for (uint32_t j=n*2;j<48000*2+4;++j) assert(b[j]==91.0f);
    }
    assert(worst<=0.003f); // exact MP3/WAV checked separately by Python.
    assert(sq_file_decoder_read_window(d,0,48001,b,sizeof(b),&n)==SQ_FILE_LIMIT && n==0);
    assert(sq_file_decoder_read_window(d,frames,48000,b,0,&n)==SQ_FILE_LIMIT && n==0);
    assert(sq_file_decoder_read_window(d,frames+1,1,b,8,&n)==SQ_FILE_INVALID_ARGUMENT && n==0);
    sq_file_decoder_destroy(d); ++files;
  }
  std::printf("native window qualification PASS files=%u rejected=%u\n",files,rejected);
}

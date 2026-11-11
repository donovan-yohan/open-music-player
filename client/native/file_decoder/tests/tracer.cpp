#include "sq_file_decoder.h"
#include <cassert>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <unistd.h>
int main() {
  char name[1024];
  std::snprintf(name, sizeof(name), "%s/sq-file-tracer-%ld.wav", std::getenv("TMPDIR"), (long)getpid());
  const unsigned char wav[] = {'R','I','F','F',40,0,0,0,'W','A','V','E','f','m','t',' ',16,0,0,0,1,0,1,0,0x44,0xac,0,0,0x88,0x58,1,0,2,0,16,0,'d','a','t','a',4,0,0,0,0,0x80,0xff,0x7f};
  FILE *f = std::fopen(name,"wb"); assert(f); assert(std::fwrite(wav,1,sizeof(wav),f)==sizeof(wav)); std::fclose(f);
  sq_file_decoder *d = nullptr;
  assert(sq_file_decoder_open(name,SQ_FILE_MAX_FILE_BYTES,&d)==0 && d);
  assert(sq_file_decoder_sample_rate(d)==44100 && sq_file_decoder_channels(d)==2);
  assert(sq_file_decoder_frame_count(d)==2);
  float output[6]={9,9,9,9,9,9}; uint32_t got=0;
  assert(sq_file_decoder_read_window(d,0,2,output,16,&got)==0 && got==2);
  assert(output[0]==-1 && output[1]==-1 && output[2]==32767.0f/32768 && output[3]==output[2]);
  assert(output[4]==9 && output[5]==9);
  sq_file_decoder_destroy(d); unlink(name); std::puts("PCM WAV tracer PASS");
}

// Test codec seam only. Production processor, map and Signalsmith source.
#include "tempo_processor.hpp"
#include <cmath>
#include <iostream>
#include <vector>
#include <new>
static uint64_t totalAllocated=0;
void* operator new(std::size_t n){totalAllocated+=n;if(auto* p=std::malloc(n?n:1))return p;throw std::bad_alloc();}
void* operator new[](std::size_t n){return ::operator new(n);}
void operator delete(void* p)noexcept{std::free(p);}
void operator delete[](void* p)noexcept{std::free(p);}
using namespace soundq::nativeengine;
struct sq_file_decoder{bool failOnce=true;unsigned reads=0;};
extern "C" int sq_file_decoder_read_window(sq_file_decoder* d,int64_t,uint32_t n,float* out,size_t,uint32_t* read){
 ++d->reads;if(d->failOnce){d->failOnce=false;*read=0;return SQ_FILE_DECODE;}
 for(uint64_t i=0;i<uint64_t{n}*2;++i)out[i]=.5f;*read=n;return 0;
}
int main(){
 soundq::transport::ScheduleClip c{1,0,0,16000,0,16000,32000,16000,0,0,1};
 c.tempo={true,0,120,120,120,0,16000,0};
 TempoProcessor processor(c,32000);sq_file_decoder d;
 std::vector<float>a(tempoPageFrames*2),b(a.size());uint32_t na=0,nb=0;
 if(processor.window(&d,0,a.data(),na,b.data(),nb)!=SQ_FILE_DECODE){std::cerr<<"FAIL first decoder error must remain sticky through current DSP fill\n";return 1;}
 if(d.reads!=1){std::cerr<<"FAIL failed DSP fill must stop further decoder calls\n";return 2;}
 std::cout<<"PASS processor decoder failure remains sticky without retry\n";
 // Fresh processor supports sub-frame selected extent and an extremely short
 // selected source with finite output and explicit zero edge declick.
 c.trimIn=.25;c.trimOut=80.125;c.end=80;c.sourceFrames=16000;
 TempoProcessor shortClip(c,32000);d.failOnce=false;
 if(shortClip.window(&d,0,a.data(),na,b.data(),nb) || na!=80 || nb!=0)return 3;
 for(unsigned i=0;i<na*2;++i)if(!std::isfinite(a[i]) || std::abs(a[i])>1)return 4;
 if(a[0]!=0 || a[(na-1)*2]!=0)return 5;
 std::cout<<"PASS short fractional selection is finite, bounded and edge-declicked\n";
 for(unsigned rate:{44100U,48000U,192000U}){
  c.sourceRate=rate;c.trimIn=0;c.trimOut=rate;c.sourceFrames=rate;c.end=48000;c.tempo.end=48000;
  const auto before=totalAllocated;{TempoProcessor measured(c,48000);}
  std::cout<<"processor constructor allocation upper-sum rate="<<rate<<" bytes="<<totalAllocated-before<<'\n';
 }
}

#include "callback_host.hpp"
#include "sq_file_decoder.h"
#include <atomic>
#include <cassert>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <iostream>
#include <fstream>
#include <new>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>
using namespace soundq::nativeengine;
static thread_local bool inRender=false;static std::atomic<uint64_t> callbackNews{0};
void* operator new(std::size_t n){if(inRender)++callbackNews;if(auto* p=std::malloc(n?n:1))return p;throw std::bad_alloc();}
void* operator new[](std::size_t n){return ::operator new(n);}void operator delete(void* p)noexcept{std::free(p);}void operator delete[](void* p)noexcept{std::free(p);}
struct sq_file_decoder{bool peer;};static std::atomic<int> opens{0};
extern "C" int sq_file_decoder_open(const char* p,uint64_t,sq_file_decoder** d){*d=new sq_file_decoder{std::string(p).find("peer")!=std::string::npos};++opens;return 0;}
extern "C" uint32_t sq_file_decoder_sample_rate(const sq_file_decoder*){return 32000;}extern "C" uint32_t sq_file_decoder_channels(const sq_file_decoder*){return 2;}extern "C" int64_t sq_file_decoder_frame_count(const sq_file_decoder*){return 640000;}
extern "C" void sq_file_decoder_destroy(sq_file_decoder* d){if(d){delete d;--opens;}}
extern "C" int sq_file_decoder_read_window(sq_file_decoder* d,int64_t first,uint32_t n,float* out,size_t capacity,uint32_t* read){assert(!inRender);if(first<0 || first+n>640000 || capacity<size_t(n)*8)return SQ_FILE_INVALID_ARGUMENT;*read=n;for(unsigned j=0;j<n;++j){const double t=(first+j)/32000.;const double beat=std::fmod(t,.5);out[j*2]=d->peer?0:float(.1*std::sin(2*3.141592653589793*440*t)+(beat<.012?.06*std::exp(-beat*250):0));out[j*2+1]=d->peer?.03125f:0;}return 0;}
struct Probe:Output{uint32_t rate=32000;Callbacks* cb=nullptr;bool open(Callbacks& c,uint32_t& r)override{cb=&c;r=rate;return true;}bool start()override{return true;}bool stopClose()override{return true;}int32_t xRuns()const noexcept override{return 0;}void frame(float* pcm){inRender=true;cb->render(pcm,1);inRender=false;}};
static double field(const std::string& s,const std::string& key){auto at=s.find("\""+key+"\":");assert(at!=std::string::npos);return std::stod(s.substr(at+key.size()+3));}
template<class H> auto change(H& h,uint64_t handle,uint64_t tag,double bpm,int)->decltype(h.liveTempo(handle,1,1,tag,120,bpm,0)){return h.liveTempo(handle,1,1,tag,120,bpm,0);}
template<class H> bool change(H&,uint64_t,uint64_t,double,long){return false;}
template<class H> auto glide(H& h,uint64_t handle,uint64_t tag,double bpm,uint64_t frames,int)->decltype(h.liveTempo(handle,1,1,tag,120,bpm,frames)){return h.liveTempo(handle,1,1,tag,120,bpm,frames);}
template<class H> bool glide(H&,uint64_t,uint64_t,double,uint64_t,long){return false;}

static void fractionalRate() {
 Registry h;auto output=std::make_unique<Probe>();output->rate=44100;auto* out=output.get();const auto handle=h.open(std::move(output));assert(handle);
 assert(h.prepareScheduleV2(handle,1,{"/fake/tone","/fake/peer"},{0,0,20000,0,0,0,0,0,20000,0,0,0},{120,120,120,0,1,0,2,0,0,0,0,0,0,0,0,0}));assert(h.arrangement(handle,4,0));
 const auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(20);float pcm[2];
 while(h.state(handle).find("\"scheduleReady\":true")==std::string::npos){out->frame(pcm);assert(std::chrono::steady_clock::now()<deadline);std::this_thread::yield();}
 assert(h.arrangement(handle,1,0));bool heard=false;double previous=0;uint64_t zero=0;double adjacent=0,last=0,minEnergy=1,energy=0;unsigned hop=0;
 for(unsigned i=0;i<24000;++i){
  if(i==7000)assert(change(h,handle,10,144,0));
  if(i==7100){assert(change(h,handle,11,105,0));assert(change(h,handle,12,135,0));}
  out->frame(pcm);const auto state=h.state(handle);const double pos=field(state,"sourceFrame");assert(field(state,"globalFrame")==i+1);assert(pcm[1]==.03125f);assert(pos>previous);assert(pos-previous<1.5*32000/44100+1e-6);previous=pos;assert(state.find("\"scheduleBuffering\":false")!=std::string::npos);
  if(field(state,"tempoApplied")==12)heard=true;
  if(i>12000){zero=std::abs(pcm[0])<1e-8?zero+1:0;assert(zero<4);adjacent=std::max(adjacent,double(std::abs(pcm[0]-last)));energy+=pcm[0]*pcm[0];if(++hop==128){minEnergy=std::min(minEnergy,std::sqrt(energy/128));energy=0;hop=0;}}
  last=pcm[0];if(i%32==0)std::this_thread::sleep_for(std::chrono::microseconds(150));assert(std::chrono::steady_clock::now()<deadline);
 }
 assert(heard);assert(minEnergy>.008);assert(adjacent<.075);assert(h.close(handle));assert(opens==0);
 std::cout<<"PASS 32k source / 44.1k output, fractional continuity, supersession, exact peer, min-hop RMS="<<minEnergy<<" max-adjacent="<<adjacent<<std::endl;
}

static void runtimeEof(){
 Registry h;auto output=std::make_unique<Probe>();auto* out=output.get();const auto handle=h.open(std::move(output));assert(handle);
 assert(h.prepareSchedule(handle,1,{"/fake/tone"},{0,0,2000,0,0,0}));assert(h.arrangement(handle,4,0));float pcm[512];const auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(10);
 while(h.state(handle).find("\"scheduleReady\":true")==std::string::npos){out->frame(pcm);assert(std::chrono::steady_clock::now()<deadline);std::this_thread::yield();}assert(h.arrangement(handle,1,0));
 for(unsigned i=0;i<7000;++i){out->frame(pcm);h.state(handle);if(i%32==0)std::this_thread::sleep_for(std::chrono::microseconds(100));}
 assert(change(h,handle,10,144,0));bool heard=false;uint64_t endpoint=0;
 while(true){h.state(handle);inRender=true;out->cb->render(pcm,128);inRender=false;const auto state=h.state(handle);if(field(state,"tempoApplied")==10){heard=true;endpoint=static_cast<uint64_t>(field(state,"durationFrames"));}if(state.find("\"scheduleEnded\":true")!=std::string::npos){assert(heard);assert(field(state,"globalFrame")==endpoint);assert(field(state,"sourceFrame")==64000);break;}assert(std::chrono::steady_clock::now()<deadline);std::this_thread::sleep_for(std::chrono::microseconds(500));}
 assert(endpoint<64000 && endpoint>53000);inRender=true;out->cb->render(pcm,128);inRender=false;for(unsigned i=0;i<256;++i)assert(pcm[i]==0);assert(h.close(handle));assert(opens==0);std::cout<<"PASS revalidated runtime EOF="<<endpoint<<" original source EOF=64000 and post-EOF silence, no reinstall\n";
}

static void twoLiveOwners(){
 Registry h;auto output=std::make_unique<Probe>();auto* out=output.get();const auto handle=h.open(std::move(output));assert(handle);
 assert(h.prepareSchedule(handle,1,{"/fake/tone-a","/fake/tone-b","/fake/peer-a","/fake/peer-b"},{0,0,20000,0,0,0,0,0,20000,0,0,0,0,0,20000,0,0,0,0,0,20000,0,0,0}));assert(h.arrangement(handle,4,0));float pcm[2];const auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(15);
 while(h.state(handle).find("\"scheduleReady\":true")==std::string::npos){out->frame(pcm);assert(std::chrono::steady_clock::now()<deadline);std::this_thread::yield();}assert(h.arrangement(handle,1,0));
 bool a=false,b=false;for(unsigned i=0;i<20000;++i){if(i==4000)assert(h.liveTempo(handle,1,1,10,120,144,0));if(i==11000)assert(h.liveTempo(handle,1,2,20,120,108,0));out->frame(pcm);const auto s=h.state(handle);assert(field(s,"globalFrame")==i+1);assert(pcm[1]==.0625f);assert(s.find("\"scheduleBuffering\":false")!=std::string::npos);if(field(s,"tempoApplied")==10)a=true;if(field(s,"tempoApplied")==20)b=true;if(i%32==0)std::this_thread::sleep_for(std::chrono::microseconds(150));assert(std::chrono::steady_clock::now()<deadline);}assert(a&&b);assert(h.close(handle));assert(opens==0);std::cout<<"PASS Host two independent live-edited of four active voices, exact two-peer sum\n";
}

static void callbackBlocks(){
 Registry h;auto output=std::make_unique<Probe>();output->rate=44100;auto* out=output.get();const auto handle=h.open(std::move(output));assert(handle);
 assert(h.prepareSchedule(handle,1,{"/fake/tone","/fake/peer"},{0,0,20000,0,0,0,0,0,20000,0,0,0}));assert(h.arrangement(handle,4,0));float pcm[512];const auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(15);
 while(h.state(handle).find("\"scheduleReady\":true")==std::string::npos){out->frame(pcm);assert(std::chrono::steady_clock::now()<deadline);std::this_thread::yield();}assert(h.arrangement(handle,1,0));
 bool changed=false,reset=false;double previous=0;unsigned zero=0;double energy=0;
 for(unsigned block=0;block<180;++block){
  if(block==24)assert(h.liveTempo(handle,1,1,10,120,144,0));if(block==100)assert(h.liveTempo(handle,1,1,20,120,120,0));
  inRender=true;out->cb->render(pcm,256);inRender=false;const auto s=h.state(handle);assert(field(s,"globalFrame")==uint64_t(block+1)*256);assert(s.find("\"schedulePlaying\":true")!=std::string::npos);assert(s.find("\"scheduleBuffering\":false")!=std::string::npos);
  const double pos=field(s,"sourceFrame");assert(pos>previous && pos-previous<=256*1.2*32000/44100+1e-6);previous=pos;
  for(unsigned i=0;i<256;++i){assert(pcm[i*2+1]==.03125f);assert(std::isfinite(pcm[i*2]));if(block>10){zero=std::abs(pcm[i*2])<1e-8?zero+1:0;assert(zero<4);energy+=pcm[i*2]*pcm[i*2];}}
  changed=changed||field(s,"tempoApplied")==10;reset=reset||field(s,"tempoApplied")==20;std::this_thread::sleep_for(std::chrono::milliseconds(6));assert(std::chrono::steady_clock::now()<deadline);
 }
 assert(changed&&reset&&energy>1);assert(h.close(handle));assert(opens==0);std::cout<<"PASS real 256-frame Host blocks crossing both future handoffs, 44.1k clock, exact peer every sample, no buffering/zero hops\n";
}
int main(int argc,char** argv){
if(argc>1 && std::string(argv[1])=="--blocks"){callbackBlocks();return 0;}
if(argc>1 && std::string(argv[1])=="--four"){twoLiveOwners();return 0;}
if(argc>1 && std::string(argv[1])=="--eof"){runtimeEof();return 0;}
if(argc>1 && std::string(argv[1])=="--fractional"){fractionalRate();return 0;}
if(argc<2){twoLiveOwners();runtimeEof();fractionalRate();}
Registry h;auto output=std::make_unique<Probe>();auto* out=output.get();const auto handle=h.open(std::move(output));assert(handle);assert(h.prepareSchedule(handle,1,{"/fake/tone","/fake/peer"},{0,0,20000,0,0,0,0,0,20000,0,0,0}));assert(h.arrangement(handle,4,0));float pcm[2];const auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(20);while(h.state(handle).find("\"scheduleReady\":true")==std::string::npos){out->frame(pcm);assert(std::chrono::steady_clock::now()<deadline);std::this_thread::yield();}assert(h.arrangement(handle,1,0));
assert(!h.liveTempo(handle,2,1,1,120,144,0));assert(!h.liveTempo(handle,1,99,1,120,144,0));assert(!h.liveTempo(handle,1,1,1,120,181,0));assert(!h.liveTempo(handle,1,1,1,120,144,320001));
std::vector<float> samples;std::string state;double previous=0;bool applied=false;for(unsigned i=0;i<64000;++i){if(i==8000)assert(change(h,handle,10,144,0) && "Host missing live prepared tempo entry");out->frame(pcm);state=h.state(handle);assert(field(state,"globalFrame")==i+1);assert(state.find("\"schedulePlaying\":true")!=std::string::npos);assert(state.find("\"scheduleBuffering\":false")!=std::string::npos);assert(pcm[1]==.03125f);assert(std::isfinite(pcm[0]));const double pos=field(state,"sourceFrame");const double speed=std::abs(field(state,"effectiveBpm")-144)<1e-7?1.2:1.;
assert(std::abs((pos-previous)-speed)<1e-6);previous=pos;samples.push_back(pcm[0]);if(i>8000 && std::abs(field(state,"effectiveBpm")-144)<1e-7)applied=true;if(i%32==0)std::this_thread::sleep_for(std::chrono::microseconds(100));assert(std::chrono::steady_clock::now()<deadline);}assert(applied);
if(argc>1 && std::string(argv[1])!="--main"){std::ofstream file(argv[1],std::ios::binary);file.write(reinterpret_cast<const char*>(samples.data()),static_cast<std::streamsize>(samples.size()*sizeof(float)));assert(file.good());}
// Reversals, rollback, a glide interrupted by immediate Reset, latest-only burst.
uint64_t global=64000;double allAdjacent=0,lastSample=samples.back();uint64_t zeroRun=0;double hopEnergy=0,minHopRms=1;unsigned hopCount=0;
for(unsigned stage=0;stage<5;++stage){
    const uint64_t tag=20+stage*10;const double target=stage==0?108:stage==1?132:stage==2?120:stage==3?141:120;
    assert(glide(h,handle,tag,target,stage==1?8000:0,0));
    if(stage==3){assert(change(h,handle,tag+1,110,0));assert(change(h,handle,tag+2,141,0));}
    const uint64_t expected=stage==3?tag+2:tag;bool heard=false;
    const auto until=global+7000;
    for(;global<until;++global){out->frame(pcm);state=h.state(handle);assert(field(state,"globalFrame")==global+1);assert(state.find("\"schedulePlaying\":true")!=std::string::npos);assert(state.find("\"scheduleBuffering\":false")!=std::string::npos);assert(pcm[1]==.03125f);assert(std::isfinite(pcm[0]));
const auto newPosition=field(state,"sourceFrame");const auto heardBpm=field(state,"effectiveBpm");
assert(newPosition>previous && newPosition-previous>=.8-1e-6 && newPosition-previous<=1.5+1e-6);
if(stage!=1 && field(state,"tempoApplied")==expected)assert(std::abs(newPosition-previous-heardBpm/120)<1e-6);
hopEnergy+=pcm[0]*pcm[0];if(++hopCount==128){minHopRms=std::min(minHopRms,std::sqrt(hopEnergy/128));hopEnergy=0;hopCount=0;}
previous=newPosition;zeroRun=std::abs(pcm[0])<1e-8?zeroRun+1:0;assert(zeroRun<4);
allAdjacent=std::max(allAdjacent,double(std::abs(pcm[0]-lastSample)));lastSample=pcm[0];if(field(state,"tempoApplied")==expected)heard=true;if(global%32==0)std::this_thread::sleep_for(std::chrono::microseconds(100));assert(std::chrono::steady_clock::now()<deadline);}
    assert(heard && "latest reversal/glide/reset/rollback not actually consumed");
    std::cout<<"PASS target "<<expected<<" bpm="<<target<<" allAdjacent="<<allAdjacent<<std::endl;
}
std::vector<double> crossings;double adjacent=0,energy=0;for(size_t i=16000;i<samples.size();++i){if(samples[i-1]<=0&&samples[i]>0)crossings.push_back(i-1+double(-samples[i-1])/(samples[i]-samples[i-1]));adjacent=std::max(adjacent,double(std::abs(samples[i]-samples[i-1])));energy+=samples[i]*samples[i];}assert(crossings.size()>100);const auto hz=(crossings.size()-1)*32000/(crossings.back()-crossings.front());assert(std::abs(hz-440)<2);assert(energy>10);assert(callbackNews==0);assert(h.close(handle));assert(opens==0);assert(allAdjacent<.075);assert(minHopRms>.008);std::cout<<"PASS worst 128-frame RMS="<<minHopRms<<std::endl;std::cout<<"PASS real Host raw->prepared live 120->144, tone+attacks pitch="<<hz<<" maxAdjacent="<<adjacent<<", 99000 exact global/peer samples, zero callback new\n";}

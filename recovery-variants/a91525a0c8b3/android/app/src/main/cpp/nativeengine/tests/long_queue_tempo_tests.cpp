// Production Host, workers, processor and Engine. Only codec/output are deterministic.
#include "callback_host.hpp"
#include "soundq_transport.hpp"
#include "soundq_tempo_map.hpp"
#include "sq_file_decoder.h"
#include <atomic>
#include <cassert>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <iostream>
#include <new>
#include <string>
#include <thread>
#include <vector>
using namespace soundq::nativeengine;
namespace tr=soundq::transport;
static thread_local bool rendering=false;
static std::atomic<unsigned> callbackNews{0},decoders{0};
void* operator new(std::size_t n){if(rendering)++callbackNews;if(auto* p=std::malloc(n?n:1))return p;throw std::bad_alloc();}
void* operator new[](std::size_t n){return ::operator new(n);}
void operator delete(void* p)noexcept{std::free(p);}void operator delete[](void* p)noexcept{std::free(p);}
struct sq_file_decoder {bool peer;};
extern "C" int sq_file_decoder_open(const char* p,uint64_t,sq_file_decoder** d){assert(!rendering);*d=new sq_file_decoder{std::string(p).find("peer")!=std::string::npos};++decoders;return 0;}
extern "C" uint32_t sq_file_decoder_sample_rate(const sq_file_decoder*){return 32000;}
extern "C" uint32_t sq_file_decoder_channels(const sq_file_decoder*){return 2;}
extern "C" int64_t sq_file_decoder_frame_count(const sq_file_decoder*){return 640000;}
extern "C" void sq_file_decoder_destroy(sq_file_decoder* d){if(d){assert(!rendering);delete d;--decoders;}}
extern "C" int sq_file_decoder_read_window(sq_file_decoder* d,int64_t first,uint32_t n,float* out,size_t capacity,uint32_t* read){assert(!rendering);assert(first>=0 && first+n<=640000 && capacity>=size_t(n)*8);*read=n;for(unsigned i=0;i<n;++i){out[i*2]=d->peer?0:float(.1*std::sin((first+i)*2*3.141592653589793*440/32000));out[i*2+1]=d->peer?.03125f:0;}return 0;}
struct Probe:Output {Callbacks* cb=nullptr;bool open(Callbacks& c,uint32_t& r)override{cb=&c;r=32000;return true;}bool start()override{return true;}bool stopClose()override{return true;}int32_t xRuns()const noexcept override{return 0;}void render(float* pcm,unsigned n=256){rendering=true;cb->render(pcm,n);rendering=false;}};
static double field(const std::string& s,const std::string& key){const auto i=s.find("\""+key+"\":");assert(i!=std::string::npos);return std::stod(s.substr(i+key.size()+3));}
static std::string deck(const std::string& s,unsigned slot){auto i=s.find("\"decks\":[")+9;for(unsigned n=0;n<slot;++n)i=s.find('}',i)+2;return s.substr(i,s.find('}',i)-i+1);}
static double shape(uint64_t local,uint64_t length,uint64_t in,uint64_t out){double x=1;if(in && local<in)x=double(local)/in;if(out && length-local<out)x=std::min(x,double(length-local)/out);return std::sin(x*1.57079632679489661923);}
static void longQueue(bool reversed=false){
 Registry h;auto output=std::make_unique<Probe>();auto* out=output.get();const auto handle=h.open(std::move(output));assert(handle);
 std::vector<std::string> paths;std::vector<int64_t> values;std::vector<double> tempo;std::vector<tr::ScheduleClip> clips;
 // Ten sequential tone occurrences plus ten independent peers. Twenty logical clips,
 // two active slots, and alternating immutable banks in each slot.
 for(unsigned i=0;i<10;++i)for(unsigned peer=0;peer<2;++peer){
  const unsigned id=i*2+peer+1;paths.push_back(peer?"/fake/peer":"/fake/tone");
  const int64_t start=i*2200,trim=100+int64_t(i)*10;
  values.insert(values.end(),{start,trim,trim+2000,10,20,0});if(peer)tempo.insert(tempo.end(),8,0);else tempo.insert(tempo.end(),{120,120,120,0,1,0,2,0});
  clips.push_back({id,0,uint64_t(start*32),uint64_t((start+2000)*32),double(trim*32),double((trim+2000)*32),32000,640000,320,640,1});if(!peer)clips.back().tempo={true,0,120,120,120,0,32,0,tr::TempoOverlapPolicy::IndependentConstant};
 }
 if(reversed){std::vector<std::string> p;std::vector<tr::ScheduleClip> c;std::vector<int64_t> v;std::vector<double> t;for(int group=9;group>=0;--group)for(int peer=0;peer<2;++peer){const int i=group*2+peer;p.push_back(paths[i]);c.push_back(clips[i]);v.insert(v.end(),values.begin()+i*6,values.begin()+(i+1)*6);t.insert(t.end(),tempo.begin()+i*8,tempo.begin()+(i+1)*8);}paths=std::move(p);clips=std::move(c);values=std::move(v);tempo=std::move(t);}
 auto identity=[&](unsigned chronological){return reversed?19-chronological/2*2+chronological%2:chronological+1;};
 auto original=tr::Schedule::compile(1,32000,clips);assert(original && original->clips.size()==20);
 for(unsigned i=0;i<10;++i)assert(original->clips[identity(i*2)-1].slot!=original->clips[identity(i*2+1)-1].slot);
 assert(h.prepareScheduleV2(handle,1,paths,values,tempo));assert(h.arrangement(handle,4,0));float pcm[512];
 const auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(25);
 while(h.state(handle).find("\"scheduleReady\":true")==std::string::npos){out->render(pcm,1);assert(std::chrono::steady_clock::now()<deadline);std::this_thread::yield();}
 assert(h.arrangement(handle,1,0));bool first=false,later=false,refused=false;unsigned seen=0;double energy=0;
 const auto started=std::chrono::steady_clock::now();
 for(uint64_t global=0;global<original->duration;){
  if(global==8192){assert(h.liveTempo(handle,1,identity(0),10,120,144,0) && "safe repeated-slot live admission");}
  // Third tone reuses the first bank. Its live preparation must not adopt any
  // prior occurrence's staged processor, source law, or page window.
  if(global==78592){assert(h.liveTempo(handle,1,identity(2),15,120,138,0));}
  if(global==149248){assert(h.liveTempo(handle,1,identity(4),20,120,132,0));assert(!h.liveTempo(handle,1,identity(4),10,120,140,0));}
  // Slowing clip five (index 8) across the next same-slot start would recolor.
  if(global==290048){assert(h.liveTempo(handle,1,identity(8),30,120,96,0));}
  const auto count=static_cast<unsigned>(std::min<uint64_t>(256,original->duration-global));out->render(pcm,count);global+=count;const auto s=h.state(handle);
  if(field(s,"globalFrame")!=global){std::cerr<<"global stopped at "<<global<<" state="<<s<<std::endl;assert(false);}
  assert(s.find("\"scheduleBuffering\":false")!=std::string::npos);assert(field(s,"durationFrames")==original->duration);assert(field(s,"scheduleError")==0);
  first=first||field(s,"tempoApplied")==10;later=later||field(s,"tempoApplied")==20;refused=refused||field(s,"tempoRefused")==30;
  if(field(s,"tempoRefused")==30){if(field(s,"tempoApplied")!=20)std::cerr<<s<<std::endl;assert(field(s,"tempoApplied")==20);}
  for(unsigned n=0;n<count;++n){const uint64_t f=global-count+n;const uint64_t local=f%70400;const double peer=local<64000?.03125*shape(local,64000,320,640):0;assert(pcm[n*2+1]==static_cast<float>(peer));assert(std::isfinite(pcm[n*2]));if(local>20000 && local<30000)energy+=pcm[n*2]*pcm[n*2];}
  const uint64_t sample=global-1;const unsigned group=static_cast<unsigned>(sample/70400);const uint64_t local=sample%70400;
  if(group<10 && local<64000){seen|=1U<<group;const auto d=deck(s,original->clips[identity(group*2)-1].slot),p=deck(s,original->clips[identity(group*2+1)-1].slot);assert(field(d,"identity")==identity(group*2) && field(p,"identity")==identity(group*2+1));assert(field(p,"sourceFrame")==double((100+group*10)*32)+local+1);
   if(group>2){assert(field(d,"sourceFrame")==double((100+group*10)*32)+local+1);assert(field(d,"tempoGeneration")==0);assert(field(d,"effectiveBpm")==120);}
   else if(field(d,"tempoGeneration")){const double rate=field(d,"effectiveBpm")/120;assert(std::abs(rate-(group==0?1.2:group==1?1.15:1.1))<1e-8);}
  }
  // Pace the callback at its actual output rate; relative short sleeps can
  // coalesce into OS timer quanta or outrun sanitizer DSP preparation.
  std::this_thread::sleep_until(started+std::chrono::microseconds(global*1000000/32000));assert(std::chrono::steady_clock::now()<deadline);
 }
 assert(first && later && refused && seen==1023 && energy>1);assert(callbackNews==0);assert(h.close(handle));assert(decoders==0);
 std::cout<<"PASS 20 clips, exact peer/global/source/fades, both-bank turnover/refill, fresh later edit, atomic unsafe refusal, no callback new\n";
}
static void seekHistory(){
 Registry h;auto output=std::make_unique<Probe>();auto* out=output.get();const auto handle=h.open(std::move(output));assert(handle);
 assert(h.prepareSchedule(handle,1,{"/fake/tone","/fake/peer"},{0,100,10100,10,20,0,0,0,20000,0,0,0}));assert(h.arrangement(handle,4,0));float pcm[512];const auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(20);
 auto ready=[&]{for(unsigned n=0;;++n){out->render(pcm,1);const auto s=h.state(handle);const auto d=deck(s,0);assert(field(d,"sourceFrame")>=3200 && field(d,"sourceFrame")<=323200);assert(field(d,"nominalSourceFrame")>=3200);if(s.find("\"scheduleReady\":true")!=std::string::npos)return;assert(n<5000 && std::chrono::steady_clock::now()<deadline);std::this_thread::sleep_for(std::chrono::microseconds(200));}};
 ready();assert(h.arrangement(handle,1,0));std::vector<double> positions(1,3200),bpms(1,0);std::vector<float> audio;
 for(unsigned i=0;i<64000;++i){
  if(i==12000)assert(h.liveTempo(handle,1,1,10,120,144,0));
  if(i==24000)assert(h.liveTempo(handle,1,1,20,120,108,0));
  if(i==36000)assert(h.liveTempo(handle,1,1,30,120,132,8000));
  if(i==48000)assert(h.liveTempo(handle,1,1,40,120,120,0));
  out->render(pcm,1);const auto s=h.state(handle);assert(field(s,"globalFrame")==i+1 && pcm[1]==.03125f);positions.push_back(field(s,"sourceFrame"));bpms.push_back(field(s,"effectiveBpm"));audio.push_back(pcm[0]);
  if(i%32==0)std::this_thread::sleep_for(std::chrono::microseconds(100));
 }
 assert(field(h.state(handle),"tempoApplied")==40);
 for(uint64_t ms:{0ULL,500ULL,900ULL,1200ULL,1600ULL}){
  const auto target=ms*32;assert(h.arrangement(handle,3,ms));ready();auto s=h.state(handle);assert(field(s,"globalFrame")==target);assert(std::abs(field(s,"sourceFrame")-positions[target])<1e-6);assert(field(s,"scheduleRevision")==1);assert(h.arrangement(handle,1,0));
  for(unsigned n=0;n<2048;++n){out->render(pcm,1);s=h.state(handle);const auto f=target+n+1;assert(field(s,"globalFrame")==f);assert(std::abs(field(s,"sourceFrame")-positions[f])<1e-6);assert(field(s,"effectiveBpm")==bpms[f] || (target==0 && bpms[f]==0 && field(s,"effectiveBpm")==120));assert(pcm[1]==.03125f);assert(std::isfinite(pcm[0]));if(n%32==0)std::this_thread::sleep_for(std::chrono::microseconds(100));}
 }
 // A fresh edit after a backward seek replaces only the future law, not history.
 assert(h.arrangement(handle,3,500));ready();assert(h.arrangement(handle,1,0));assert(h.liveTempo(handle,1,1,50,120,138,0));bool heard=false;
 for(unsigned i=0;i<8000;++i){out->render(pcm,1);const auto s=h.state(handle);heard=heard||field(s,"tempoApplied")==50;assert(field(s,"sourceFrame")>=3200 && pcm[1]==.03125f);h.state(handle);if(i%32==0)std::this_thread::sleep_for(std::chrono::microseconds(100));}
 assert(heard);assert(h.arrangement(handle,3,0));ready();assert(field(h.state(handle),"sourceFrame")==3200);assert(h.arrangement(handle,1,0));assert(h.close(handle));assert(decoders==0 && callbackNews==0);
 std::cout<<"PASS applied reversals/glide/origin restore, historical backward seeks exact source law, READY/Play, fresh post-seek edit, bounded source, exact peer\n";
}
static void historyCapacity(){
 Registry h;auto output=std::make_unique<Probe>();auto* out=output.get();const auto handle=h.open(std::move(output));assert(handle);
 assert(h.prepareSchedule(handle,1,{"/fake/tone","/fake/peer"},{0,0,20000,0,0,0,0,0,20000,0,0,0}));assert(h.arrangement(handle,4,0));float pcm[512];
 const auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(25);
 while(h.state(handle).find("\"scheduleReady\":true")==std::string::npos){out->render(pcm,1);assert(std::chrono::steady_clock::now()<deadline);std::this_thread::yield();}assert(h.arrangement(handle,1,0));out->render(pcm);h.state(handle);
 for(uint64_t tag=1;tag<=64+1;++tag){
  assert(h.arrangement(handle,2,0));out->render(pcm,1);h.state(handle);
  assert(h.liveTempo(handle,1,1,tag,120,tag%2?132:120,0));
  std::this_thread::sleep_for(std::chrono::milliseconds(60));h.state(handle);assert(h.arrangement(handle,1,0));
  for(;;){out->render(pcm);const auto s=h.state(handle);assert(field(s,"sourceFrame")>=0 && field(s,"sourceFrame")<=640000);assert(s.find("\"scheduleBuffering\":false")!=std::string::npos);for(unsigned n=0;n<256;++n)assert(pcm[n*2+1]==.03125f);
   if(tag<=64 && field(s,"tempoApplied")==tag)break;
   if(tag>64 && field(s,"tempoRefused")==tag){assert(field(s,"tempoApplied")==64);break;}
   assert(std::chrono::steady_clock::now()<deadline);std::this_thread::sleep_for(std::chrono::microseconds(700));
  }
 }
 assert(h.arrangement(handle,3,0));for(;;){out->render(pcm,1);const auto s=h.state(handle);assert(field(s,"sourceFrame")==0);if(s.find("\"scheduleReady\":true")!=std::string::npos)break;assert(std::chrono::steady_clock::now()<deadline);std::this_thread::sleep_for(std::chrono::microseconds(700));}assert(h.arrangement(handle,1,0));assert(h.close(handle));assert(decoders==0 && callbackNews==0);std::cout<<"PASS 64 retained live segments, overflow terminal refusal without replacement, backward seek READY/Play\n";
}
int main(int argc,char** argv){if(argc>1 && std::string(argv[1])=="--seek")seekHistory();else if(argc>1 && std::string(argv[1])=="--capacity")historyCapacity();else longQueue(argc>1 && std::string(argv[1])=="--reverse");return 0;}

// Real source decoder + production ScheduleWorker + callback Engine PCM oracle.
#include "schedule_worker.hpp"
#include "callback_host.hpp"
#include "soundq_tempo_map.hpp"
#include <cassert>
#include <chrono>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <limits>
#include <atomic>
#include <cstdlib>
#include <new>
#include <cstddef>
static thread_local bool callbackAllocationWatch=false;
static std::atomic<uint64_t> callbackAllocations{0}, liveCppBytes{0}, peakCppBytes{0};
struct alignas(std::max_align_t) AllocationHeader{std::size_t bytes;};
void* operator new(std::size_t n){
 if(callbackAllocationWatch)++callbackAllocations;
 auto* p=static_cast<AllocationHeader*>(std::malloc(sizeof(AllocationHeader)+(n?n:1)));if(!p)throw std::bad_alloc();p->bytes=n;
 const auto live=liveCppBytes.fetch_add(n)+n;auto peak=peakCppBytes.load();while(peak<live && !peakCppBytes.compare_exchange_weak(peak,live)){}
 return p+1;
}
void* operator new[](std::size_t n){return ::operator new(n);}
void operator delete(void* p)noexcept{if(p){auto* h=static_cast<AllocationHeader*>(p)-1;liveCppBytes.fetch_sub(h->bytes);std::free(h);}}
void operator delete[](void* p)noexcept{::operator delete(p);}
using namespace soundq::nativeengine;
namespace t=soundq::transport;
struct FakeOutput final:Output {
 Callbacks* cb=nullptr;
 bool open(Callbacks& c,uint32_t& rate)override{cb=&c;rate=48000;return true;}
 bool start()override{return true;}bool stopClose()override{return true;}int32_t xRuns()const noexcept override{return 0;}
 void block(){float pcm[512]{};cb->render(pcm,256);}
};
void require(bool value,const char* message){if(!value)throw std::runtime_error(message);}
template<class F>void until(F f){auto limit=std::chrono::steady_clock::now()+std::chrono::seconds(10);while(!f()){if(std::chrono::steady_clock::now()>limit)throw std::runtime_error("worker deadline");std::this_thread::yield();}}
void hostAdmission(const std::string& path){
 Registry r;auto o=std::make_unique<FakeOutput>();auto* out=o.get();auto h=r.open(std::move(o));require(h,"host opens");
 std::vector<int64_t> v{0,0,8000,0,0,0};std::vector<double> law{120,120,100,1000,5000,0,1,0};
 auto invalid=law;invalid[7]=2;require(!r.prepareScheduleV2(h,1,{path},v,invalid),"reject unknown curve");
 invalid=law;invalid[6]=0;require(!r.prepareScheduleV2(h,1,{path},v,invalid),"reject dropped tempo fields");
 require(!r.prepareScheduleV2(h,1,{path},{0,0,8000,0,0},law),"reject V2 legacy stride");
 invalid=law;invalid[0]=std::numeric_limits<double>::quiet_NaN();require(!r.prepareScheduleV2(h,1,{path},v,invalid),"reject nonfinite tempo");
 invalid=law;invalid[2]=95;require(!r.prepareScheduleV2(h,1,{path},v,invalid),"reject unqualified rate range");
 invalid=law;invalid[5]=1e99;require(!r.prepareScheduleV2(h,1,{path},v,invalid),"reject invalid source anchor");
 require(r.prepareScheduleV2(h,1,{path},v,law),"admit actual decoded V2");
 require(r.arrangement(h,4,0),"install V2");require(!r.arrangement(h,1,0),"Play before ready refused");
 until([&]{out->block();return r.state(h).find("\"scheduleReady\":true")!=std::string::npos;});
 require(r.arrangement(h,1,0),"Play after ready admitted");out->block();
 require(r.state(h).find("\"nonSilentCallbacks\":0")==std::string::npos,"host produces PCM");
 require(!r.scratch(h,1,1,1,1,0),"preserve scratch refused");
 require(!r.sync(h,1,0,0,0,0,0,0,0,0),"preserve sync refused");
 require(r.arrangement(h,2,0),"pause");out->block();
 require(r.arrangement(h,3,6500),"seek");out->block();
 require(!r.arrangement(h,1,0),"seek requires fresh readiness");
 until([&]{out->block();return r.state(h).find("\"scheduleReady\":true")!=std::string::npos;});
 require(r.arrangement(h,1,0),"seek resumes");out->block();
 require(r.arrangement(h,5,0),"retire");out->block();
 until([&]{return r.state(h).find("\"scheduleRevision\":0")!=std::string::npos;});
 require(r.prepareScheduleV2(h,2,{path},v,law),"replacement candidate");require(r.arrangement(h,4,0),"replacement installs");out->block();
 until([&]{out->block();return r.state(h).find("\"scheduleReady\":true")!=std::string::npos;});
 require(r.close(h),"close joins workers");
 std::cout<<"PASS real Host V2 admission, readiness, pause, seek, replacement, retirement\n";
}
int main(int argc,char** argv){try{
 if(argc!=8){std::cerr<<"usage: oracle inputA inputB out target curve decks mode\n";return 2;}
 const double target=std::stod(argv[4]);const unsigned curve=std::stoul(argv[5]),count=std::stoul(argv[6]);const std::string mode=argv[7];
 if(mode=="host"){hostAdmission(argv[1]);return 0;}
 std::vector<t::ScheduleClip> clips;std::vector<std::string> paths;
 for(unsigned i=0;i<count;++i){
  const std::string path=argv[1+i%2];sq_file_decoder* d=nullptr;require(!sq_file_decoder_open(path.c_str(),SQ_FILE_MAX_FILE_BYTES,&d),"open actual input");
  const auto hz=sq_file_decoder_sample_rate(d);const auto frames=sq_file_decoder_frame_count(d);sq_file_decoder_destroy(d);
  const double bpm=i%2?100:120;
  t::ScheduleClip c{i+1,0,0,0,0,static_cast<double>(frames),hz,static_cast<uint64_t>(frames),0,0,1};
  c.tempo={true,curve,bpm,120,target,48000,240000,0};
  if(mode=="overlap") {
   if(i%2==0){c.trimOut=hz*(120.+4.*(120.+target)/2.)/120.; c.fadeOut=192000;}
   else {c.start=48000;c.fadeIn=192000;}
  }
  c.gain=1./count;clips.push_back(c);paths.push_back(path);
 }
 auto schedule=t::Schedule::compile(1,48000,clips);require(bool(schedule),"compile shared law");
 t::Engine e(48000);uint64_t sequence=0;t::Snapshot snap;
 float out[512]{};require(e.installSchedule(++sequence,schedule.get(),0),"install actual engine");e.render(out,1);e.snapshot(snap);
 std::array<std::unique_ptr<ScheduleWorker>,4> workers;
 for(unsigned i=0;i<4;++i)workers[i]=std::make_unique<ScheduleWorker>(i,*schedule,paths,e,sequence);
 auto ready=[&]{for(const auto& w:workers)if(!w->ready(snap))return false;return true;};
 until([&]{for(auto& w:workers)w->pump(snap);e.render(out,1);e.snapshot(snap);return ready();});
 require(e.scheduleTransport(++sequence,1,1,0),"play actual engine");
 std::ofstream output(argv[3],std::ios::binary);uint64_t written=0,holds=0;bool paused=false,seeked=false;auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(60);
 while(snap.globalFrame<schedule->duration){
  if(std::chrono::steady_clock::now()>deadline)throw std::runtime_error("PCM drain deadline");
  if(mode=="lifecycle" && !paused && snap.globalFrame>=96000){
   e.scheduleTransport(++sequence,1,2,0);e.render(out,256);e.snapshot(snap);auto held=snap.globalFrame;
   for(unsigned k=0;k<20;++k){for(auto& w:workers)w->pump(snap);e.render(out,256);e.snapshot(snap);require(snap.globalFrame==held,"pause clock fixed");}
   e.scheduleTransport(++sequence,1,1,0);paused=true;
  }
  if(mode=="lifecycle" && !seeked && snap.globalFrame>=144000){
   e.scheduleTransport(++sequence,1,3,288000);e.render(out,1);e.snapshot(snap);
   until([&]{for(auto& w:workers)w->pump(snap);e.render(out,1);e.snapshot(snap);return ready();});
   e.scheduleTransport(++sequence,1,1,0);seeked=true;
  }
  for(auto& w:workers)w->pump(snap);
  const auto before=snap.globalFrame;callbackAllocationWatch=true;e.render(out,256);callbackAllocationWatch=false;require(e.snapshot(snap),"snapshot");
  const auto advanced=snap.globalFrame-before;
  if(!advanced){++holds;std::this_thread::yield();continue;}
  require(advanced<=256,"bounded callback advancement");
  for(unsigned i=0;i<4;++i)if(snap.decks[i].identity){const auto& c=schedule->clips[snap.decks[i].identity-1];const auto expected=std::min(c.trimOut,t::sourceAt(c,std::max(c.start,snap.globalFrame),48000));require(std::abs(snap.decks[i].nominalSourceFrame-expected)<1e-6,"snapshot original source mapping");if(snap.globalFrame<c.end)require(std::abs(snap.decks[i].rate-t::tempoRate(c,snap.globalFrame))<1e-12,"snapshot effective rate matches accepted frame");}
  for(uint64_t i=0;i<advanced*2;++i)require(std::isfinite(out[i]) && std::abs(out[i])<=1.000001,"finite bounded output");
  output.write(reinterpret_cast<char*>(out),static_cast<std::streamsize>(advanced*8));written+=advanced;
 }
 require(callbackAllocations.load()==0,"callback C++ allocation forbidden");
 require(snap.scheduleEnded && !snap.schedulePlaying,"exact schedule EOF");
 e.render(out,256);for(auto v:out)require(v==0,"no acoustic tail beyond EOF");
 const auto peakBytes=peakCppBytes.load();
 require(e.installSchedule(++sequence,nullptr,0),"retire engine");e.render(out,1);for(auto& w:workers)w.reset();
 std::cout<<"{\"frames\":"<<written<<",\"duration\":"<<schedule->duration<<",\"starvedBlocks\":"<<holds<<",\"target\":"<<target<<",\"curve\":"<<curve<<",\"decks\":"<<count<<",\"callbackNewCalls\":"<<callbackAllocations.load()<<",\"peakCppBytes\":"<<peakBytes<<",\"mode\":\""<<mode<<"\"}\n";
 return 0;
 }catch(const std::exception& e){std::cerr<<"FAIL "<<e.what()<<'\n';return 1;}}

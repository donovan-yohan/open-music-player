#include "soundq_mix.h"
#include <cmath>
#include <cstdlib>
#include <iostream>
#include <vector>
#include <array>
#include <atomic>
#include <fstream>
#include <new>
#include <cstring>
static_assert(sizeof(sq_stem_event)>=sizeof(uint64_t)+3*sizeof(uint32_t));
static thread_local bool in_render=false;
static std::atomic<unsigned> heap_calls{0};
void* operator new(std::size_t n) { if(in_render) ++heap_calls; if(auto *p=std::malloc(n?n:1)) return p; throw std::bad_alloc(); }
void* operator new[](std::size_t n) { return ::operator new(n); }
void* operator new(std::size_t n,const std::nothrow_t&) noexcept { try { return ::operator new(n); } catch(...) { return nullptr; } }
void* operator new[](std::size_t n,const std::nothrow_t&) noexcept { return ::operator new(n,std::nothrow); }
void operator delete(void *p) noexcept { if(in_render) ++heap_calls; std::free(p); }
void operator delete[](void *p) noexcept { ::operator delete(p); }
void operator delete(void *p,std::size_t) noexcept { ::operator delete(p); }
void operator delete[](void *p,std::size_t) noexcept { ::operator delete[](p); }
void operator delete(void *p,const std::nothrow_t&) noexcept { ::operator delete(p); }
void operator delete[](void *p,const std::nothrow_t&) noexcept { ::operator delete[](p); }
static sq_result render(sq_engine *e,float *out,uint32_t n) {
  in_render=true; auto result=sq_render(e,out,n); in_render=false; return result;
}
#define CHECK(x) do { if(!(x)) { std::cerr << __LINE__ << ": " #x "\n"; std::exit(1); } } while(0)
static void oracle() {
  sq_config config{SQ_ABI_VERSION,48000,64,64};
  auto *e=sq_create(&config); CHECK(e);
  std::vector<float> pcm(128,.25f);
  sq_schedule_clip c{}; c.instance_id=1; c.asset_id=10; c.start_frame=2;
  c.end_frame=18; c.source_start_frame=4; c.source_frame_count=64;
  c.bus_count=1; c.buses[0].gain=1;
  sq_pcm_window w{}; w.asset_id=10; w.pcm.sample_rate=48000;
  w.pcm.bus_count=1; w.pcm.frame_count=64; w.pcm.buses[0]=pcm.data();
  sq_schedule_desc d{1,1,1,&c,1,&w};
  sq_stem_event events[]={{2,0,8,0},{6,0,4,1}};
  sq_clip_automation a{}; a.instance_id=1; a.base_gain=.5f;
  a.envelope_source_start_frame=4; a.envelope_frame_count=16;
  a.fade_in_frames=4; a.fade_out_frames=4; a.fade_curve=SQ_FADE_EQUAL_POWER;
  a.event_count=2; a.events=events;
  sq_schedule *s=nullptr;
  CHECK(sq_schedule_create_automated(e,&d,1,&a,&s)==SQ_OK);
  CHECK(sq_schedule_submit(e,s)==SQ_OK);
  // Descriptor lifetime ends at create; PCM remains borrowed.
  events[0].gain=1; a.base_gain=1;
  float out[40]{}; CHECK(sq_render(e,out,20)==SQ_OK);
  for(int t=0;t<20;++t) {
    double expected=0;
    if(t>=2 && t<18) {
      const int source=4+t-2;
      double stem=source<6?1.0-(source-2)/8.0:
        source<10?.5+.5*(source-6)/4.0:1;
      double fade=1;
      if(t<6) fade=std::sin((t-2)/4.0*std::acos(-1)/2);
      if(t>=14) fade=std::sin((18-t)/4.0*std::acos(-1)/2);
      expected=.25*.5*stem*fade;
    }
    CHECK(std::abs(out[t*2]-expected)<1e-7);
    CHECK(out[t*2]==out[t*2+1]);
  }
  sq_destroy(e); CHECK(sq_schedule_retire(s)==SQ_OK);
}
static void twenty_bus_wav_and_continuity(const char *path) {
  sq_config config{SQ_ABI_VERSION,48000,32,256};
  auto *edited=sq_create(&config), *baseline=sq_create(&config); CHECK(edited && baseline);
  std::array<std::array<std::vector<float>,5>,4> pcm;
  sq_schedule_clip clips[5]{}; sq_pcm_window windows[4]{};
  sq_clip_automation automation[5]{}; sq_stem_event events[4][10]{};
  for(unsigned d=0;d<4;++d) {
    auto& c=clips[d]; c.instance_id=d+1; c.asset_id=d+1; c.start_frame=3+d;
    c.end_frame=123+d; c.source_start_frame=8+d; c.source_frame_count=256; c.bus_count=5;
    auto& w=windows[d]; w.asset_id=d+1; w.pcm.sample_rate=48000; w.pcm.bus_count=5; w.pcm.frame_count=256;
    auto& a=automation[d]; a.instance_id=c.instance_id; a.base_gain=.5;
    a.envelope_source_start_frame=c.source_start_frame; a.envelope_frame_count=120;
    a.fade_in_frames=16; a.fade_out_frames=24; a.fade_curve=d%2;
    a.event_count=10; a.events=events[d];
    for(unsigned b=0;b<5;++b) {
      auto& p=pcm[d][b]; p.resize(512);
      for(unsigned f=0;f<256;++f) {
        p[2*f]=static_cast<float>((static_cast<int>((f+3*d+7*b)%31)-15)*static_cast<int>(b+1)/2048.0);
        p[2*f+1]=-p[2*f]*.5f;
      }
      w.pcm.buses[b]=p.data(); c.buses[b].gain=1;
      events[d][b]={12,b,24,.25f}; events[d][b+5]={20,b,16,.5f};
    }
  }
  // Future metadata uses a distinct cursor for the same immutable asset.
  clips[4]=clips[0]; clips[4].instance_id=5; clips[4].start_frame=150; clips[4].end_frame=160;
  automation[4]=automation[0]; automation[4].instance_id=5;
  std::vector<sq_schedule*> handles;
  auto install=[&](sq_engine *e,uint64_t revision) {
    sq_schedule_desc desc{revision,.25f,5,clips,4,windows}; sq_schedule *s=nullptr;
    CHECK(sq_schedule_create_automated(e,&desc,5,automation,&s)==SQ_OK);
    CHECK(sq_schedule_submit(e,s)==SQ_OK); handles.push_back(s);
  };
  install(edited,1); install(baseline,1);
  std::vector<float> output(280),control(280);
  for(unsigned t=0;t<140;) {
    if(t==8) { // live ramp, then unrelated future edit while ramp is in flight
      clips[0].buses[0].gain=.5; clips[0].buses[0].ramp_frames=16;
      install(edited,2); install(baseline,2);
    }
    if(t==12) { clips[4].start_frame=180; clips[4].end_frame=190; install(edited,3); }
    const unsigned n=(t==0?8:t==8?4:std::min(13u,140-t));
    CHECK(render(edited,output.data()+2*t,n)==SQ_OK);
    // A different block partition must not change authored curves.
    for(unsigned f=0;f<n;++f) CHECK(render(baseline,control.data()+2*(t+f),1)==SQ_OK);
    t+=n;
  }
  for(unsigned t=0;t<140;++t) {
    double expected[2]{};
    for(unsigned d=0;d<4;++d) {
      const unsigned start=3+d;
      if(t<start || t>=123+d) continue;
      const unsigned local=t-start, source=8+d+local;
      double shaped=local<16?local/16.0:local>=96?(120-local)/24.0:1;
      if(d%2) shaped=std::sin(shaped*std::acos(-1)/2);
      const double stem=source<12?1:source<20?1-.75*(source-12)/24.0:
        source<36?.75-.25*(source-20)/16.0:.5;
      for(unsigned b=0;b<5;++b) {
        const double live=d==0 && b==0 && t>=8?1-.5*std::min(t-7,16u)/16.0:1;
        for(unsigned ch=0;ch<2;++ch) expected[ch]+=pcm[d][b][2*source+ch]*stem*shaped*.5*live*.25;
      }
    }
    for(unsigned ch=0;ch<2;++ch) {
      CHECK(std::abs(output[2*t+ch]-expected[ch])<1e-8);
      CHECK(output[2*t+ch]==control[2*t+ch]);
    }
  }
  if(path) {
    std::ofstream wav(path,std::ios::binary); CHECK(wav);
    auto u16=[&](uint16_t x) { wav.put(static_cast<char>(x));wav.put(static_cast<char>(x>>8)); };
    auto u32=[&](uint32_t x) { u16(x&65535);u16(x>>16); };
    wav.write("RIFF",4);u32(36+140*8);wav.write("WAVEfmt ",8);u32(16);u16(3);u16(2);
    u32(48000);u32(48000*8);u16(8);u16(32);wav.write("data",4);u32(140*8);
    for(float f:output) { uint32_t bits; static_assert(sizeof bits==sizeof f); std::memcpy(&bits,&f,4);u32(bits); }
    CHECK(wav.good());
  }
  sq_destroy(edited);sq_destroy(baseline);
  for(auto *s:handles)CHECK(sq_schedule_retire(s)==SQ_OK);
  CHECK(heap_calls==0);
}
static void validation_and_queue_fences() {
  sq_config config{SQ_ABI_VERSION,48000,128,4096}; auto *e=sq_create(&config);CHECK(e);
  sq_schedule_clip c{};c.instance_id=1;c.asset_id=1;c.end_frame=4096;c.source_frame_count=4096;
  c.bus_count=1;c.buses[0].gain=1;
  sq_schedule_desc d{1,1,1,&c,0,nullptr};sq_clip_automation a{};
  a.instance_id=1;a.base_gain=1;a.envelope_frame_count=4096;
  std::vector<sq_stem_event> events;for(unsigned i=0;i<65;++i)events.push_back({i,0,8,0});
  a.event_count=65;a.events=events.data(); sq_schedule *s=nullptr;
  CHECK(sq_schedule_create_automated(e,&d,1,&a,&s)==SQ_INVALID);CHECK(!s);
  a.event_count=1;
  auto reject=[&]() { CHECK(sq_schedule_create_automated(e,&d,1,&a,&s)==SQ_INVALID);CHECK(!s); };
  events[0].gain=std::nanf("");reject(); events[0].gain=0;
  a.stem_override_mask=2;reject();a.stem_override_mask=0;
  a.base_gain=1.1;reject();a.base_gain=1;
  a.fade_in_frames=4096;a.fade_out_frames=1;reject();a.fade_in_frames=0;a.fade_out_frames=0;
  a.envelope_source_start_frame=UINT64_MAX;reject();a.envelope_source_start_frame=0;
  a.event_count=2049;reject();a.event_count=1;
  std::vector<sq_schedule*> handles;
  for(unsigned i=1;i<=9;++i) {
    d.revision=i;CHECK(sq_schedule_create_automated(e,&d,1,&a,&s)==SQ_OK);handles.push_back(s);
    CHECK(sq_schedule_submit(e,s)==(i==9?SQ_QUEUE_FULL:SQ_OK));
  }
  CHECK(sq_applied_revision(e)==0);
  float out[2];CHECK(render(e,out,1)==SQ_OK);CHECK(sq_applied_revision(e)==8);
  for(unsigned i=0;i<7;++i)CHECK(sq_schedule_get_state(handles[i])==SQ_SCHEDULE_COMPLETE);
  CHECK(sq_schedule_submit(e,handles.back())==SQ_OK);CHECK(render(e,out,1)==SQ_OK);
  CHECK(sq_missing_pcm_frames(e)==2);CHECK(sq_last_missing_instance(e)==1);
  sq_destroy(e);for(auto *h:handles)CHECK(sq_schedule_retire(h)==SQ_OK);
}
int main(int argc,char **argv) {
  oracle(); twenty_bus_wav_and_continuity(argc>1?argv[1]:nullptr);validation_and_queue_fences();
  CHECK(heap_calls==0);std::cout << "automation: 3 native scenarios, 20-bus every-sample oracle, zero C++ render heap calls\n";
}

#include "soundq_mix.h"
#include <atomic>
#include <cmath>
#include <cstdlib>
#include <iostream>
#include <memory>
#include <new>
#include <thread>
#include <chrono>
#include <limits>
#include <vector>

static thread_local bool render_guard=false;
static std::atomic<uint64_t> heap_calls{0};
void* operator new(std::size_t n) {
  if(render_guard) ++heap_calls;
  if(void *p=std::malloc(n?n:1)) return p;
  throw std::bad_alloc();
}
void* operator new[](std::size_t n) { return ::operator new(n); }
void* operator new(std::size_t n,const std::nothrow_t&) noexcept { try { return ::operator new(n); } catch(...) { return nullptr; } }
void* operator new[](std::size_t n,const std::nothrow_t&) noexcept { return ::operator new(n,std::nothrow); }
void operator delete(void *p) noexcept { if(render_guard) ++heap_calls; std::free(p); }
void operator delete[](void *p) noexcept { ::operator delete(p); }
void operator delete(void *p,std::size_t) noexcept { ::operator delete(p); }
void operator delete[](void *p,std::size_t) noexcept { ::operator delete[](p); }
void operator delete(void *p,const std::nothrow_t&) noexcept { ::operator delete(p); }
void operator delete[](void *p,const std::nothrow_t&) noexcept { ::operator delete[](p); }
#define CHECK(x) do { if(!(x)) { std::cerr << __func__ << ":" << __LINE__ << ": " #x "\n"; std::exit(1); } } while(0)
static void near(float a,float b) { CHECK(std::abs(a-b)<0.000002f); }
using Engine=std::unique_ptr<sq_engine,decltype(&sq_destroy)>;
static Engine engine(uint32_t block=64,uint64_t asset=480000) {
  sq_config c{SQ_ABI_VERSION,48000,block,asset};
  Engine e(sq_create(&c),sq_destroy); CHECK(e); return e;
}
static sq_schedule_clip clip(uint64_t id,uint64_t start,uint64_t end,uint64_t extent=32) {
  sq_schedule_clip c{}; c.instance_id=id; c.asset_id=1;
  c.start_frame=start; c.end_frame=end; c.source_frame_count=extent;
  c.bus_count=1; c.buses[0].gain=1; return c;
}
static sq_pcm_window window(const std::vector<float>& pcm,uint64_t asset=1,uint64_t origin=0) {
  sq_pcm_window w{}; w.asset_id=asset; w.source_start_frame=origin;
  w.pcm={}; w.pcm.sample_rate=48000; w.pcm.bus_count=1;
  w.pcm.frame_count=pcm.size()/2; w.pcm.buses[0]=pcm.data(); return w;
}
static sq_schedule_desc desc(const std::vector<sq_schedule_clip>& clips,
                             const std::vector<sq_pcm_window>& windows,uint64_t revision=1) {
  return {revision,1,static_cast<uint32_t>(clips.size()),clips.data(),
          static_cast<uint32_t>(windows.size()),windows.data()};
}
static sq_schedule* create(sq_engine *e,const sq_schedule_desc& d) {
  sq_schedule *s=nullptr; CHECK(sq_schedule_create(e,&d,&s)==SQ_OK); CHECK(s); return s;
}
static void render(sq_engine *e,float *out,uint32_t frames) {
  render_guard=true; const auto r=sq_render(e,out,frames); render_guard=false;
  CHECK(r==SQ_OK); CHECK(heap_calls.load()==0);
}
static void exact_future_starts_without_any_producer_replenishment() {
  auto e=engine(); std::vector<float> pcm={.1f,-.1f,.2f,-.2f,.3f,-.3f,.4f,-.4f};
  std::vector<sq_schedule_clip> clips;
  for(uint64_t i=0;i<12;++i) clips.push_back(clip(i+1,3+i*11,7+i*11,4));
  std::vector<sq_pcm_window> windows={window(pcm)};
  auto d=desc(clips,windows); auto *s=create(e.get(),d);
  CHECK(sq_schedule_get_state(s)==SQ_SCHEDULE_READY);
  CHECK(sq_schedule_submit(e.get(),s)==SQ_OK);
  CHECK(sq_schedule_retire(s)==SQ_BUSY);
  CHECK(sq_applied_revision(e.get())==0);
  // Destroy/mutate caller descriptors: native schedule is a copied immutable value.
  clips.clear(); windows.clear(); d.clip_count=0;
  uint64_t cursor=0; float out[34]{};
  while(cursor<144) {
    const uint32_t n=static_cast<uint32_t>(std::min<uint64_t>(17,144-cursor));
    render(e.get(),out,n);
    for(uint32_t f=0;f<n;++f) {
      const auto t=cursor+f;
      const auto relative=t>=3?(t-3)%11:10;
      const float expected=t>=3 && (t-3)/11<12 && relative<4?pcm[relative*2]:0;
      near(out[f*2],expected); near(out[f*2+1],-expected);
    }
    cursor+=n;
  }
  CHECK(sq_applied_revision(e.get())==1); CHECK(sq_missing_pcm_frames(e.get())==0);
  CHECK(sq_schedule_retire(s)==SQ_BUSY); // clip EOF is not a release fence
  sq_plan empty{}; empty.revision=2; empty.master_gain=1;
  CHECK(sq_submit(e.get(),&empty)==SQ_OK); CHECK(sq_schedule_retire(s)==SQ_BUSY);
  render(e.get(),out,1); CHECK(sq_schedule_get_state(s)==SQ_SCHEDULE_COMPLETE);
  CHECK(sq_schedule_retire(s)==SQ_OK);
}
static void full_arrangement_capacity_validation_is_atomic() {
  auto e=engine(); std::vector<float> pcm(64,.125f);
  std::vector<sq_schedule_clip> clips;
  for(uint64_t i=0;i<8;++i) clips.push_back(clip(i+1,i*32,(i+1)*32));
  std::vector<sq_pcm_window> windows={window(pcm)};
  auto d=desc(clips,windows); auto *s=create(e.get(),d);
  CHECK(sq_schedule_submit(e.get(),s)==SQ_OK);
  std::vector<sq_schedule_clip> five;
  for(uint64_t i=0;i<5;++i) five.push_back(clip(i+1,500,520));
  auto bad=desc(five,windows,2); sq_schedule *rejected=s;
  CHECK(sq_schedule_create(e.get(),&bad,&rejected)==SQ_INVALID); CHECK(!rejected);
  float out[16]{}; render(e.get(),out,8);
  for(float x:out) near(x,.125f);
  CHECK(sq_applied_revision(e.get())==1);
  // Half-open endpoint: four ending as four begin is legal, not eight overlaps.
  five.clear();
  for(uint64_t i=0;i<8;++i) five.push_back(clip(i+1,i<4?0:32,i<4?32:64));
  bad=desc(five,windows,2); auto *legal=create(e.get(),bad);
  CHECK(sq_schedule_submit(e.get(),legal)==SQ_OK); render(e.get(),out,1);
  near(out[0],.5f); CHECK(sq_applied_revision(e.get())==2);
  CHECK(sq_schedule_retire(s)==SQ_OK);
  e.reset(); CHECK(sq_schedule_retire(legal)==SQ_OK);
}
static void missing_windows_silence_only_the_unprepared_clip() {
  auto e=engine(); std::vector<float> a(8,.2f),b(8,.4f),healthy(64,.1f);
  std::vector<sq_schedule_clip> clips={clip(1,0,32),clip(2,0,32)};
  clips[1].asset_id=2;
  std::vector<sq_pcm_window> windows={window(a),window(b,1,12),window(healthy,2)};
  auto *s=create(e.get(),desc(clips,windows)); CHECK(sq_schedule_submit(e.get(),s)==SQ_OK);
  float out[64]{}; render(e.get(),out,32);
  for(uint32_t f=0;f<32;++f) near(out[f*2],.1f+(f<4?.2f:(f>=12&&f<16?.4f:0)));
  CHECK(sq_missing_pcm_frames(e.get())==24); CHECK(sq_last_missing_instance(e.get())==1);
  e.reset(); CHECK(sq_schedule_retire(s)==SQ_OK);
}
static void revisions_preserve_unaffected_cursor_and_inflight_gain_ramp() {
  auto edited=engine(), baseline=engine(); std::vector<float> pcm(256);
  for(size_t f=0;f<pcm.size()/2;++f) pcm[2*f]=pcm[2*f+1]=static_cast<float>(f+1)/256;
  std::vector<sq_schedule_clip> clips={clip(1,0,120,128),clip(2,80,90,128)};
  clips[1].source_start_frame=20;
  std::vector<sq_pcm_window> windows={window(pcm)};
  std::vector<sq_schedule*> handles;
  auto install=[&](sq_engine *e,uint64_t rev) {
    auto *s=create(e,desc(clips,windows,rev)); handles.push_back(s);
    CHECK(sq_schedule_submit(e,s)==SQ_OK);
  };
  float a[64]{},b[64]{};
  install(edited.get(),1); install(baseline.get(),1);
  render(edited.get(),a,3); render(baseline.get(),b,3);
  clips[0].buses[0].gain=0; clips[0].buses[0].ramp_frames=20;
  install(edited.get(),2); install(baseline.get(),2);
  render(edited.get(),a,5); render(baseline.get(),b,5);
  clips[1].start_frame=48; clips[1].end_frame=58;
  // Reorder metadata too: runtime slots must follow identity, not array order.
  std::swap(clips[0],clips[1]); install(edited.get(),3);
  render(edited.get(),a,24); render(baseline.get(),b,24);
  for(uint32_t f=0;f<24;++f) {
    CHECK(a[2*f]==b[2*f]); CHECK(a[2*f+1]==b[2*f+1]);
    const auto elapsed=8+f;
    const auto ramp=elapsed<22?static_cast<float>(22-elapsed)/20:0;
    near(a[2*f],pcm[elapsed*2]*ramp);
  }
  render(edited.get(),a,32); render(baseline.get(),b,32);
  for(uint32_t f=0;f<32;++f) {
    const uint64_t t=32+f;
    near(a[2*f],t>=48&&t<58?pcm[2*(20+t-48)]:0);
    near(b[2*f],0);
  }
  edited.reset(); baseline.reset(); for(auto *s:handles) CHECK(sq_schedule_retire(s)==SQ_OK);
}
static void validation_rejects_malformed_metadata_and_bounded_residency() {
  auto e=engine(); std::vector<float> pcm(64,.25f);
  std::vector<sq_schedule_clip> clips={clip(1,0,32)};
  std::vector<sq_pcm_window> windows={window(pcm)};
  auto reject=[&](const sq_schedule_desc& d) {
    sq_schedule *s=reinterpret_cast<sq_schedule*>(1);
    CHECK(sq_schedule_create(e.get(),&d,&s)==SQ_INVALID); CHECK(!s);
  };
  auto bad=clips; bad.push_back(bad[0]); reject(desc(bad,windows));
  bad=clips; bad[0].asset_id=0; reject(desc(bad,windows));
  bad=clips; bad[0].instance_id=0; reject(desc(bad,windows));
  bad=clips; bad[0].start_frame=32; reject(desc(bad,windows));
  bad=clips; bad[0].source_start_frame=1; reject(desc(bad,windows));
  bad=clips; bad[0].source_frame_count=0; reject(desc(bad,windows));
  bad=clips; bad[0].source_start_frame=UINT64_MAX; reject(desc(bad,windows));
  bad=clips; bad[0].bus_count=6; reject(desc(bad,windows));
  bad=clips; bad[0].buses[0].gain=NAN; reject(desc(bad,windows));
  bad=clips; bad[0].buses[0].gain=1.01f; reject(desc(bad,windows));
  bad=clips; bad[0].buses[0].muted=2; reject(desc(bad,windows));
  bad=clips; bad.push_back(clip(2,32,64,64)); reject(desc(bad,windows)); // asset extent mismatch
  auto wbad=windows; wbad[0].pcm.buses[0]=nullptr; reject(desc(clips,wbad));
  wbad=windows; wbad[0].pcm.sample_rate=44100; reject(desc(clips,wbad));
  wbad=windows; wbad[0].pcm.bus_count=2; reject(desc(clips,wbad));
  wbad=windows; wbad[0].pcm.frame_count=480001; reject(desc(clips,wbad));
  wbad=windows; wbad[0].source_start_frame=1; reject(desc(clips,wbad));
  wbad=windows; wbad.push_back(wbad[0]); reject(desc(clips,wbad));
  wbad=windows; wbad[0].asset_id=2; reject(desc(clips,wbad));
  auto d=desc(clips,windows); d.master_gain=INFINITY; reject(d);
  d=desc(clips,windows); d.revision=0; reject(d);
  d=desc(clips,windows); d.clip_count=SQ_SCHEDULE_MAX_CLIPS+1; reject(d);
  d=desc(clips,windows); d.window_count=SQ_SCHEDULE_MAX_WINDOWS+1; reject(d);
  d=desc(clips,windows); d.clips=nullptr; reject(d);
  d=desc(clips,windows); d.windows=nullptr; reject(d);
  // Repeated pointers are still charged for each resident window descriptor.
  bad.clear(); wbad.clear();
  for(uint64_t i=0;i<3;++i) {
    auto c=clip(i+1,i*480000,(i+1)*480000,480000); c.asset_id=i+1; bad.push_back(c);
    auto w=window(pcm,i+1); w.pcm.frame_count=480000; wbad.push_back(w);
  }
  reject(desc(bad,wbad)); // no sample reads during off-callback validation
  CHECK(sq_schedule_create(e.get(),nullptr,nullptr)==SQ_INVALID);
  CHECK(sq_schedule_retire(nullptr)==SQ_INVALID);
  CHECK(sq_missing_pcm_frames(nullptr)==0); CHECK(sq_last_missing_instance(nullptr)==0);
}
static void dense_schedule_is_rejected_before_any_revision_is_accepted() {
  auto e=engine(64); std::vector<sq_schedule_clip> clips;
  std::vector<sq_pcm_window> windows;
  for(uint64_t i=0;i<40;++i) clips.push_back(clip(i+1,i*2,i*2+1,1));
  sq_schedule *s=nullptr; auto d=desc(clips,windows);
  // 65 boundaries in [0,64) is impossible for integer frames; use a longer
  // render bound so this deliberately pathological one-frame edit is rejected.
  auto dense_engine=engine(128);
  CHECK(sq_schedule_create(dense_engine.get(),&d,&s)==SQ_INVALID); CHECK(!s);
  // Exactly the documented 64 boundaries is accepted, not a smaller hidden cap.
  clips.resize(32); d=desc(clips,windows);
  auto *at_limit=create(dense_engine.get(),d); CHECK(sq_schedule_retire(at_limit)==SQ_OK);
  // The SAME revision remains legal after rejection; no hidden partial install.
  clips={clip(1,0,10,10)}; d=desc(clips,windows);
  s=create(dense_engine.get(),d); CHECK(sq_schedule_submit(dense_engine.get(),s)==SQ_OK);
  float out[2]{}; render(dense_engine.get(),out,1);
  CHECK(sq_applied_revision(dense_engine.get())==1);
  dense_engine.reset(); CHECK(sq_schedule_retire(s)==SQ_OK);
}
static void queue_lifetime_and_legacy_schedule_switching_share_one_owner() {
  auto e=engine(), other=engine(); std::vector<float> pcm(128,.25f);
  std::vector<sq_schedule_clip> clips={clip(1,0,64,64)};
  std::vector<sq_pcm_window> windows={window(pcm)}; std::vector<sq_schedule*> handles;
  for(uint64_t rev=1;rev<=9;++rev) handles.push_back(create(e.get(),desc(clips,windows,rev)));
  CHECK(sq_schedule_submit(other.get(),handles[0])==SQ_INVALID);
  for(size_t i=0;i<8;++i) CHECK(sq_schedule_submit(e.get(),handles[i])==SQ_OK);
  CHECK(sq_schedule_submit(e.get(),handles[8])==SQ_QUEUE_FULL);
  CHECK(sq_schedule_get_state(handles[8])==SQ_SCHEDULE_READY);
  float out[4]={.8f,.8f,.8f,.8f};
  CHECK(sq_render(e.get(),out,0)==SQ_INVALID); CHECK(sq_applied_revision(e.get())==0);
  for(size_t i=0;i<8;++i) CHECK(sq_schedule_retire(handles[i])==SQ_BUSY);
  render(e.get(),out,1); near(out[0],.25f); CHECK(sq_applied_revision(e.get())==8);
  for(size_t i=0;i<7;++i) CHECK(sq_schedule_retire(handles[i])==SQ_OK);
  CHECK(sq_schedule_retire(handles[7])==SQ_BUSY);
  CHECK(sq_schedule_submit(e.get(),handles[8])==SQ_OK);
  auto *stale=create(e.get(),desc(clips,windows,8));
  CHECK(sq_schedule_submit(e.get(),stale)==SQ_STALE_REVISION);
  CHECK(sq_schedule_retire(stale)==SQ_OK);
  sq_plan empty{}; empty.revision=10; empty.master_gain=1;
  CHECK(sq_submit(e.get(),&empty)==SQ_OK); // skips revision 9 in this block
  CHECK(sq_schedule_retire(handles[8])==SQ_BUSY);
  render(e.get(),out,2); near(out[0],0); CHECK(sq_applied_revision(e.get())==10);
  CHECK(sq_schedule_retire(handles[7])==SQ_OK); CHECK(sq_schedule_retire(handles[8])==SQ_OK);
  auto *ready=create(e.get(),desc(clips,windows,11));
  auto *queued=create(e.get(),desc(clips,windows,12)); CHECK(sq_schedule_submit(e.get(),queued)==SQ_OK);
  e.reset(); CHECK(sq_schedule_retire(ready)==SQ_OK); CHECK(sq_schedule_retire(queued)==SQ_OK);
}
static void hour_of_metadata_uses_one_small_nonlooping_pcm_fixture() {
  constexpr uint64_t hour=uint64_t{48000}*60*60;
  constexpr uint64_t spacing=hour/1000;
  auto e=engine(65536); std::vector<float> pcm(64);
  for(size_t i=0;i<32;++i) { pcm[2*i]=static_cast<float>(i+1)/100; pcm[2*i+1]=-pcm[2*i]; }
  std::vector<sq_schedule_clip> clips;
  for(uint64_t i=0;i<1000;++i) clips.push_back(clip(i+1,5+i*spacing,37+i*spacing));
  std::vector<sq_pcm_window> windows={window(pcm)};
  const auto began=std::chrono::steady_clock::now();
  auto *s=create(e.get(),desc(clips,windows)); CHECK(sq_schedule_submit(e.get(),s)==SQ_OK);
  const auto compiled=std::chrono::steady_clock::now();
  std::vector<float> out(2*65536);
  uint64_t frame=0,nonzero=0;
  while(frame<hour) {
    const uint32_t n=static_cast<uint32_t>(std::min<uint64_t>(65536,hour-frame));
    render(e.get(),out.data(),n);
    for(uint32_t f=0;f<n;++f) {
      const auto t=frame+f;
      const auto source=t>=5?(t-5)%spacing:spacing;
      const bool audible=t>=5 && (t-5)/spacing<1000 && source<32;
      const float expected=audible?pcm[2*source]:0;
      // Exact independent interval oracle, including every silent frame.
      CHECK(out[2*f]==expected); CHECK(out[2*f+1]==-expected);
      if(audible) ++nonzero;
    }
    frame+=n;
  }
  CHECK(nonzero==uint64_t{1000}*32); CHECK(sq_rendered_frames(e.get())==hour);
  CHECK(sq_missing_pcm_frames(e.get())==0); CHECK(sq_applied_revision(e.get())==1);
  e.reset(); CHECK(sq_schedule_retire(s)==SQ_OK);
  std::cout << "HOUR frames=" << hour << " clips=1000 resident_frames=32 nonzero_frames=" << nonzero
            << " compile_and_enqueue_us=" << std::chrono::duration_cast<std::chrono::microseconds>(compiled-began).count()
            << " render_and_oracle_ms=" << std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now()-compiled).count() << "\n";
}
static void rolling_pcm_revisions_do_not_reset_inflight_ramps() {
  auto e=engine(); std::vector<float> first(16,.4f),next(16,.4f);
  std::vector<sq_schedule_clip> clips={clip(1,0,24,24)};
  std::vector<sq_pcm_window> windows={window(first)};
  std::vector<sq_schedule*> handles;
  auto install=[&](uint64_t rev) { auto *s=create(e.get(),desc(clips,windows,rev)); handles.push_back(s); CHECK(sq_schedule_submit(e.get(),s)==SQ_OK); };
  float out[32]{}; install(1); render(e.get(),out,2);
  clips[0].buses[0].gain=0; clips[0].buses[0].ramp_frames=12;
  install(2); render(e.get(),out,4);
  windows={window(next,1,8)}; install(3);
  render(e.get(),out,10);
  for(uint32_t f=0;f<10;++f) {
    const auto t=6+f;
    const float expected=t>=8&&t<14?.4f*static_cast<float>(13-t)/12:0;
    near(out[2*f],expected);
  }
  CHECK(sq_missing_pcm_frames(e.get())==2);
  e.reset(); for(auto *s:handles) CHECK(sq_schedule_retire(s)==SQ_OK);
}
static void four_decks_twenty_buses_and_block_partition_are_exact() {
  auto a=engine(),b=engine(); std::vector<float> pcm(128,.1f);
  std::vector<sq_schedule_clip> clips;
  std::vector<sq_pcm_window> windows;
  for(uint64_t i=0;i<4;++i) {
    auto c=clip(i+1,3,35,64); c.bus_count=5;
    for(auto& control:c.buses) control.gain=1;
    clips.push_back(c);
  }
  auto w=window(pcm); w.pcm.bus_count=5;
  for(auto& p:w.pcm.buses) p=pcm.data();
  windows.push_back(w);
  auto d=desc(clips,windows); d.master_gain=.25f;
  auto *sa=create(a.get(),d),*sb=create(b.get(),d);
  CHECK(sq_schedule_submit(a.get(),sa)==SQ_OK); CHECK(sq_schedule_submit(b.get(),sb)==SQ_OK);
  float x[80]{},y[80]{}; render(a.get(),x,40);
  render(b.get(),y,5); render(b.get(),y+10,11); render(b.get(),y+32,24);
  for(uint32_t f=0;f<40;++f) {
    CHECK(x[2*f]==y[2*f]); CHECK(x[2*f+1]==y[2*f+1]); near(x[2*f],f>=3&&f<35?.5f:0);
  }
  a.reset(); b.reset(); CHECK(sq_schedule_retire(sa)==SQ_OK); CHECK(sq_schedule_retire(sb)==SQ_OK);
}
static void concurrent_install_and_completion_retirement_never_tear_blocks() {
  auto e=engine(); std::vector<float> pcm(800000,.25f);
  std::vector<sq_schedule_clip> clips={clip(1,0,400000,400000)};
  std::vector<sq_pcm_window> windows={window(pcm)};
  std::atomic<bool> done{false};
  std::thread producer([&] {
    std::vector<sq_schedule*> pending;
    for(uint64_t rev=1;rev<=500;++rev) {
      auto d=desc(clips,windows,rev); d.master_gain=rev%2?1.f:.5f;
      auto *s=create(e.get(),d);
      sq_result status;
      do { status=sq_schedule_submit(e.get(),s); if(status==SQ_QUEUE_FULL) std::this_thread::yield(); } while(status==SQ_QUEUE_FULL);
      CHECK(status==SQ_OK); pending.push_back(s);
      for(auto it=pending.begin();it!=pending.end();) {
        if(sq_schedule_get_state(*it)==SQ_SCHEDULE_COMPLETE) {
          CHECK(sq_schedule_retire(*it)==SQ_OK); it=pending.erase(it);
        } else ++it;
      }
    }
    sq_plan stop{}; stop.revision=501; stop.master_gain=1;
    sq_result status;
    do { status=sq_submit(e.get(),&stop); if(status==SQ_QUEUE_FULL) std::this_thread::yield(); } while(status==SQ_QUEUE_FULL);
    CHECK(status==SQ_OK);
    for(auto *s:pending) {
      while(sq_schedule_get_state(s)!=SQ_SCHEDULE_COMPLETE) std::this_thread::yield();
      CHECK(sq_schedule_retire(s)==SQ_OK);
    }
    done.store(true,std::memory_order_release);
  });
  float out[128]{}; uint64_t last=0;
  while(!done.load(std::memory_order_acquire)) {
    render(e.get(),out,64);
    const auto rev=sq_applied_revision(e.get()); CHECK(rev>=last); last=rev;
    if(sq_rendered_frames(e.get())<=400000 && rev>0 && rev<501) {
      CHECK(out[0]==.25f || out[0]==.125f);
      for(float x:out) CHECK(x==out[0]);
    }
    for(float x:out) CHECK(std::isfinite(x) && x>=0 && x<=.25f);
    std::this_thread::yield();
  }
  producer.join(); CHECK(sq_applied_revision(e.get())==501);
}
#define RUN(test) do { test(); std::cout << "PASS " #test "\n"; } while(0)
int main() {
  RUN(exact_future_starts_without_any_producer_replenishment);
  RUN(full_arrangement_capacity_validation_is_atomic);
  RUN(missing_windows_silence_only_the_unprepared_clip);
  RUN(revisions_preserve_unaffected_cursor_and_inflight_gain_ramp);
  RUN(validation_rejects_malformed_metadata_and_bounded_residency);
  RUN(dense_schedule_is_rejected_before_any_revision_is_accepted);
  RUN(queue_lifetime_and_legacy_schedule_switching_share_one_owner);
  RUN(rolling_pcm_revisions_do_not_reset_inflight_ramps);
  RUN(four_decks_twenty_buses_and_block_partition_are_exact);
  RUN(concurrent_install_and_completion_retirement_never_tear_blocks);
  RUN(hour_of_metadata_uses_one_small_nonlooping_pcm_fixture);
}

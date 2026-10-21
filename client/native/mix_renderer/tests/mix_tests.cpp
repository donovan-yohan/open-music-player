#include "soundq_mix.h"
#include <cmath>
#include <cstdlib>
#include <iostream>
#include <memory>
#include <limits>
#include <vector>
#include <atomic>
#include <array>
#include <thread>
#include <new>

static thread_local bool render_guard=false;
static std::atomic<uint64_t> guarded_heap_calls{0};
void* operator new(std::size_t n) {
  if(render_guard) ++guarded_heap_calls;
  if(void *p=std::malloc(n?n:1)) return p;
  throw std::bad_alloc();
}
void* operator new[](std::size_t n) { return ::operator new(n); }
void operator delete(void *p) noexcept { if(render_guard) ++guarded_heap_calls; std::free(p); }
void operator delete[](void *p) noexcept { ::operator delete(p); }

#define CHECK(x) do { if (!(x)) { std::cerr << __func__ << ":" << __LINE__ << ": " #x "\n"; std::exit(1); } } while (0)
static void near(float a, float b) { CHECK(std::abs(a-b) < 0.000002f); }
using Engine = std::unique_ptr<sq_engine, decltype(&sq_destroy)>;
static Engine engine(uint32_t max_block=64) {
  sq_config c{SQ_ABI_VERSION,48000,max_block,480000};
  Engine e(sq_create(&c), sq_destroy); CHECK(e); return e;
}
static sq_deck deck(const std::vector<float>& pcm, uint32_t slot=0, uint32_t buses=1) {
  sq_deck d{}; d.slot=slot; d.instance_id=slot+1;
  d.pcm.sample_rate=48000; d.pcm.bus_count=buses; d.pcm.frame_count=pcm.size()/2;
  d.end_frame=pcm.size()/2;
  for (uint32_t b=0;b<buses;++b) { d.pcm.buses[b]=pcm.data(); d.buses[b].gain=1; }
  return d;
}
[[maybe_unused]] static sq_plan plan(const sq_deck& d, uint64_t revision=1) {
  sq_plan p{}; p.revision=revision; p.deck_count=1; p.master_gain=1; p.decks[0]=d; return p;
}
static void four_decks_twenty_correlated_buses_share_start_and_end() {
  auto e=engine(); std::vector<float> input(32,0); input[8]=1; input[9]=-.5f;
  sq_plan p{}; p.revision=1; p.deck_count=4; p.master_gain=.05f;
  for (uint32_t i=0;i<4;++i) { p.decks[i]=deck(input,i,5); p.decks[i].start_frame=3; p.decks[i].end_frame=10; }
  CHECK(sq_submit(e.get(),&p)==SQ_OK); CHECK(sq_applied_revision(e.get())==0);
  float a[10], b[14]; for (float& x:a) x=.25f; for (float& x:b) x=.25f;
  CHECK(sq_render(e.get(),a,5)==SQ_OK); CHECK(sq_render(e.get(),b,7)==SQ_OK);
  for (uint32_t i=0;i<5;++i) { near(a[2*i],0); near(a[2*i+1],0); }
  for (uint32_t i=0;i<7;++i) { near(b[2*i],i==2?1.f:0.f); near(b[2*i+1],i==2?-.5f:0.f); }
  CHECK(sq_rendered_frames(e.get())==12); CHECK(sq_applied_revision(e.get())==1);
}
static void malformed_plans_do_not_drop_accepted_state() {
  auto e=engine(); std::vector<float> input(64,.125f); auto p=plan(deck(input));
  CHECK(sq_submit(e.get(),&p)==SQ_OK);
  auto reject=[&](sq_plan bad) { bad.revision=2; CHECK(sq_submit(e.get(),&bad)==SQ_INVALID); };
  auto bad=p; bad.deck_count=5; reject(bad);
  bad=p; bad.deck_count=2; bad.decks[1]=bad.decks[0]; reject(bad);
  bad=p; bad.decks[0].slot=4; reject(bad);
  bad=p; bad.decks[0].instance_id=0; reject(bad);
  bad=p; bad.decks[0].pcm.bus_count=6; reject(bad);
  bad=p; bad.decks[0].pcm.bus_count=0; reject(bad);
  bad=p; bad.decks[0].pcm.buses[0]=nullptr; reject(bad);
  bad=p; bad.decks[0].pcm.sample_rate=44100; reject(bad);
  bad=p; bad.decks[0].pcm.frame_count=480001; reject(bad);
  bad=p; bad.decks[0].pcm.frame_count=0; reject(bad);
  bad=p; bad.decks[0].end_frame=0; reject(bad);
  bad=p; bad.decks[0].source_start_frame=32; reject(bad);
  bad=p; bad.decks[0].has_seek=2; reject(bad);
  bad=p; bad.decks[0].has_seek=1; bad.decks[0].seek_frame=32; reject(bad);
  bad=p; bad.decks[0].has_seek=1; bad.decks[0].seek_source_frame=32; reject(bad);
  bad=p; bad.decks[0].buses[0].muted=2; reject(bad);
  bad=p; bad.decks[0].buses[0].gain=-.01f; reject(bad);
  bad=p; bad.decks[0].buses[0].gain=1.01f; reject(bad);
  bad=p; bad.decks[0].buses[0].gain=std::nanf(""); reject(bad);
  bad=p; bad.master_gain=std::numeric_limits<float>::infinity(); reject(bad);
  bad=p; bad.master_gain=-1; reject(bad);
  bad=p; bad.master_gain=1.01f; reject(bad);
  CHECK(sq_submit(e.get(),nullptr)==SQ_INVALID); CHECK(sq_submit(nullptr,&p)==SQ_INVALID);
  CHECK(sq_submit(e.get(),&p)==SQ_STALE_REVISION);
  p.revision=0; CHECK(sq_submit(e.get(),&p)==SQ_STALE_REVISION);
  float out[8]{}; CHECK(sq_render(e.get(),out,4)==SQ_OK);
  for(float x:out) near(x,.125f);
  CHECK(sq_applied_revision(e.get())==1);
  p.revision=2; CHECK(sq_submit(e.get(),&p)==SQ_OK);
  CHECK(sq_render(e.get(),out,4)==SQ_OK); CHECK(sq_applied_revision(e.get())==2);
}
static void bounded_queue_backpressure_preserves_revision_and_copies_plan() {
  auto e=engine(); std::vector<float> input(32,.5f); auto p=plan(deck(input));
  for(uint64_t r=1;r<=SQ_QUEUE_CAPACITY;++r) { p.revision=r; CHECK(sq_submit(e.get(),&p)==SQ_OK); }
  p.revision=SQ_QUEUE_CAPACITY+1; p.master_gain=0;
  CHECK(sq_submit(e.get(),&p)==SQ_QUEUE_FULL); CHECK(sq_applied_revision(e.get())==0);
  float out[2]{}; CHECK(sq_render(e.get(),out,1)==SQ_OK); near(out[0],.5f);
  CHECK(sq_applied_revision(e.get())==SQ_QUEUE_CAPACITY);
  CHECK(sq_submit(e.get(),&p)==SQ_OK); p.master_gain=1; p.decks[0].pcm.buses[0]=nullptr;
  CHECK(sq_render(e.get(),out,1)==SQ_OK); near(out[0],0);
  CHECK(sq_applied_revision(e.get())==SQ_QUEUE_CAPACITY+1);
}
static void exact_seek_and_half_open_stop_align_all_twenty_buses() {
  auto e=engine(); std::vector<float> input(24,0); input[4]=1; input[5]=-.25f;
  sq_plan p{}; p.revision=1; p.master_gain=.05f; p.deck_count=4;
  for(uint32_t i=0;i<4;++i) {
    p.decks[i]=deck(input,i,5); auto& d=p.decks[i];
    d.start_frame=1; d.source_start_frame=1; d.end_frame=9;
    d.has_seek=1; d.seek_frame=6; d.seek_source_frame=1;
  }
  CHECK(sq_submit(e.get(),&p)==SQ_OK);
  float out[24]{}; CHECK(sq_render(e.get(),out,12)==SQ_OK);
  for(uint32_t i=0;i<12;++i) { near(out[2*i],i==2||i==7?1.f:0.f); near(out[2*i+1],i==2||i==7?-.25f:0.f); }
  auto e2=engine(); std::vector<float> constant(8,.4f); auto d=deck(constant);
  d.start_frame=2; d.end_frame=5; p=plan(d); CHECK(sq_submit(e2.get(),&p)==SQ_OK);
  CHECK(sq_render(e2.get(),out,8)==SQ_OK);
  for(uint32_t i=0;i<8;++i) near(out[2*i],i>=2&&i<5?.4f:0.f);
  auto e3=engine(); d=deck(constant); d.end_frame=12; p=plan(d);
  CHECK(sq_submit(e3.get(),&p)==SQ_OK); CHECK(sq_render(e3.get(),out,8)==SQ_OK);
  for(uint32_t i=0;i<8;++i) near(out[2*i],i<4?.4f:0.f);
}
static void live_mute_gain_ramps_survive_future_placement_edits() {
  auto e=engine(); std::vector<float> input(128,1); auto p=plan(deck(input));
  p.master_gain=.5f; CHECK(sq_submit(e.get(),&p)==SQ_OK);
  float out[16]{}; CHECK(sq_render(e.get(),out,2)==SQ_OK); near(out[0],.5f);
  p.revision=2; p.decks[0].buses[0].muted=1; p.decks[0].buses[0].ramp_frames=4;
  CHECK(sq_submit(e.get(),&p)==SQ_OK); CHECK(sq_render(e.get(),out,2)==SQ_OK);
  near(out[0],.375f); near(out[2],.25f);
  p.revision=3; p.deck_count=2; p.decks[1]=deck(input,1); p.decks[1].start_frame=50; p.decks[1].end_frame=60;
  CHECK(sq_submit(e.get(),&p)==SQ_OK); CHECK(sq_render(e.get(),out,2)==SQ_OK);
  near(out[0],.125f); near(out[2],0);
  p.revision=4; p.decks[0].buses[0].gain=.8f; p.decks[0].buses[0].muted=0;
  CHECK(sq_submit(e.get(),&p)==SQ_OK); CHECK(sq_render(e.get(),out,2)==SQ_OK);
  near(out[0],.1f); near(out[2],.2f);
  p.revision=5; p.decks[0].buses[0].gain=0; p.decks[0].buses[0].ramp_frames=2;
  CHECK(sq_submit(e.get(),&p)==SQ_OK); CHECK(sq_render(e.get(),out,3)==SQ_OK);
  near(out[0],.1f); near(out[2],0); near(out[4],0);
  p.revision=6; p.decks[0].buses[0].gain=1; p.decks[0].buses[0].ramp_frames=0;
  CHECK(sq_submit(e.get(),&p)==SQ_OK); CHECK(sq_render(e.get(),out,1)==SQ_OK); near(out[0],.5f);
}
static void future_drag_does_not_restart_unaffected_source_cursor() {
  auto e=engine(); std::vector<float> sequence(64), future(64,.1f);
  for(uint32_t i=0;i<32;++i) sequence[2*i]=sequence[2*i+1]=static_cast<float>(i)/100;
  auto p=plan(deck(sequence)); p.deck_count=2; p.decks[1]=deck(future,1);
  p.decks[1].start_frame=20; p.decks[1].end_frame=25;
  CHECK(sq_submit(e.get(),&p)==SQ_OK); float out[16]{}; CHECK(sq_render(e.get(),out,4)==SQ_OK);
  p.revision=2; p.decks[1].start_frame=8; p.decks[1].end_frame=12;
  CHECK(sq_submit(e.get(),&p)==SQ_OK); CHECK(sq_render(e.get(),out,8)==SQ_OK);
  for(uint32_t i=0;i<8;++i) near(out[2*i],static_cast<float>(i+4)/100+(i>=4?.1f:0.f));
  CHECK(sq_rendered_frames(e.get())==12);
}
static void invalid_config_and_render_leave_all_state_unchanged() {
  CHECK(sq_create(nullptr)==nullptr);
  sq_config c{SQ_ABI_VERSION,48000,64,480000};
  auto invalid=[&](sq_config bad) { auto *e=sq_create(&bad); CHECK(e==nullptr); };
  auto bad=c; bad.abi_version=2; invalid(bad);
  bad=c; bad.sample_rate=0; invalid(bad);
  bad=c; bad.max_block_frames=0; invalid(bad);
  bad=c; bad.max_block_frames=65537; invalid(bad);
  bad=c; bad.max_asset_frames=0; invalid(bad);
  bad=c; bad.max_asset_frames=UINT64_MAX; invalid(bad);
  auto e=engine(); std::vector<float> input(32,.2f); auto p=plan(deck(input));
  CHECK(sq_submit(e.get(),&p)==SQ_OK);
  float out[132]; for(float& x:out) x=.123f;
  CHECK(sq_render(e.get(),out,0)==SQ_INVALID); CHECK(sq_render(e.get(),out,65)==SQ_INVALID);
  CHECK(sq_render(e.get(),nullptr,1)==SQ_INVALID); CHECK(sq_render(nullptr,out,1)==SQ_INVALID);
  CHECK(sq_rendered_frames(e.get())==0); CHECK(sq_applied_revision(e.get())==0);
  for(float x:out) near(x,.123f);
  CHECK(sq_render(e.get(),out,1)==SQ_OK); near(out[0],.2f); CHECK(sq_applied_revision(e.get())==1);
  sq_destroy(nullptr); CHECK(sq_rendered_frames(nullptr)==0); CHECK(sq_applied_revision(nullptr)==0);
}
static void nonfinite_samples_are_silence_with_fixed_headroom_then_clip() {
  auto e=engine(); std::vector<float> input={std::nanf(""),.5f, INFINITY,-INFINITY,2,-2,.5f,-.5f};
  auto p=plan(deck(input)); p.master_gain=.5f;
  CHECK(sq_submit(e.get(),&p)==SQ_OK); float out[8]{}; CHECK(sq_render(e.get(),out,4)==SQ_OK);
  const float expected[]={0,.25f,0,0,1,-1,.25f,-.25f};
  for(uint32_t i=0;i<8;++i) { CHECK(std::isfinite(out[i])); near(out[i],expected[i]); }
  auto e2=engine(); std::vector<float> huge(8,std::numeric_limits<float>::max());
  p={}; p.revision=1; p.deck_count=4; p.master_gain=1;
  for(uint32_t i=0;i<4;++i) p.decks[i]=deck(huge,i,5);
  CHECK(sq_submit(e2.get(),&p)==SQ_OK); CHECK(sq_render(e2.get(),out,1)==SQ_OK); near(out[0],1);
  p.revision=2; p.master_gain=0; CHECK(sq_submit(e2.get(),&p)==SQ_OK);
  CHECK(sq_render(e2.get(),out,1)==SQ_OK); near(out[0],0);
}
static void block_partition_is_invariant_and_render_does_not_use_cpp_heap() {
  auto a=engine(), b=engine(); std::vector<float> input(128,.5f); auto p=plan(deck(input));
  CHECK(sq_submit(a.get(),&p)==SQ_OK); CHECK(sq_submit(b.get(),&p)==SQ_OK);
  float x[32]{}, y[32]{}; CHECK(sq_render(a.get(),x,1)==SQ_OK); CHECK(sq_render(b.get(),y,1)==SQ_OK);
  p.revision=2; p.decks[0].buses[0].gain=0; p.decks[0].buses[0].ramp_frames=11;
  CHECK(sq_submit(a.get(),&p)==SQ_OK); CHECK(sq_submit(b.get(),&p)==SQ_OK);
  render_guard=true;
  const auto one=sq_render(a.get(),x,16);
  const auto two=sq_render(b.get(),y,3);
  const auto three=sq_render(b.get(),y+6,5);
  const auto four=sq_render(b.get(),y+16,8);
  render_guard=false;
  CHECK(one==SQ_OK && two==SQ_OK && three==SQ_OK && four==SQ_OK);
  CHECK(guarded_heap_calls.load()==0);
  for(uint32_t i=0;i<32;++i) near(x[i],y[i]);
}
static void spsc_revision_updates_never_tear_render_blocks() {
  auto e=engine(); std::vector<float> input(960000,.25f); auto p=plan(deck(input));
  CHECK(sq_submit(e.get(),&p)==SQ_OK);
  std::atomic<bool> done{false};
  std::thread producer([&] {
    for(uint64_t revision=2;revision<=2000;++revision) {
      p.revision=revision; p.master_gain=(revision%2)?1.f:.5f;
      sq_result status;
      do { status=sq_submit(e.get(),&p); if(status==SQ_QUEUE_FULL) std::this_thread::yield(); } while(status==SQ_QUEUE_FULL);
      CHECK(status==SQ_OK);
    }
    done.store(true,std::memory_order_release);
  });
  float out[128]{}; uint64_t last=0;
  for(uint32_t blocks=0;blocks<7000;++blocks) {
    CHECK(sq_render(e.get(),out,64)==SQ_OK);
    CHECK(out[0]==.25f || out[0]==.125f);
    for(float sample:out) near(sample,out[0]);
    const auto revision=sq_applied_revision(e.get()); CHECK(revision>=last); last=revision;
    if(done.load(std::memory_order_acquire) && revision==2000) break;
    CHECK(blocks<6999); std::this_thread::yield();
  }
  producer.join(); CHECK(sq_applied_revision(e.get())==2000);
}
static void independent_bus_controls_stop_and_release_after_empty_revision() {
  auto e=engine(); std::array<std::vector<float>,20> pcm;
  sq_plan p{}; p.revision=1; p.deck_count=4; p.master_gain=.05f;
  double expected=0;
  for(uint32_t d=0;d<4;++d) {
    for(uint32_t b=0;b<5;++b) pcm[d*5+b]=std::vector<float>(128,static_cast<float>(b+1)/10);
    p.decks[d]=deck(pcm[d*5],d,5);
    for(uint32_t b=0;b<5;++b) {
      p.decks[d].pcm.buses[b]=pcm[d*5+b].data(); p.decks[d].buses[b].gain=.5f;
      p.decks[d].buses[b].muted=b%2;
      if(!(b%2)) expected+=(static_cast<float>(b+1)/10)*.5;
    }
  }
  CHECK(sq_submit(e.get(),&p)==SQ_OK); float out[8]{};
  render_guard=true; const auto status=sq_render(e.get(),out,4); render_guard=false;
  CHECK(status==SQ_OK); CHECK(guarded_heap_calls.load()==0);
  for(float x:out) near(x,static_cast<float>(expected*.05));
  p.revision=2; p.deck_count=0; CHECK(sq_submit(e.get(),&p)==SQ_OK);
  CHECK(sq_render(e.get(),out,1)==SQ_OK); CHECK(sq_applied_revision(e.get())==2);
  for(auto& bus:pcm) { std::vector<float> empty; bus.swap(empty); }
  CHECK(sq_render(e.get(),out,4)==SQ_OK); for(float x:out) near(x,0);
  CHECK(sq_rendered_frames(e.get())==9);
}
#define RUN(test) do { test(); std::cout << "PASS " #test "\n"; } while (0)
int main() {
  RUN(four_decks_twenty_correlated_buses_share_start_and_end);
  RUN(malformed_plans_do_not_drop_accepted_state);
  RUN(bounded_queue_backpressure_preserves_revision_and_copies_plan);
  RUN(exact_seek_and_half_open_stop_align_all_twenty_buses);
  RUN(live_mute_gain_ramps_survive_future_placement_edits);
  RUN(future_drag_does_not_restart_unaffected_source_cursor);
  RUN(invalid_config_and_render_leave_all_state_unchanged);
  RUN(nonfinite_samples_are_silence_with_fixed_headroom_then_clip);
  RUN(block_partition_is_invariant_and_render_does_not_use_cpp_heap);
  RUN(spsc_revision_updates_never_tear_render_blocks);
  RUN(independent_bus_controls_stop_and_release_after_empty_revision);
}

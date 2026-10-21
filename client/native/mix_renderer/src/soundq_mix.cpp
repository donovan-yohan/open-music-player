#include "soundq_mix.h"
#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <limits>
#include <map>
#include <memory>
#include <new>
#include <set>
#include <vector>

static_assert(std::atomic<uint64_t>::is_always_lock_free, "Requires lock-free 64-bit atomics");
static_assert(std::atomic<uint32_t>::is_always_lock_free, "Requires lock-free status atomics");
struct GainRamp {
  double value=0, target=0, step=0;
  uint32_t remaining=0;
};
struct SpanEntry { uint32_t clip=0, window=UINT32_MAX; };
struct ScheduleSpan {
  uint64_t frame=0;
  uint32_t count=0;
  SpanEntry entries[SQ_MAX_DECKS]{};
};
struct AuthoredKnot {
  uint64_t frame=0;
  uint32_t ramp=0;
  double from=1, target=1;
};
struct AuthoredClip {
  sq_clip_automation envelope{};
  std::vector<AuthoredKnot> buses[SQ_MAX_BUSES];
};
static double knot_gain(const AuthoredKnot& k,uint64_t frame) {
  if(!k.ramp || frame-k.frame>=k.ramp) return k.target;
  return k.from+(k.target-k.from)*(static_cast<double>(frame-k.frame)/k.ramp);
}
struct sq_schedule {
  sq_engine *owner=nullptr;
  sq_schedule *previous=nullptr, *next=nullptr; // producer-only registry
  std::atomic<uint32_t> state{SQ_SCHEDULE_READY};
  uint64_t revision=0;
  float master_gain=0;
  std::vector<sq_schedule_clip> clips;
  std::vector<sq_pcm_window> windows;
  std::vector<ScheduleSpan> spans;
  std::vector<AuthoredClip> automation;
};
struct Submission { sq_plan plan{}; sq_schedule *schedule=nullptr; };
struct sq_engine {
  sq_config config;
  Submission queue[SQ_QUEUE_CAPACITY]{};
  std::atomic<uint64_t> write{0}, read{0}, applied{0}, cursor{0};
  std::atomic<uint64_t> missing{0}, last_missing{0};
  uint64_t accepted=0;
  sq_plan current{};
  GainRamp gains[SQ_MAX_DECKS][SQ_MAX_BUSES]{};
  uint64_t asset_ids[SQ_MAX_DECKS]{}; // zero denotes legacy snapshot identity
  sq_schedule *schedule=nullptr, *handles=nullptr;
  size_t span=0;
  uint32_t clip_indices[SQ_MAX_DECKS]{};
  size_t knot_indices[SQ_MAX_DECKS][SQ_MAX_BUSES]{}; // next knot, binary-seeked on install
};
static bool same_asset(const sq_deck& a, const sq_deck& b) {
  if(a.instance_id!=b.instance_id || a.pcm.bus_count!=b.pcm.bus_count || a.pcm.frame_count!=b.pcm.frame_count) return false;
  for(uint32_t bus=0;bus<a.pcm.bus_count;++bus) if(a.pcm.buses[bus]!=b.pcm.buses[bus]) return false;
  return true;
}
static void target_gain(GainRamp& r, const sq_bus_control& control, bool preserve) {
  const double target=control.muted?0:control.gain;
  if(!preserve) r={target,target,0,0};
  else if(r.target!=target) {
    r.target=target; r.remaining=control.ramp_frames;
    r.step=r.remaining?(target-r.value)/r.remaining:0;
    if(!r.remaining) r.value=target;
  }
}
static void apply(sq_engine *e, const sq_plan& next) {
  for(uint32_t i=0;i<next.deck_count;++i) {
    const auto& d=next.decks[i];
    const sq_deck *old=nullptr;
    for(uint32_t j=0;j<e->current.deck_count;++j)
      if(e->current.decks[j].slot==d.slot) old=&e->current.decks[j];
    for(uint32_t bus=0;bus<d.pcm.bus_count;++bus)
      target_gain(e->gains[d.slot][bus],d.buses[bus],old && same_asset(*old,d));
  }
  e->current=next;
  std::fill(std::begin(e->asset_ids),std::end(e->asset_ids),0);
}
// The span compiler resolves residency off callback. This bounded reconciliation
// feeds the SAME four-deck runtime and sample loop as the legacy snapshot ABI.
static void apply_span(sq_engine *e, const ScheduleSpan& span,uint64_t frame) {
  sq_plan next{}; next.revision=e->schedule->revision;
  next.master_gain=e->schedule->master_gain; next.deck_count=span.count;
  GainRamp gains[SQ_MAX_DECKS][SQ_MAX_BUSES]{};
  uint64_t assets[SQ_MAX_DECKS]{};
  int old_slots[SQ_MAX_DECKS]={-1,-1,-1,-1};
  uint32_t used=0;
  for(uint32_t i=0;i<span.count;++i) {
    const auto& c=e->schedule->clips[span.entries[i].clip];
    for(uint32_t j=0;j<e->current.deck_count;++j) {
      const auto& old=e->current.decks[j];
      if(old.instance_id==c.instance_id && e->asset_ids[old.slot]==c.asset_id && old.pcm.bus_count==c.bus_count) {
        old_slots[i]=static_cast<int>(old.slot); used|=1u<<old.slot; break;
      }
    }
  }
  for(uint32_t i=0;i<span.count;++i) {
    const auto& entry=span.entries[i]; const auto& c=e->schedule->clips[entry.clip];
    auto& d=next.decks[i];
    if(old_slots[i]>=0) d.slot=static_cast<uint32_t>(old_slots[i]);
    else { while(used&(1u<<d.slot)) ++d.slot; used|=1u<<d.slot; }
    d.instance_id=c.instance_id; d.start_frame=c.start_frame; d.end_frame=c.end_frame;
    d.pcm.bus_count=c.bus_count; d.pcm.sample_rate=e->config.sample_rate;
    if(entry.window!=UINT32_MAX) {
      const auto& w=e->schedule->windows[entry.window];
      d.pcm=w.pcm;
      // The descriptor's mapping is anchored to this span; source extent and
      // residency intersection were checked without overflow at compile time.
      d.start_frame=span.frame;
      d.source_start_frame=c.source_start_frame+(span.frame-c.start_frame)-w.source_start_frame;
    }
    for(uint32_t b=0;b<c.bus_count;++b) {
      d.buses[b]=c.buses[b];
      auto& r=gains[d.slot][b];
      if(old_slots[i]>=0) r=e->gains[d.slot][b];
      target_gain(r,c.buses[b],old_slots[i]>=0);
    }
    assets[d.slot]=c.asset_id;
    e->clip_indices[d.slot]=entry.clip;
    if(!e->schedule->automation.empty()) {
      const auto source=c.source_start_frame+(frame-c.start_frame);
      const auto& a=e->schedule->automation[entry.clip];
      for(uint32_t b=0;b<c.bus_count;++b) {
        const auto& knots=a.buses[b];
        e->knot_indices[d.slot][b]=static_cast<size_t>(std::upper_bound(knots.begin(),knots.end(),source,
          [](uint64_t f,const AuthoredKnot& k) { return f<k.frame; })-knots.begin());
      }
    }
  }
  e->current=next;
  for(uint32_t slot=0;slot<SQ_MAX_DECKS;++slot)
    std::copy(std::begin(gains[slot]),std::end(gains[slot]),std::begin(e->gains[slot]));
  std::copy(std::begin(assets),std::end(assets),std::begin(e->asset_ids));
}
static void install_schedule(sq_engine *e,sq_schedule *s,uint64_t frame) {
  e->schedule=s;
  const auto it=std::upper_bound(s->spans.begin(),s->spans.end(),frame,
    [](uint64_t t,const ScheduleSpan& span) { return t<span.frame; });
  e->span=static_cast<size_t>(it-s->spans.begin()-1);
  apply_span(e,s->spans[e->span],frame);
}
static bool valid_gain(float g) { return std::isfinite(g) && g>=0 && g<=1; }
static bool valid_plan(const sq_engine *e, const sq_plan& p) {
  if(p.deck_count>SQ_MAX_DECKS || !valid_gain(p.master_gain)) return false;
  uint32_t slots=0;
  for(uint32_t i=0;i<p.deck_count;++i) {
    const auto& d=p.decks[i];
    if(d.slot>=SQ_MAX_DECKS || (slots&(1u<<d.slot)) || !d.instance_id) return false;
    slots|=1u<<d.slot;
    if(d.pcm.sample_rate!=e->config.sample_rate || !d.pcm.bus_count || d.pcm.bus_count>SQ_MAX_BUSES ||
       !d.pcm.frame_count || d.pcm.frame_count>e->config.max_asset_frames ||
       d.start_frame>=d.end_frame || d.source_start_frame>=d.pcm.frame_count || d.has_seek>1) return false;
    if(d.has_seek && (d.seek_frame<d.start_frame || d.seek_frame>=d.end_frame || d.seek_source_frame>=d.pcm.frame_count)) return false;
    for(uint32_t b=0;b<d.pcm.bus_count;++b)
      if(!d.pcm.buses[b] || !valid_gain(d.buses[b].gain) || d.buses[b].muted>1) return false;
  }
  return true;
}
struct ClipEvent { uint64_t frame; uint32_t clip; bool start; };
static bool compile_schedule(const sq_engine *e,const sq_schedule_desc& d,sq_schedule& s) {
  if(!d.revision || !valid_gain(d.master_gain) || d.clip_count>SQ_SCHEDULE_MAX_CLIPS ||
     d.window_count>SQ_SCHEDULE_MAX_WINDOWS || (d.clip_count && !d.clips) || (d.window_count && !d.windows)) return false;
  s.revision=d.revision; s.master_gain=d.master_gain;
  if(d.clip_count) s.clips.assign(d.clips,d.clips+d.clip_count);
  if(d.window_count) s.windows.assign(d.windows,d.windows+d.window_count);
  std::set<uint64_t> ids;
  // Asset identity describes full metadata, not prepared window sizes/pointers.
  std::map<uint64_t,std::pair<uint64_t,uint32_t>> assets;
  std::vector<ClipEvent> events; events.reserve(s.clips.size()*2);
  std::set<uint64_t> boundaries{0};
  for(uint32_t i=0;i<s.clips.size();++i) {
    const auto& c=s.clips[i];
    if(!c.instance_id || !ids.insert(c.instance_id).second || !c.asset_id ||
       c.start_frame>=c.end_frame || !c.source_frame_count || c.source_start_frame>=c.source_frame_count ||
       c.end_frame-c.start_frame>c.source_frame_count-c.source_start_frame ||
       !c.bus_count || c.bus_count>SQ_MAX_BUSES) return false;
    for(uint32_t b=0;b<c.bus_count;++b) if(!valid_gain(c.buses[b].gain) || c.buses[b].muted>1) return false;
    const auto identity=std::make_pair(c.source_frame_count,c.bus_count);
    const auto result=assets.emplace(c.asset_id,identity);
    if(!result.second && result.first->second!=identity) return false;
    events.push_back({c.start_frame,i,true}); events.push_back({c.end_frame,i,false});
    boundaries.insert(c.start_frame); boundaries.insert(c.end_frame);
  }
  std::sort(s.windows.begin(),s.windows.end(),[](const sq_pcm_window& a,const sq_pcm_window& b) {
    return a.asset_id<b.asset_id || (a.asset_id==b.asset_id && a.source_start_frame<b.source_start_frame);
  });
  uint64_t resident=0;
  for(size_t i=0;i<s.windows.size();++i) {
    const auto& w=s.windows[i]; const auto& p=w.pcm;
    const auto asset=assets.find(w.asset_id);
    if(asset==assets.end() || p.sample_rate!=e->config.sample_rate || p.bus_count!=asset->second.second ||
       !p.frame_count || p.frame_count>e->config.max_asset_frames ||
       w.source_start_frame>=asset->second.first || p.frame_count>asset->second.first-w.source_start_frame ||
       p.frame_count>SQ_SCHEDULE_MAX_RESIDENT_FRAMES-resident) return false;
    resident+=p.frame_count;
    for(uint32_t b=0;b<p.bus_count;++b) if(!p.buses[b]) return false;
    if(i && s.windows[i-1].asset_id==w.asset_id &&
       w.source_start_frame-s.windows[i-1].source_start_frame<s.windows[i-1].pcm.frame_count) return false;
  }
  for(const auto& c:s.clips) {
    const uint64_t source_end=c.source_start_frame+(c.end_frame-c.start_frame);
    for(const auto& w:s.windows) {
      if(w.asset_id!=c.asset_id) continue;
      const auto first=std::max(c.source_start_frame,w.source_start_frame);
      const auto last=std::min(source_end,w.source_start_frame+w.pcm.frame_count);
      if(first>=last) continue;
      boundaries.insert(c.start_frame+(first-c.source_start_frame));
      boundaries.insert(c.start_frame+(last-c.source_start_frame));
      if(boundaries.size()>SQ_SCHEDULE_MAX_SPANS) return false;
    }
  }
  if(boundaries.size()>SQ_SCHEDULE_MAX_SPANS) return false;
  std::sort(events.begin(),events.end(),[](const ClipEvent& a,const ClipEvent& b) {
    return a.frame<b.frame || (a.frame==b.frame && a.start<b.start); // ends first
  });
  s.spans.reserve(boundaries.size());
  std::array<uint32_t,SQ_MAX_DECKS> active{}; uint32_t count=0;
  size_t event=0;
  for(const auto frame:boundaries) {
    while(event<events.size() && events[event].frame==frame) {
      const auto& ev=events[event++];
      if(ev.start) { if(count==SQ_MAX_DECKS) return false; active[count++]=ev.clip; }
      else {
        const auto it=std::find(active.begin(),active.begin()+count,ev.clip);
        if(it==active.begin()+count) return false;
        *it=active[--count];
      }
    }
    ScheduleSpan span{}; span.frame=frame; span.count=count;
    for(uint32_t i=0;i<count;++i) {
      const auto& c=s.clips[active[i]]; const auto source=c.source_start_frame+(frame-c.start_frame);
      span.entries[i].clip=active[i];
      for(uint32_t w=0;w<s.windows.size();++w) {
        const auto& window=s.windows[w];
        if(window.asset_id==c.asset_id && source>=window.source_start_frame &&
           source-window.source_start_frame<window.pcm.frame_count) { span.entries[i].window=w; break; }
      }
    }
    const auto index=s.spans.size();
    if(index>=SQ_SCHEDULE_MAX_BOUNDARIES_PER_BLOCK &&
       frame-s.spans[index-SQ_SCHEDULE_MAX_BOUNDARIES_PER_BLOCK].frame<e->config.max_block_frames) return false;
    s.spans.push_back(span);
  }
  return true;
}
static bool compile_automation(const sq_engine *e,sq_schedule& s,uint32_t count,const sq_clip_automation *records) {
  if(count>s.clips.size() || (count && !records)) return false;
  s.automation.resize(s.clips.size());
  std::map<uint64_t,size_t> clips;
  for(size_t i=0;i<s.clips.size();++i) {
    clips.emplace(s.clips[i].instance_id,i);
    auto& a=s.automation[i].envelope;
    a.base_gain=1; a.envelope_source_start_frame=s.clips[i].source_start_frame;
    a.envelope_frame_count=s.clips[i].end_frame-s.clips[i].start_frame;
  }
  std::set<uint64_t> seen;
  std::vector<uint64_t> density;
  uint32_t total=0;
  for(uint32_t i=0;i<count;++i) {
    const auto& a=records[i]; const auto found=clips.find(a.instance_id);
    if(found==clips.end() || !seen.insert(a.instance_id).second) return false;
    const auto& c=s.clips[found->second];
    if(!valid_gain(a.base_gain) || a.fade_curve>SQ_FADE_EQUAL_POWER ||
       (a.stem_override_mask>>c.bus_count) || !a.envelope_frame_count ||
       a.envelope_source_start_frame>c.source_start_frame ||
       a.envelope_frame_count>c.source_frame_count-a.envelope_source_start_frame ||
       c.source_start_frame-a.envelope_source_start_frame>a.envelope_frame_count ||
       c.end_frame-c.start_frame>a.envelope_frame_count-(c.source_start_frame-a.envelope_source_start_frame) ||
       a.fade_in_frames>a.envelope_frame_count || a.fade_out_frames>a.envelope_frame_count-a.fade_in_frames ||
       a.event_count>SQ_AUTOMATION_MAX_EVENTS_PER_CLIP || a.event_count>SQ_AUTOMATION_MAX_EVENTS-total ||
       (a.event_count && !a.events)) return false;
    total+=a.event_count;
    auto& compiled=s.automation[found->second]; compiled.envelope=a; compiled.envelope.events=nullptr;
    for(uint32_t j=0;j<a.event_count;++j) {
      const auto& ev=a.events[j];
      if(ev.bus>=c.bus_count || !valid_gain(ev.gain) || ev.source_frame>=c.source_frame_count ||
         ev.ramp_frames>UINT64_MAX-ev.source_frame) return false;
      if(j && (ev.source_frame<a.events[j-1].source_frame ||
          (ev.source_frame==a.events[j-1].source_frame && ev.bus<=a.events[j-1].bus))) return false;
      auto& knots=compiled.buses[ev.bus];
      const double from=knots.empty()?1:knot_gain(knots.back(),ev.source_frame);
      knots.push_back({ev.source_frame,ev.ramp_frames,from,ev.gain});
      if(ev.source_frame>=c.source_start_frame && ev.source_frame-c.source_start_frame<c.end_frame-c.start_frame)
        density.push_back(c.start_frame+(ev.source_frame-c.source_start_frame));
    }
  }
  std::sort(density.begin(),density.end());
  for(size_t i=SQ_AUTOMATION_MAX_EVENTS_PER_BLOCK;i<density.size();++i)
    if(density[i]-density[i-SQ_AUTOMATION_MAX_EVENTS_PER_BLOCK]<e->config.max_block_frames) return false;
  return true;
}
static double authored_gain(sq_engine *e,uint32_t slot,uint32_t bus,uint64_t source) {
  const auto& a=e->schedule->automation[e->clip_indices[slot]];
  if(a.envelope.stem_override_mask&(1u<<bus)) return 1;
  const auto& knots=a.buses[bus]; auto& next=e->knot_indices[slot][bus];
  while(next<knots.size() && knots[next].frame<=source) ++next;
  return next?knot_gain(knots[next-1],source):1;
}
static double envelope_gain(const sq_clip_automation& a,uint64_t source) {
  const auto local=source-a.envelope_source_start_frame;
  double shaped=1;
  if(a.fade_in_frames && local<a.fade_in_frames) shaped=static_cast<double>(local)/a.fade_in_frames;
  if(a.fade_out_frames && local>=a.envelope_frame_count-a.fade_out_frames)
    shaped=std::min(shaped,static_cast<double>(a.envelope_frame_count-local)/a.fade_out_frames);
  if(a.fade_curve==SQ_FADE_EQUAL_POWER && shaped<1) shaped=std::sin(shaped*1.57079632679489661923);
  return a.base_gain*shaped;
}
extern "C" {
sq_engine *sq_create(const sq_config *c) {
  if(!c || c->abi_version!=SQ_ABI_VERSION || !c->sample_rate || !c->max_block_frames ||
     c->max_block_frames>65536 || !c->max_asset_frames ||
     c->max_asset_frames>std::numeric_limits<size_t>::max()/(2*sizeof(float))) return nullptr;
  auto *e=new(std::nothrow) sq_engine;
  if(e) e->config=*c;
  return e;
}
void sq_destroy(sq_engine *e) {
  if(!e) return;
  for(auto *s=e->handles;s;) {
    auto *next=s->next; s->owner=nullptr; s->previous=nullptr; s->next=nullptr;
    s->state.store(SQ_SCHEDULE_COMPLETE,std::memory_order_release); s=next;
  }
  delete e;
}
sq_result sq_submit(sq_engine *e, const sq_plan *p) {
  if(!e || !p || !valid_plan(e,*p)) return SQ_INVALID;
  if(p->revision<=e->accepted) return SQ_STALE_REVISION;
  const auto w=e->write.load(std::memory_order_relaxed);
  if(w-e->read.load(std::memory_order_acquire)>=SQ_QUEUE_CAPACITY) return SQ_QUEUE_FULL;
  auto& entry=e->queue[w%SQ_QUEUE_CAPACITY]; entry.plan=*p; entry.schedule=nullptr;
  e->accepted=p->revision;
  e->write.store(w+1,std::memory_order_release);
  return SQ_OK;
}
sq_result sq_schedule_create(sq_engine *e,const sq_schedule_desc *d,sq_schedule **out) {
  if(!out) return SQ_INVALID;
  *out=nullptr;
  if(!e || !d) return SQ_INVALID;
  try {
    auto s=std::make_unique<sq_schedule>();
    if(!compile_schedule(e,*d,*s)) return SQ_INVALID;
    s->owner=e; s->next=e->handles;
    if(e->handles) e->handles->previous=s.get();
    e->handles=s.get(); *out=s.release(); return SQ_OK;
  } catch(const std::bad_alloc&) { return SQ_INVALID; }
}
sq_result sq_schedule_submit(sq_engine *e,sq_schedule *s) {
  if(!e || !s || s->owner!=e) return SQ_INVALID;
  if(s->state.load(std::memory_order_acquire)!=SQ_SCHEDULE_READY) return SQ_BUSY;
  if(s->revision<=e->accepted) return SQ_STALE_REVISION;
  const auto w=e->write.load(std::memory_order_relaxed);
  if(w-e->read.load(std::memory_order_acquire)>=SQ_QUEUE_CAPACITY) return SQ_QUEUE_FULL;
  e->queue[w%SQ_QUEUE_CAPACITY].schedule=s;
  e->accepted=s->revision; s->state.store(SQ_SCHEDULE_IN_USE,std::memory_order_release);
  e->write.store(w+1,std::memory_order_release); return SQ_OK;
}
sq_result sq_schedule_create_automated(sq_engine *e,const sq_schedule_desc *d,uint32_t count,
    const sq_clip_automation *automation,sq_schedule **out) {
  if(!out) return SQ_INVALID;
  *out=nullptr;
  if(!e || !d) return SQ_INVALID;
  try {
    auto s=std::make_unique<sq_schedule>();
    if(!compile_schedule(e,*d,*s) || !compile_automation(e,*s,count,automation)) return SQ_INVALID;
    s->owner=e; s->next=e->handles;
    if(e->handles) e->handles->previous=s.get();
    e->handles=s.get(); *out=s.release(); return SQ_OK;
  } catch(const std::bad_alloc&) { return SQ_INVALID; }
}
sq_schedule_state sq_schedule_get_state(const sq_schedule *s) {
  return s?static_cast<sq_schedule_state>(s->state.load(std::memory_order_acquire)):SQ_SCHEDULE_COMPLETE;
}
sq_result sq_schedule_retire(sq_schedule *s) {
  if(!s) return SQ_INVALID;
  if(s->state.load(std::memory_order_acquire)==SQ_SCHEDULE_IN_USE) return SQ_BUSY;
  if(s->owner) {
    if(s->previous) s->previous->next=s->next; else s->owner->handles=s->next;
    if(s->next) s->next->previous=s->previous;
  }
  delete s; return SQ_OK;
}
sq_result sq_render(sq_engine *e, float *out, uint32_t n) {
  if(!e || !out || !n || n>e->config.max_block_frames) return SQ_INVALID;
  const auto t=e->cursor.load(std::memory_order_relaxed);
  if(n>UINT64_MAX-t) return SQ_INVALID;
  auto r=e->read.load(std::memory_order_relaxed);
  const auto w=e->write.load(std::memory_order_acquire);
  sq_schedule *completed[SQ_QUEUE_CAPACITY]{}; uint32_t completed_count=0;
  while(r!=w) {
    const auto& entry=e->queue[r%SQ_QUEUE_CAPACITY];
    if(e->schedule) completed[completed_count++]=e->schedule;
    if(entry.schedule) install_schedule(e,entry.schedule,t);
    else { e->schedule=nullptr; apply(e,entry.plan); }
    ++r;
  }
  e->read.store(r,std::memory_order_release);
  auto missing=e->missing.load(std::memory_order_relaxed);
  auto last_missing=e->last_missing.load(std::memory_order_relaxed);
  for(uint32_t f=0;f<n;++f) {
    const auto frame=t+f;
    if(e->schedule && e->span+1<e->schedule->spans.size() && e->schedule->spans[e->span+1].frame<=frame)
      apply_span(e,e->schedule->spans[++e->span],frame);
    double sum[2]{};
    for(uint32_t i=0;i<e->current.deck_count;++i) {
      const auto& d=e->current.decks[i];
      for(uint32_t b=0;b<d.pcm.bus_count;++b) {
        auto& ramp=e->gains[d.slot][b];
        if(ramp.remaining) { ramp.value+=ramp.step; if(!--ramp.remaining) ramp.value=ramp.target; }
      }
      if(frame<d.start_frame || frame>=d.end_frame) continue;
      if(e->schedule && !d.pcm.frame_count) {
        if(missing!=UINT64_MAX) ++missing;
        last_missing=d.instance_id; continue;
      }
      const bool seek=d.has_seek && frame>=d.seek_frame;
      const auto origin=seek?d.seek_source_frame:d.source_start_frame;
      const auto elapsed=frame-(seek?d.seek_frame:d.start_frame);
      if(elapsed>=d.pcm.frame_count-origin) continue;
      const auto source=origin+elapsed;
      const bool automated=e->schedule && !e->schedule->automation.empty();
      uint64_t absolute_source=0; double envelope=1;
      if(automated) {
        const auto clip=e->clip_indices[d.slot]; const auto& c=e->schedule->clips[clip];
        absolute_source=c.source_start_frame+(frame-c.start_frame);
        envelope=envelope_gain(e->schedule->automation[clip].envelope,absolute_source);
      }
      for(uint32_t b=0;b<d.pcm.bus_count;++b) {
        const double gain=e->gains[d.slot][b].value*envelope*(automated?authored_gain(e,d.slot,b,absolute_source):1);
        for(uint32_t ch=0;ch<2;++ch) {
          const auto sample=d.pcm.buses[b][2*source+ch];
          if(std::isfinite(sample)) sum[ch]+=sample*gain;
        }
      }
    }
    for(uint32_t ch=0;ch<2;++ch) out[2*f+ch]=static_cast<float>(std::clamp(sum[ch]*e->current.master_gain,-1.0,1.0));
  }
  e->cursor.store(t+n,std::memory_order_release);
  e->missing.store(missing,std::memory_order_release);
  e->last_missing.store(last_missing,std::memory_order_release);
  e->applied.store(e->current.revision,std::memory_order_release);
  for(uint32_t i=0;i<completed_count;++i) completed[i]->state.store(SQ_SCHEDULE_COMPLETE,std::memory_order_release);
  return SQ_OK;
}
uint64_t sq_applied_revision(const sq_engine *e) { return e?e->applied.load(std::memory_order_acquire):0; }
uint64_t sq_rendered_frames(const sq_engine *e) { return e?e->cursor.load(std::memory_order_acquire):0; }
uint64_t sq_missing_pcm_frames(const sq_engine *e) { return e?e->missing.load(std::memory_order_acquire):0; }
uint64_t sq_last_missing_instance(const sq_engine *e) { return e?e->last_missing.load(std::memory_order_acquire):0; }
}

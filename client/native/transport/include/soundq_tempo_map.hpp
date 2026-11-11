#pragma once
#include "soundq_transport.hpp"
#include <algorithm>
#include <cmath>
namespace soundq::transport {
// BPM * output frames. Integral has a continuous value and first derivative.
inline double tempoIntegral(const TempoLaw& t, double frame) noexcept {
    const double x=frame-static_cast<double>(t.first), length=static_cast<double>(t.end-t.first);
    if(x<=0)return t.startBpm*x;
    const double u=std::min(1.,x/length);
    const double area=t.curve==1?u*u*u-.5*u*u*u*u:.5*u*u;
    return length*(t.startBpm*u+(t.endBpm-t.startBpm)*area)+std::max(0.,x-length)*t.endBpm;
}
inline bool sameTempo(const TempoLaw& a,const TempoLaw& b) noexcept {
    return a.preserve==b.preserve && a.curve==b.curve && a.sourceBpm==b.sourceBpm && a.startBpm==b.startBpm && a.endBpm==b.endBpm && a.first==b.first && a.end==b.end && a.sourceAnchor==b.sourceAnchor && a.overlapPolicy==b.overlapPolicy;
}
inline bool sameHistory(const ScheduleClip& a,const ScheduleClip& b) noexcept {
    if(a.tempoHistory.size()!=b.tempoHistory.size())return false;
    for(size_t i=0;i<a.tempoHistory.size();++i){const auto& x=a.tempoHistory[i];const auto& y=b.tempoHistory[i];if(x.frame!=y.frame || x.source!=y.source || !sameTempo(x.tempo,y.tempo))return false;}
    return true;
}
inline const TempoSegment* tempoSegment(const ScheduleClip& c,double frame) noexcept {
    if(c.tempoHistory.empty() || frame>=c.mapFrame)return nullptr;
    const auto it=std::upper_bound(c.tempoHistory.begin(),c.tempoHistory.end(),frame,
        [](double f,const TempoSegment& s){return f<s.frame;});
    return it==c.tempoHistory.begin()?&*it:&*std::prev(it);
}
inline double tempoRate(const ScheduleClip& c,double frame) noexcept {
    const auto* segment=tempoSegment(c,frame);
    const auto& t=segment?segment->tempo:c.tempo;
    if(!t.preserve)return 1;
    double u=std::clamp((frame-t.first)/static_cast<double>(t.end-t.first),0.,1.);
    if(t.curve==1)u=u*u*(3-2*u);
    return (t.startBpm+(t.endBpm-t.startBpm)*u)/t.sourceBpm;
}
inline double sourceAt(const ScheduleClip& c,double frame,uint32_t outputRate) noexcept {
    const auto* segment=tempoSegment(c,frame);
    const auto& law=segment?segment->tempo:c.tempo;
    const double anchor=segment?segment->frame:c.mapFrame>=0?c.mapFrame:static_cast<double>(c.start);
    const double source=segment?segment->source:c.mapFrame>=0?c.mapSource:c.trimIn;
    if(!law.preserve)return source+(frame-anchor)*c.sourceRate/outputRate;
    return source+(tempoIntegral(law,frame)-tempoIntegral(law,anchor))*c.sourceRate/(law.sourceBpm*outputRate);
}
inline uint64_t preparedExtent(const ScheduleClip& c,uint32_t outputRate) noexcept {
    return static_cast<uint64_t>(std::ceil(static_cast<long double>(c.end-c.start)*c.sourceRate/outputRate));
}
inline double preparedAt(const ScheduleClip& c,uint64_t frame,uint32_t outputRate) noexcept {
    return static_cast<double>(frame-c.start)*c.sourceRate/outputRate;
}
}

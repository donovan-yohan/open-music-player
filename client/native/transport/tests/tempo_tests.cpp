#include "soundq_transport.hpp"
#include "soundq_tempo_map.hpp"
#include <cmath>
#include <iostream>
#include <vector>
using namespace soundq::transport;
int main() {
    ScheduleClip c{1,0,0,480000,0,480000,48000,480000,0,0,1};
    c.tempo={true,0,120,120,100,0,480000,0};
    auto s=Schedule::compile(1,48000,{c});
    if(!s || s->duration!=528000) {
        std::cerr<<"FAIL shared ramp exact decoded EOF expected 528000, actual "<<(s?s->duration:0)<<'\n';return 1;
    }
    std::cout<<"PASS shared ramp exact decoded EOF\n";
    c.trimOut=48000;c.sourceFrames=48000;c.tempo.end=48000;
    s=Schedule::compile(2,48000,{c}); if(!s)return 2;
    Engine e(48000);uint64_t seq=0;
    std::vector<float> pcm(96000);
    for(unsigned i=0;i<48000;++i)pcm[2*i]=pcm[2*i+1]=i/100000.f;
    PcmWindow w;w.count=1;w.pages[0]={pcm.data(),0,48000};
    if(!e.installSchedule(++seq,s.get(),10000) || !e.bindSchedule(++seq,2,1,w) || !e.scheduleTransport(++seq,2,1,0))return 3;
    float out[512]{};e.render(out,1);Snapshot snap;e.snapshot(snap);
    if(std::abs(out[0]-.1)>1e-6 || std::abs(snap.decks[0].sourceFrame-sourceAt(s->clips[0],10001,48000))>1e-7){
        std::cerr<<"FAIL processed coordinate independent of original source map audio="<<out[0]<<" source="<<snap.decks[0].sourceFrame<<'\n';return 4;
    }
    std::cout<<"PASS processed coordinate independent of original source map\n";
    e.scheduleTransport(++seq,2,3,47900);e.render(out,1);e.scheduleTransport(++seq,2,1,0);e.render(out,256);e.snapshot(snap);
    if(snap.globalFrame!=47900){std::cerr<<"FAIL whole shared block starvation must hold global clock actual="<<snap.globalFrame<<'\n';return 5;}
    for(auto v:out)if(v!=0)return 6;
    std::cout<<"PASS whole shared block starvation holds global clock\n";
    if(!snap.scheduleBuffering || snap.renderedFrames<=256)return 7;
    if(e.scratch(++seq,2,1,1,1,1,0) || e.sync(++seq,2,LiveSync{1,0,0}))return 8;
    auto a=c,b=c;a.tempo.sourceBpm=120;b.instance=2;b.sourceRate=44100;b.sourceFrames=44100;b.trimOut=44100;b.tempo.sourceBpm=100;
    auto pair=Schedule::compile(3,48000,{a,b});if(!pair)return 9;
    for(unsigned f=0;f<40000;f+=73){
        const auto& x=pair->clips[0];const auto& y=pair->clips[1];
        const double phase=(sourceAt(x,f,48000)-x.tempo.sourceAnchor)/x.sourceRate*x.tempo.sourceBpm-(sourceAt(y,f,48000)-y.tempo.sourceAnchor)/y.sourceRate*y.tempo.sourceBpm;
        if(std::abs(phase)>1e-9)return 10;
    }
    b.tempo.sourceAnchor=100;if(Schedule::compile(4,48000,{a,b}))return 11;
    // Aggregate default remains the legacy strict phase contract.
    if(a.tempo.overlapPolicy!=TempoOverlapPolicy::StrictSharedPhase)return 30;
    auto independentA=a,independentB=b;
    independentA.tempo={true,0,120,137.1234567,137.1234567,0,1,17,TempoOverlapPolicy::IndependentConstant};
    independentB.tempo={true,1,100,101.9876543,101.9876543,123,8000,103,TempoOverlapPolicy::IndependentConstant};
    if(!Schedule::compile(10,48000,{independentA,independentB}))return 31;
    independentB.tempo.endBpm+=.01;if(Schedule::compile(10,48000,{independentB}))return 32;
    independentB.tempo.endBpm=independentB.tempo.startBpm;
    independentB.tempo.overlapPolicy=static_cast<TempoOverlapPolicy>(4);
    if(Schedule::compile(10,48000,{independentB}))return 33;
    auto boundsA=a,boundsB=b;
    boundsA.tempo.overlapPolicy=boundsB.tempo.overlapPolicy=TempoOverlapPolicy::SharedSourceBounds;
    boundsB.tempo=boundsA.tempo;boundsB.tempo.sourceBpm=100;boundsB.tempo.sourceAnchor=103;
    if(!Schedule::compile(11,48000,{boundsA,boundsB}))return 34;
    boundsB.tempo.endBpm+=.01;if(Schedule::compile(11,48000,{boundsA,boundsB}))return 35;
    boundsB.tempo.endBpm=boundsA.tempo.endBpm;
    boundsB.tempo.overlapPolicy=TempoOverlapPolicy::StrictSharedPhase;
    if(Schedule::compile(11,48000,{boundsA,boundsB}))return 36;
    boundsB.tempo.overlapPolicy=TempoOverlapPolicy::IndependentConstant;
    boundsB.tempo.endBpm=boundsB.tempo.startBpm;
    if(Schedule::compile(11,48000,{boundsA,boundsB}))return 37;
    std::cout<<"PASS explicit independent constants, unaligned shared source bounds, mixed/unknown policy and nonconstant refusal; legacy default retained\n";
    b.tempo.sourceAnchor=0;b.tempo.endBpm=110;if(Schedule::compile(4,48000,{a,b}))return 12;
    auto invalid=a;invalid.tempo.curve=2;if(Schedule::compile(4,48000,{invalid}))return 13;
    invalid=a;invalid.tempo.endBpm=95;if(Schedule::compile(4,48000,{invalid}))return 14;
    std::vector<ScheduleClip> five(5,a);for(unsigned i=0;i<five.size();++i)five[i].instance=i+1;
    if(Schedule::compile(4,48000,five))return 15;
    a.tempo.curve=1;auto smooth=Schedule::compile(5,48000,{a});if(!smooth)return 16;
    const auto& x=smooth->clips[0];
    if(std::abs(tempoIntegral(x.tempo,24000)-2790000)>1e-8 || std::abs(tempoRate(x,24000)-110./120)>1e-12)return 17;
    // Strict finite fractional endpoints and positive range reject remain independent.
    a.trimIn=.25;a.trimOut=47000.125;auto fractional=Schedule::compile(6,48000,{a});if(!fractional)return 18;
    const auto& z=fractional->clips[0];if(sourceAt(z,z.end-1,48000)>=z.trimOut || sourceAt(z,z.end,48000)<z.trimOut)return 19;
    std::cout<<"PASS mixed-rate shared phase, conflicting laws, unknown curve, range, fifth-active, smooth integral, fractional EOF, scratch/sync refusal\n";
    e.installSchedule(++seq,nullptr,0);e.render(out,1);
    std::fill(pcm.begin(),pcm.end(),2.f); // old graph retirement ACK precedes mutation
    e.installSchedule(++seq,s.get(),10000);e.bindSchedule(++seq,2,1,w);e.scheduleTransport(++seq,2,1,0);e.render(out,256);
    for(auto v:out)if(!std::isfinite(v) || std::abs(v)>1){std::cerr<<"FAIL strict preserved mix output clipping actual="<<v<<'\n';return 20;}
    std::cout<<"PASS strict preserved mix output clipping\n";
    std::vector<float> futurePcm(4096*2,.2f);
    ScheduleClip future{1,0,50000,0,0,4096,48000,4096,0,0,1};
    future.tempo={true,0,120,120,110,50000,60000,0};
    auto futureSchedule=Schedule::compile(7,48000,{future});if(!futureSchedule)return 21;
    Engine lead(48000);lead.installSchedule(1,futureSchedule.get(),49900);lead.render(out,1);lead.scheduleTransport(2,7,1,0);lead.render(out,256);lead.snapshot(snap);
    if(snap.globalFrame!=49900)return 22;
    // Snapshot at held pre-entry boundary must still carry the paused-seek cursor
    // so a nearest-future worker prepares the correct output page.
    PcmWindow prepared;prepared.count=1;prepared.pages[0]={futurePcm.data(),0,4096};
    lead.bindSchedule(3,7,1,prepared);lead.render(out,256);lead.snapshot(snap);
    if(snap.globalFrame!=50156)return 23;
    std::cout<<"PASS upcoming preserved entry shares block hold and healthy recovery\n";
    a.tempo.first=.25;a.tempo.end=48000.75;
    auto subframe=Schedule::compile(8,48000,{a});if(!subframe || subframe->clips[0].tempo.first!=.25 || subframe->clips[0].tempo.end!=48000.75)return 24;
    if(std::abs(tempoRate(subframe->clips[0],24000.5)-110./120)>1e-12)return 25;
    std::cout<<"PASS exact subframe shared law boundaries\n";
    // A raw peer deliberately scratching backward has its own audible source
    // cursor. In a mixed preserved graph preflight must not demand nominal taps.
    ScheduleClip raw{2,0,0,20000,0,20000,48000,20000,0,0,1};
    a.instance=1;a.trimIn=0;a.trimOut=20000;a.sourceFrames=20000;a.tempo.first=0;a.tempo.end=48000;
    auto mixed=Schedule::compile(9,48000,{a,raw});if(!mixed)return 26;
    std::vector<float> lockedPcm(40000,.1f),rawPcm(12000,.2f);
    PcmWindow locked,vinyl;locked.count=vinyl.count=1;locked.pages[0]={lockedPcm.data(),0,20000};vinyl.pages[0]={rawPcm.data(),5000,6000};
    Engine mixedEngine(48000);uint64_t ms=0;
    mixedEngine.installSchedule(++ms,mixed.get(),10000);mixedEngine.bindSchedule(++ms,9,1,locked);mixedEngine.bindSchedule(++ms,9,2,vinyl);mixedEngine.render(out,1);
    mixedEngine.scheduleTransport(++ms,9,1,0);mixedEngine.render(out,1);
    if(!mixedEngine.scratch(++ms,9,1,2,1,1,0))return 27;
    mixedEngine.renderAt(out,1,1);if(!mixedEngine.scratch(++ms,9,2,2,1,2,-1))return 28;
    mixedEngine.renderAt(out,256,2);
    for(unsigned n=0;n<4;++n)mixedEngine.renderAt(out,256,3);mixedEngine.snapshot(snap);const auto before=snap.globalFrame;
    mixedEngine.renderAt(out,256,4);mixedEngine.snapshot(snap);
    if(snap.globalFrame!=before+256){std::cerr<<"FAIL raw scratch in preserved graph must preflight actual cursor\n";return 29;}
}

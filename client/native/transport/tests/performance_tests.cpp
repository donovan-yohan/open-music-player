#include "soundq_transport.hpp"
#include <algorithm>
#include <cassert>
#include <cmath>
#include <iostream>
#include <vector>
#include <cstdlib>
#include <new>
namespace heap_probe {thread_local bool callback=false;unsigned operations=0;}
void* operator new(std::size_t n){if(heap_probe::callback)++heap_probe::operations;if(auto* p=std::malloc(n?n:1))return p;throw std::bad_alloc();}
void* operator new[](std::size_t n){return ::operator new(n);}
void operator delete(void* p)noexcept{if(heap_probe::callback)++heap_probe::operations;std::free(p);}
void operator delete[](void* p)noexcept{::operator delete(p);}
using namespace soundq::transport;
namespace {
void checkedRender(Engine& e,float* output,unsigned frames,uint64_t t) {
    heap_probe::callback=true;e.renderAt(output,frames,t);heap_probe::callback=false;assert(heap_probe::operations==0);
}
PcmWindow window(const std::vector<float>& data) {
    PcmWindow w;
    const auto frames=data.size()/2;
    for(size_t at=0;at<frames;at+=maxPcmPageFrames)w.pages[w.count++]={data.data()+at*2,at,static_cast<uint32_t>(std::min<size_t>(maxPcmPageFrames,frames-at))};
    return w;
}
double interpolate(const std::vector<float>& data,double p,unsigned ch) {
    const auto i=static_cast<size_t>(p);const double f=p-i;
    return data[2*i+ch]*(1-f)+data[2*std::min(i+1,data.size()/2-1)+ch]*f;
}
Snapshot snap(Engine& e){Snapshot s;assert(e.snapshot(s));return s;}
void scratchOracle() {
    constexpr unsigned hz=48000,extent=144000;
    std::array<std::vector<float>,4> pcm;
    std::vector<ScheduleClip> clips;
    for(unsigned v=0;v<4;++v) {
        pcm[v].resize(extent*2);
        for(unsigned i=0;i<extent;++i){pcm[v][2*i]=static_cast<float>(.02*std::sin(i*(.013+v*.001)));pcm[v][2*i+1]=v?static_cast<float>(.03*std::cos(i*(.007+v*.002))):0;}
        clips.push_back({v+1,0,0,96000,24000,120000,hz,extent,0,0,1});
    }
    auto schedule=Schedule::compile(1,hz,clips);assert(schedule);
    Engine e(hz),baseline(hz);uint64_t q=1,bq=1,event=1000000000;
    for(auto* engine:{&e,&baseline}){
        auto& seq=engine==&e?q:bq;
        assert(engine->installSchedule(seq++,schedule.get(),0));
        for(unsigned v=0;v<4;++v)assert(engine->bindSchedule(seq++,1,v+1,window(pcm[v])));
        engine->renderAt(nullptr,1,event);
        assert(engine->scheduleTransport(seq++,1,1,0));engine->renderAt(nullptr,256,event);
    }
    assert(e.scratch(q++,1,1,1,1,++event,0));
    e.renderAt(nullptr,1,event+100);baseline.renderAt(nullptr,1,event+100);
    auto s=snap(e);double position=24256,rate=0;
    assert(s.decks[0].sourceFrame==position && s.decks[0].heldZero);
    std::vector<float> out(512),plain(512);
    uint64_t global=257;
    double maximum=0;
    // Each block is shorter than the 40ms inactivity budget. Independent ramp
    // integrates every rendered source derivative, including fractional micro rates.
    for(const double target:{.000013, .000013, .75, 0., -1.25, -1.25, 2., 0.}) {
        assert(e.scratch(q++,1,2,1,1,++event,target));
        const auto step=(target-rate)/128.;
        checkedRender(e,out.data(),256,event+100);baseline.renderAt(plain.data(),256,event+100);
        for(unsigned i=0;i<256;++i) {
            if(i<128)rate=i==127?target:rate+step;
            double expected[2]{};
            for(unsigned ch=0;ch<2;++ch){
                expected[ch]=interpolate(pcm[0],position,ch)*((position==24000 && rate<0)?0:std::min(1.,std::abs(rate)));
                for(unsigned peer=1;peer<4;++peer)expected[ch]+=pcm[peer][2*(24000+global+i)+ch];
                maximum=std::max(maximum,std::abs(expected[ch]-out[2*i+ch]));
                assert(std::abs(expected[ch]-out[2*i+ch])<2e-8);
            }
            assert(out[2*i+1]==plain[2*i+1]); // three-peer contribution is BIT identical
            position=std::clamp(position+rate,24000.,120000.);
        }
        global+=256;s=snap(e);
        assert(std::abs(s.decks[0].sourceFrame-position)<1e-7);
        assert(s.decks[0].rate==target);
        for(unsigned peer=1;peer<4;++peer)assert(s.decks[peer].sourceFrame==snap(baseline).decks[peer].sourceFrame);
    }
    assert(e.scratch(q++,1,2,1,1,++event,1));e.renderAt(nullptr,128,event+100);
    e.renderAt(nullptr,1920,event+200);
    s=snap(e);assert(s.decks[0].heldZero && s.decks[0].rate==0);
    const double held=s.decks[0].sourceFrame;e.renderAt(nullptr,200,event+300);assert(snap(e).decks[0].sourceFrame==held);
    assert(!e.scratch(q++,1,2,1,1,event,1)); // repeated timestamp
    assert(e.scratch(q++,1,3,1,1,++event,0));e.renderAt(nullptr,128,event+100);
    s=snap(e);assert(!s.decks[0].scratching && s.decks[0].rate==1);
    assert(std::abs(s.decks[0].sourceFrame-(held+64.5))<1e-7); // resume HERE, not nominal
    assert(!e.scratch(q++,1,2,1,1,++event,-1));
    assert(e.scratch(q++,1,1,1,2,++event,0));e.renderAt(nullptr,1,event+100);
    assert(e.scheduleTransport(q++,1,2,0));e.renderAt(nullptr,1,event+100);
    assert(!e.scratch(q++,1,3,1,2,++event,0));assert(!snap(e).schedulePlaying);
    const auto paused=snap(e).decks[0].sourceFrame;
    assert(e.scratch(q++,1,1,1,3,++event,0));e.renderAt(nullptr,1,event+100);
    assert(e.scratch(q++,1,2,1,3,++event,-.01));e.renderAt(nullptr,128,event+100);
    assert(e.scratch(q++,1,4,1,3,++event,0));e.renderAt(nullptr,128,event+100);
    assert(e.scratch(q++,1,4,1,3,event,0)); // exact cancel replay has no new effect
    assert(!snap(e).schedulePlaying && snap(e).decks[0].sourceFrame<paused);
    assert(e.installSchedule(q++,nullptr,0));e.render(nullptr,1);
    assert(!e.scratch(q++,1,3,1,3,++event,0));
    std::cout<<"PASS every-sample four independent sources scratch ramp/micro/zero/reverse, peer oracle, watchdog40ms, resume-here, paused cancel, replacement max_error="<<maximum<<'\n';
}
void syncOracle(unsigned beats,double rb,double ib,unsigned incomingRate) {
    constexpr unsigned hz=1000,extent=80000;
    std::array<std::vector<float>,4> pcm;
    std::vector<ScheduleClip> clips;
    const double ro=250,io=400,ra=ro+3*60000/rb,ia=io+2*60000/ib;
    for(unsigned v=0;v<4;++v){
        const unsigned sr=v==1?incomingRate:hz;
        pcm[v].resize(extent*2);
        for(unsigned i=0;i<extent;++i) {
            // Narrow pulse trains, with a low-level independent ramp in channel2.
            const double phase=std::remainder((i*1000./sr-(v==1?io:ro))*(v==1?ib:rb)/60000.,1.);
            pcm[v][2*i]=static_cast<float>(std::max(0.,1-std::abs(phase)*80)*.04);
            pcm[v][2*i+1]=static_cast<float>((i%173)*.00003*(v+1));
        }
        clips.push_back({v+1,0,0,60000,static_cast<double>(sr)*.1,static_cast<double>(sr)*60.1,sr,extent,0,0,1});
    }
    auto schedule=Schedule::compile(9,hz,clips);assert(schedule);
    Engine e(hz);uint64_t q=1,event=2000000000;
    assert(e.installSchedule(q++,schedule.get(),0));for(unsigned v=0;v<4;++v)assert(e.bindSchedule(q++,9,v+1,window(pcm[v])));
    e.renderAt(nullptr,1,event);assert(e.scheduleTransport(q++,9,1,0));e.renderAt(nullptr,17,event);
    LiveSync r{2,1,beats,rb,ra,beats==1?-1:ro,ib,ia,beats==1?-1:io};
    assert(e.sync(q++,9,r));assert(snap(e).decks[1].syncState==0); // admission != ACK
    e.renderAt(nullptr,1,event);auto s=snap(e);assert(s.decks[1].syncState==1);
    const uint64_t boundary=s.decks[1].syncBoundaryFrame;
    const double speed=rb/ib;
    const double target=s.decks[1].demandSourceFrame;
    assert(boundary>18 && target>=clips[1].trimIn);
    double maximum=0,maxPhase=0;
    std::vector<float> out(2);
    for(uint64_t g=18;g<boundary+5000 && g<59000;++g) {
        checkedRender(e,out.data(),1,event);s=snap(e);
        for(unsigned ch=0;ch<2;++ch) {
            double expected=0;
            for(unsigned v=0;v<4;++v) {
                double pos=clips[v].trimIn+static_cast<double>(g)*clips[v].sourceRate/hz;
                double gain=1;
                if(v==1) {
                    if(g>=boundary){pos=target+(g-boundary)*speed*incomingRate/hz;gain=g<boundary+64?(g-boundary)/64.:1;}
                    else if(boundary-g<=64)gain=(boundary-g)/64.;
                }
                expected+=interpolate(pcm[v],pos,ch)*gain;
            }
            maximum=std::max(maximum,std::abs(expected-out[ch]));assert(std::abs(expected-out[ch])<2e-8);
        }
        if(g>=boundary) {
            assert(s.decks[1].syncState==2);
            const double rp=(clips[0].trimIn+g-ro*hz/1000.)/hz*rb/60.;
            const double ip=(target+(g-boundary)*speed*incomingRate/hz-io*incomingRate/1000.)/incomingRate*ib/60.;
            const double error=std::abs(std::remainder(ip-rp,static_cast<double>(beats))*60*hz/rb);
            maxPhase=std::max(maxPhase,error);assert(error<=1);
            assert(std::abs(s.decks[1].syncPhaseErrorFrames)<=1);
        }
    }
    assert(!e.scratch(q++,9,1,1,1,++event,0)); // master cannot scratch
    assert(e.scratch(q++,9,1,2,1,++event,0));e.renderAt(nullptr,1,event+100);
    assert(snap(e).decks[1].syncState==3);
    assert(e.scratch(q++,9,2,2,1,++event,-1));e.renderAt(nullptr,100,event+100);
    assert(e.scratch(q++,9,3,2,1,++event,0));e.renderAt(nullptr,1,event+100);
    s=snap(e);assert(s.decks[1].syncState==4);
    const auto rejoin=s.decks[1].syncBoundaryFrame;while(snap(e).globalFrame<=rejoin)e.renderAt(nullptr,1,event);assert(snap(e).decks[1].syncState==2);
    e.renderAt(nullptr,128,event); // finish release ramp even if no future boundary exists
    const auto before=snap(e);assert(e.sync(q++,9,{2,0,0}));e.renderAt(nullptr,1,event);s=snap(e);
    assert(s.decks[1].syncState==0 && std::abs(s.decks[1].rate-speed)<1e-12 && s.schedulePlaying);
    assert(std::abs(s.decks[1].sourceFrame-before.decks[1].sourceFrame-speed*incomingRate/hz)<1e-7);
    std::cout<<"PASS sync pulses beats="<<beats<<" bpm="<<rb<<'/'<<ib<<" normalized_hz="<<incomingRate<<" phase_max_output_frames="<<maxPhase<<" every_sample_max_error="<<maximum<<'\n';
}
void lifecycleOracle() {
    std::vector<float> pcm(40000*2,.1f);auto w=window(pcm);
    // Same slot, alternating bank. Old instance authority must end at the exact
    // half-open boundary, including an unended scratch and its queued latest move.
    auto s=Schedule::compile(20,1000,{{1,0,0,5000,1000,6000,1000,40000,0,0,1},{2,0,5000,10000,0,5000,1000,40000,0,0,1}});assert(s);
    Engine e(1000);uint64_t q=1,event=3000000000;
    assert(e.installSchedule(q++,s.get(),0));assert(e.bindSchedule(q++,20,1,w));assert(e.bindSchedule(q++,20,2,w));e.renderAt(nullptr,1,event);
    assert(!e.scratch(q++,20,2,1,1,++event,1));
    assert(e.scheduleTransport(q++,20,1,0));e.renderAt(nullptr,4998,event);
    assert(e.scratch(q++,20,1,1,1,++event,0));
    assert(e.scratch(q++,20,2,1,1,++event,-1));
    assert(e.scratch(q++,20,2,1,1,++event,.01)); // bounded latest, not two queued moves
    e.renderAt(nullptr,2,event+1);
    assert(!snap(e).decks[0].scratching && snap(e).movesCoalesced==1);
    assert(!e.scratch(q++,20,3,1,1,++event,0));
    e.renderAt(nullptr,1,event+1);assert(snap(e).decks[0].identity==2 && snap(e).decks[0].sourceFrame==1);
    assert(e.scratch(q++,20,1,2,2,++event,0));
    // Terminal is consumed reliably even when Move was never rendered.
    assert(e.scratch(q++,20,2,2,2,++event,8));assert(e.scratch(q++,20,4,2,2,++event,0));
    e.renderAt(nullptr,1,event+1);assert(!snap(e).decks[0].scratching);
    assert(e.scheduleTransport(q++,20,3,0));e.renderAt(nullptr,1,event);
    assert(!e.scratch(q++,20,2,2,2,++event,1));

    auto both=Schedule::compile(21,1000,{{1,0,0,30000,0,30000,1000,40000,0,0,1},{2,0,0,30000,0,30000,1000,40000,0,0,1}});assert(both);
    assert(e.installSchedule(q++,both.get(),0));assert(e.bindSchedule(q++,21,1,w));assert(e.bindSchedule(q++,21,2,w));e.renderAt(nullptr,1,event);
    assert(e.scheduleTransport(q++,21,1,0));e.renderAt(nullptr,100,event);
    LiveSync link{2,1,4,120,0,-1,100,0,-1};assert(!e.sync(q++,21,link));
    link.beats=1;link.referenceBpm=600;link.incomingBpm=10;assert(!e.sync(q++,21,link));
    link.referenceBpm=120;link.incomingBpm=100;assert(e.sync(q++,21,link));e.renderAt(nullptr,1,event);
    auto pending=snap(e);assert(pending.decks[1].syncState==1);const auto missed=pending.decks[1].syncBoundaryFrame;
    assert(e.bindSchedule(q++,21,2,{}));
    while(snap(e).globalFrame<=missed)e.renderAt(nullptr,1,event);
    auto rescheduled=snap(e);assert(rescheduled.decks[1].syncState!=2 && rescheduled.syncReschedules==1 && rescheduled.decks[1].syncBoundaryFrame>missed);
    assert(e.bindSchedule(q++,21,2,w));const auto next=rescheduled.decks[1].syncBoundaryFrame;
    while(snap(e).globalFrame<=next)e.renderAt(nullptr,1,event);
    assert(snap(e).decks[1].syncState==2);
    assert(e.bindSchedule(q++,21,1,{}));e.renderAt(nullptr,1,event);assert(snap(e).decks[1].syncState!=2);
    // A late event is not allowed an extra 40ms after dispatch. Its original age
    // is included in the output-frame watchdog, then only the short ramp remains.
    assert(e.sync(q++,21,{2,0,0}));assert(e.bindSchedule(q++,21,1,w));e.renderAt(nullptr,1,event);
    assert(e.scratch(q++,21,1,1,3,++event,0));e.renderAt(nullptr,1,event);
    assert(e.scratch(q++,21,2,1,3,++event,4));e.renderAt(nullptr,128,event+100000000);
    assert(snap(e).decks[0].heldZero);
    assert(e.scheduleTransport(q++,21,3,29900));e.renderAt(nullptr,1,event);
    assert(e.scheduleTransport(q++,21,1,0));e.renderAt(nullptr,1,event);
    LiveSync tooLate{2,1,32,120,0,0,100,0,0};assert(e.sync(q++,21,tooLate));e.renderAt(nullptr,1,event);
    assert(snap(e).decks[1].syncState==5 && snap(e).decks[1].rate==0);
    std::cout<<"PASS exact slot end/successor, stale and pre-Begin, coalescing/terminal, seek, timing/ratio refusal, missed boundary reschedule, starving-master lock removal, original-event-age watchdog\n";
}
}
int main(){scratchOracle();for(unsigned n:{1,4,16,32})syncOracle(n,127,103,800);lifecycleOracle();}

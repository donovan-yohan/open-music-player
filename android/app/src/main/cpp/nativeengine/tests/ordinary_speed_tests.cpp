// Ordinary listening speed: real Engine + Host + WorkerDeck + TempoProcessor with
// the TEST ONLY deterministic decoder. Exact source-coordinate invariants, a
// pitch oracle (tone frequency) and EOF/natural-end receipts at non-1x.
#include "callback_host.hpp"
#include "soundq_transport.hpp"
#include <array>
#include <atomic>
#include <cassert>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <iostream>
#include <string>
#include <thread>
#include <vector>
using namespace soundq::nativeengine;
using namespace soundq::transport;
extern std::atomic<int> testDecoders;
namespace soundq::nativeengine::test {void workerJoin() noexcept {}}
#define CHECK(x) do{if(!(x)){std::cerr<<"FAIL line "<<__LINE__<<": "<<#x<<"\n";std::exit(1);}}while(0)
struct Controlled final:Output {
    Callbacks* cb=nullptr;
    bool open(Callbacks& c,uint32_t& rate)override{cb=&c;rate=48000;return true;}
    bool start()override{return true;}bool stopClose()override{return true;}
    int32_t xRuns()const noexcept override{return 0;}
    std::vector<float> render(uint32_t n=256){std::vector<float> pcm(size_t{n}*2);cb->render(pcm.data(),n);return pcm;}
};
std::string deck(const std::string& s,int index) {
    auto at=s.find("\"decks\":[")+9;
    for(int i=0;i<index;++i)at=s.find('}',at)+2;
    return s.substr(at,s.find('}',at)-at+1);
}
double field(const std::string& s,const std::string& name) {
    const auto at=s.find("\""+name+"\":");CHECK(at!=std::string::npos);
    return std::strtod(s.c_str()+at+name.size()+3,nullptr);
}
template<class Test>void wait(Test test) {
    const auto end=std::chrono::steady_clock::now()+std::chrono::seconds(20);
    while(!test()){CHECK(std::chrono::steady_clock::now()<end);std::this_thread::sleep_for(std::chrono::milliseconds(1));}
}
double frequency(const std::vector<float>& pcm,uint32_t rate) {
    unsigned crossings=0;double energy=0;const size_t frames=pcm.size()/2;
    for(size_t i=1;i<frames;++i){if((pcm[2*(i-1)]<0)!=(pcm[2*i]<0))++crossings;energy+=pcm[2*i]*pcm[2*i];}
    CHECK(std::sqrt(energy/frames)>0.03); // audible, not a held/silent window
    return crossings/2.0/(double(frames)/rate);
}

void exactCore() {
    Engine e(48000);std::array<float,128> a{};
    for(unsigned i=0;i<64;++i){a[2*i]=float(i+1)/256;a[2*i+1]=-float(i+1)/256;}
    PcmWindow w{};w.count=1;w.pages[0]={a.data(),0,64};
    std::array<float,512> pcm{};
    // Initial speed applies with the assignment, without a 128-frame ramp.
    CHECK(e.assignPaged(0,1,1,{64,48000,11,1.5},w));e.render(pcm.data(),1);
    Snapshot s;CHECK(e.snapshot(s));CHECK(s.decks[0].rate==1.5);CHECK(s.decks[0].traversalRevision==1);
    CHECK(e.submit({Operation::Play,0,2,1}));e.render(pcm.data(),10);
    CHECK(e.snapshot(s));CHECK(s.decks[0].sourceFrame==15);
    // Interpolated source-coordinate samples, consumed at 1.5 source frames/output frame.
    CHECK(std::abs(pcm[2]-(a[2]*0.5f+a[4]*0.5f))<1e-7);
    // Atomic window+rate handoff: same block, no ramp, no traversal discontinuity.
    CHECK(!e.publishWindowRate(0,3,1,w,0));CHECK(!e.publishWindowRate(0,3,1,w,std::nan("")));
    CHECK(!e.publishWindowRate(0,3,1,w,5));CHECK(!e.publishWindowRate(0,3,2,w,0.75));
    CHECK(e.publishWindowRate(0,3,1,w,0.75));e.render(pcm.data(),4);
    CHECK(e.snapshot(s));CHECK(s.decks[0].rate==0.75);CHECK(s.decks[0].sourceFrame==18);
    CHECK(s.decks[0].traversalRevision==1);
    // Scratch owns rate; a listening handoff cannot overwrite its saved rate.
    CHECK(e.submit({Operation::BeginScratch,0,4,1,4}));CHECK(!e.publishWindowRate(0,5,1,w,1.25));
    CHECK(e.submit({Operation::CancelScratch,0,5,1,4}));e.render(pcm.data(),1);
    CHECK(e.snapshot(s));CHECK(!s.decks[0].scratching);
    CHECK(e.publishWindowRate(0,6,1,w,2));e.render(pcm.data(),1);
    const auto revision=[&]{Snapshot x;CHECK(e.snapshot(x));return x.decks[0].traversalRevision;}();
    // Exact EOF and one natural-end receipt at 2x.
    for(unsigned i=0;i<64;++i)e.render(pcm.data(),1);
    CHECK(e.snapshot(s));CHECK(s.decks[0].eofCount==1);CHECK(s.decks[0].naturalEndCount==1);
    CHECK(s.decks[0].naturalEndTraversalRevision==revision);CHECK(s.decks[0].sourceFrame==64);
    e.render(pcm.data(),64);CHECK(e.snapshot(s));CHECK(s.decks[0].eofCount==1&&s.decks[0].naturalEndCount==1);
}

void crossfadeAtSpeed() {
    // Outgoing at 2x: the accepted fade still spans `length` OUTPUT frames and
    // ends exactly at outgoing EOF, so incoming has advanced `length` frames.
    Engine e(48000);std::vector<float> a(4800*2,.25f),b(4800*2,.5f);
    PcmWindow aw{},bw{};aw.count=bw.count=1;aw.pages[0]={a.data(),0,4800};bw.pages[0]={b.data(),0,4800};
    std::array<float,8192> pcm{};
    CHECK(e.assignPaged(0,1,1,{4800,48000,11,2},aw));CHECK(e.assignPaged(1,2,2,{4800,48000,12,1},bw));
    e.render(pcm.data(),1);CHECK(e.crossfade(3,0,1,1,2,480));CHECK(e.submit({Operation::Play,0,4,1}));
    uint64_t outputs=0;Snapshot s;
    for(;;){e.render(pcm.data(),1);++outputs;CHECK(e.snapshot(s));if(s.decks[0].eofCount)break;CHECK(outputs<5000);}
    CHECK(outputs==2400);
    CHECK(std::abs(s.decks[1].sourceFrame-480)<=1);
}

void listeningSpeedKeepsLevel() {
    // Ordinary listening speed is a pace, not a gain: a 0.5x or 0.75x track plays
    // at the same level as 1x (scratch/varispeed attenuation is separate).
    Engine e(48000);std::vector<float> a(4800*2,.25f);
    PcmWindow w{};w.count=1;w.pages[0]={a.data(),0,4800};
    std::array<float,512> pcm{};
    CHECK(e.assignPaged(0,1,1,{4800,48000,11,0.5},w));CHECK(e.submit({Operation::Play,0,2,1}));
    e.render(pcm.data(),64);
    std::cout<<"0.5x output level "<<pcm[2*63]<<" (source .25)\n";
    CHECK(std::abs(pcm[2*63]-.25f)<1e-6&&std::abs(pcm[2*63+1]-.25f)<1e-6);
    CHECK(e.publishWindowRate(0,3,1,w,0.75));e.render(pcm.data(),64);
    CHECK(std::abs(pcm[2*63]-.25f)<1e-6);
    CHECK(e.publishWindowRate(0,4,1,w,1.5));e.render(pcm.data(),64);
    CHECK(std::abs(pcm[2*63]-.25f)<1e-6);
}

void crossfadeRetimedBySpeedChange() {
    // A speed change on the outgoing deck mid-fade keeps the fade continuous and
    // still completes exactly at outgoing EOF, so the incoming deck ends at unity.
    Engine e(48000);std::vector<float> a(4800*2,.25f),b(9600*2,.5f);
    PcmWindow aw{},bw{};aw.count=bw.count=1;aw.pages[0]={a.data(),0,4800};bw.pages[0]={b.data(),0,9600};
    std::array<float,8192> pcm{};
    CHECK(e.assignPaged(0,1,1,{4800,48000,11,1},aw));CHECK(e.assignPaged(1,2,2,{9600,48000,12,1},bw));
    e.render(pcm.data(),1);CHECK(e.crossfade(3,0,1,1,2,960));CHECK(e.submit({Operation::Play,0,4,1}));
    Snapshot s;uint64_t outputs=0;
    // Into the fade: 4800-960 = 3840 frames before it begins, then 480 frames of it.
    for(;outputs<3840+480;++outputs)e.render(pcm.data(),1);
    CHECK(e.snapshot(s));const double before=s.decks[1].boundaryGain;CHECK(before>0.1&&before<0.9);
    CHECK(e.publishWindowRate(0,5,1,aw,2));e.render(pcm.data(),1);++outputs;
    CHECK(e.snapshot(s));CHECK(std::abs(s.decks[1].boundaryGain-before)<0.01); // no gain jump
    for(;;){e.render(pcm.data(),1);++outputs;CHECK(e.snapshot(s));if(s.decks[0].eofCount)break;CHECK(outputs<9000);}
    // 480 source frames remained at 2x = 240 output frames.
    std::cout<<"retimed fade: outgoing EOF after "<<outputs<<" outputs, incoming gain "<<s.decks[1].boundaryGain<<"\n";
    CHECK(outputs>=3840+480+239&&outputs<=3840+480+242);
    e.render(pcm.data(),1);CHECK(e.snapshot(s));
    CHECK(std::abs(s.decks[1].boundaryGain-1)<1e-9);
    CHECK(std::abs(pcm[0]-.5f)<1e-6);
}

int main() {
    exactCore();crossfadeAtSpeed();listeningSpeedKeepsLevel();crossfadeRetimedBySpeedChange();
    Registry registry;auto output=std::make_unique<Controlled>();auto* out=output.get();
    const auto h=registry.open(std::move(output));CHECK(h);
    CHECK(field(registry.state(h),"speedMin")==0.5&&field(registry.state(h),"speedMax")==2);
    // Fake tone: 440 Hz, 32 kHz source, 320000 frames (10 s); output is 48 kHz.
    CHECK(registry.load(h,0,"/fake/tone",11,1,0));
    auto ready=[&]{out->render(1);return deck(registry.state(h),0).find("\"ready\":true")!=std::string::npos;};
    wait(ready);
    CHECK(!registry.control(h,10,0,2.5,0));CHECK(!registry.control(h,10,0,0.4,0));CHECK(!registry.control(h,10,0,std::nan(""),0));
    CHECK(!registry.control(h,10,1,1.5,0)); // no source on deck 1
    const auto revision=field(deck(registry.state(h),0),"traversalRevision");
    CHECK(registry.control(h,10,0,1.5,0));
    CHECK(field(deck(registry.state(h),0),"speed")==1.5);
    wait([&]{out->render(1);const auto d=deck(registry.state(h),0);return field(d,"rate")==1.5&&d.find("\"ready\":true")!=std::string::npos;});
    CHECK(field(deck(registry.state(h),0),"traversalRevision")==revision); // journal stays bound
    CHECK(registry.control(h,1,0,0,0));
    auto play=[&](uint32_t frames,std::vector<float>* sink=nullptr){
        // Readiness polls only pump the control lane; every rendered frame is counted.
        auto covered=[&]{return deck(registry.state(h),0).find("\"ready\":true")!=std::string::npos;};
        for(uint32_t done=0;done<frames;done+=256){wait(covered);auto pcm=out->render(std::min(256U,frames-done));if(sink)sink->insert(sink->end(),pcm.begin(),pcm.end());}
    };
    play(256);
    double before=field(deck(registry.state(h),0),"sourceFrame");
    std::vector<float> fast;play(9600,&fast);
    double after=field(deck(registry.state(h),0),"sourceFrame");
    // 9600 output frames * 1.5 speed * 32000/48000 = 9600 source frames.
    CHECK(std::abs(after-before-9600)<1e-6);
    const auto pitch=frequency(fast,48000);
    std::cout<<"1.5x tone frequency "<<pitch<<" Hz (source 440, varispeed would be 660)\n";
    CHECK(std::abs(pitch-440)<440*0.04);
    // Seek at non-1x: source coordinates, speed retained.
    CHECK(registry.control(h,3,0,5000,0));
    wait([&]{out->render(1);const auto d=deck(registry.state(h),0);return std::abs(field(d,"positionMs")-5000)<=20&&d.find("\"ready\":true")!=std::string::npos;});
    CHECK(field(deck(registry.state(h),0),"rate")==1.5);
    before=field(deck(registry.state(h),0),"sourceFrame");play(4800);after=field(deck(registry.state(h),0),"sourceFrame");
    CHECK(std::abs(after-before-4800)<1e-6);
    // Route failure + explicit recovery keeps the accepted speed (quiesce does not force 1x).
    out->cb->outputError(-5);registry.state(h);CHECK(registry.control(h,9,0,0,0));
    CHECK(field(deck(registry.state(h),0),"rate")==1.5);
    CHECK(registry.control(h,1,0,0,0));
    // Natural end once at 1.5x.
    CHECK(registry.control(h,3,0,9800,0));
    wait([&]{out->render(1);const auto d=deck(registry.state(h),0);return std::abs(field(d,"positionMs")-9800)<=20&&d.find("\"ready\":true")!=std::string::npos;});
    const auto endRevision=field(deck(registry.state(h),0),"traversalRevision");
    for(unsigned i=0;i<200&&field(deck(registry.state(h),0),"eofCount")==0;++i)out->render(256);
    auto d=deck(registry.state(h),0);
    CHECK(field(d,"eofCount")==1);CHECK(field(d,"naturalEndCount")==1);CHECK(field(d,"naturalEndTraversalRevision")==endRevision);
    for(unsigned i=0;i<20;++i)out->render(256);
    d=deck(registry.state(h),0);CHECK(field(d,"eofCount")==1&&field(d,"naturalEndCount")==1);
    // Reset returns to the raw path at 1x.
    CHECK(registry.control(h,3,0,1000,0));
    CHECK(registry.control(h,10,0,1,0));
    wait([&]{out->render(1);const auto x=deck(registry.state(h),0);return field(x,"rate")==1&&std::abs(field(x,"positionMs")-1000)<=40&&x.find("\"ready\":true")!=std::string::npos;});
    CHECK(registry.control(h,1,0,0,0));
    std::vector<float> normal;play(9600,&normal);
    CHECK(std::abs(frequency(normal,48000)-440)<440*0.02);
    // A successor deck loads directly at its own track speed; deck 0 is unaffected.
    CHECK(registry.loadSpeed(h,1,"/fake/tone",12,2,0,0.75));
    wait([&]{out->render(1);return deck(registry.state(h),1).find("\"ready\":true")!=std::string::npos;});
    CHECK(field(deck(registry.state(h),1),"rate")==0.75);CHECK(field(deck(registry.state(h),0),"rate")==1);
    CHECK(registry.control(h,8,1,0,0));CHECK(registry.control(h,8,0,0,0));
    wait([&]{out->render(1);return deck(registry.state(h),0).find("\"identity\":0")!=std::string::npos&&deck(registry.state(h),1).find("\"identity\":0")!=std::string::npos;});
    CHECK(registry.close(h));CHECK(testDecoders==0);
    std::cout<<"PASS ordinary speed: initial/handoff rate without ramp or traversal change, exact source advance, pitch preserved, seek, recovery, single natural end, reset, per-deck load speed, crossfade at speed\n";
}

// Production map, ScheduleWorker, Signalsmith DSP, Engine and V2 Host admission.
// Only encoded IO and device output are deterministic test boundaries.
#include "callback_host.hpp"
#include "schedule_worker.hpp"
#include "soundq_tempo_map.hpp"
#include <cassert>
#include <chrono>
#include <cmath>
#include <iostream>
#include <limits>
#include <string>
#include <thread>
#include <vector>
using namespace soundq::nativeengine;
namespace t = soundq::transport;
extern std::atomic<int> testDecoders;
#ifdef SOUNDQ_CALLBACK_TEST_BARRIERS
namespace soundq::nativeengine::test { void workerJoin() noexcept {} }
#endif
struct OutputProbe final : Output {
    Callbacks* cb = nullptr;
    bool open(Callbacks& target,uint32_t& rate) override { cb=&target;rate=44100;return true; }
    bool start() override {return true;}
    bool stopClose() override {return true;}
    int32_t xRuns() const noexcept override {return 0;}
    double energy=0;unsigned finiteSamples=0;
    void block(){float pcm[512]{};cb->render(pcm,256);for(float sample:pcm){assert(std::isfinite(sample));assert(std::abs(sample)<=1);energy+=sample*sample;++finiteSamples;}}
};
static double field(const std::string& json,const std::string& key) {
    const auto at=json.find("\""+key+"\":");assert(at!=std::string::npos);
    return std::stod(json.substr(at+key.size()+3));
}
static int producerPayloads() {
    std::string name;size_t count=0;unsigned cases=0,failed=0;
    while(std::cin>>name>>count) {
        assert(count==2);
        std::vector<int64_t> values(count*6);std::vector<double> tempo(count*8),positions(count);
        for(auto& v:values)assert(bool(std::cin>>v));
        for(auto& v:tempo)assert(bool(std::cin>>v));
        for(auto& v:positions)assert(bool(std::cin>>v));
        Registry host;auto output=std::make_unique<OutputProbe>();auto* out=output.get();
        const auto handle=host.open(std::move(output));assert(handle);
        const std::vector<std::string> paths{"/fake/tone-a","/fake/tone-b"};
        uint64_t revision=0;
        const auto prepare=[&](const std::vector<double>& t,const std::vector<int64_t>& v){return host.prepareScheduleV2(handle,++revision,paths,v,t);};
        const bool accepted=prepare(tempo,values);
        std::cout<<(accepted?"PASS ":"FAIL ")<<"serialized Kotlin -> real Host/Schedule "<<name<<std::endl;
        failed+=!accepted;++cases;
        if(accepted) {
            assert(host.arrangement(handle,6,0)); // discard; all refusals below must leave fresh admission usable
            // Exact discriminators, finite fields, plain zero, and unchanged admission bounds.
            for(double marker:{-1.,.5,1.5,2.5,3.5,4.,4294967297.}) {
                auto bad=tempo;bad[6]=marker;assert(!prepare(bad,values));
            }
            auto bad=tempo;bad[6]=0;assert(!prepare(bad,values)); // zero must be all-zero
            for(unsigned offset=0;offset<8;++offset)for(double nonfinite:{std::numeric_limits<double>::infinity(),std::numeric_limits<double>::quiet_NaN()}) {
                bad=tempo;bad[offset]=nonfinite;assert(!prepare(bad,values));
            }
            auto plain=tempo;std::fill(plain.begin(),plain.begin()+8,0.0);
            assert(prepare(plain,values));assert(host.arrangement(handle,6,0));
            // No phase claim: the neutral unclaimed zero remains safe for policies 2/3.
            if(name!="legacy") {
                auto unclaimed=tempo;unclaimed[5]=unclaimed[13]=0;
                assert(prepare(unclaimed,values));assert(host.arrangement(handle,6,0));
            }
            bad=tempo;bad[6]=2;bad[2]=bad[1]+1;assert(!prepare(bad,values));
            bad=tempo;bad[1]=bad[2]=601;assert(!prepare(bad,values));
            auto bounds=values;bounds[2]=10001;assert(!prepare(tempo,bounds));
            if(name!="legacy") {
                bad=tempo;bad[6]=bad[14]=1;assert(!prepare(bad,values)); // old phase/law contract still strict
                bad=tempo;bad[14]=name.find("independent")!=std::string::npos?3:2;assert(!prepare(bad,values));
            }
            if(name.find("auto-")!=std::string::npos) {
                for(unsigned offset:{1u,2u,3u,4u,7u}) {
                    bad=tempo;bad[8+offset]+=offset==7?-1:.01;
                    if(offset==7)bad[15]=1-tempo[15];
                    assert(!prepare(bad,values)); // law/curve mismatch never admitted
                }
            }
            assert(prepare(tempo,values));assert(host.arrangement(handle,4,0));
            const auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(15);
            const auto ready=[&]{
                while(host.state(handle).find("\"scheduleReady\":true")==std::string::npos) {
                    assert(std::chrono::steady_clock::now()<deadline);out->block();std::this_thread::yield();
                }
            };
            ready();const uint64_t seekMs=name=="legacy"?2500:7500;
            assert(host.arrangement(handle,3,seekMs));out->block();ready();
            auto state=host.state(handle);assert(field(state,"globalFrame")==seekMs*44100/1000);
            auto decks=state.substr(state.find("\"decks\":["));
            for(size_t i=0;i<count;++i) {
                const auto at=decks.find("\"identity\":"+std::to_string(i+1)+",");assert(at!=std::string::npos);
                const auto member=decks.substr(at,decks.find('}',at)-at);
                assert(std::abs(field(member,"sourceFrame")-positions[i]*32)<1e-6);
                assert(field(member,"missingPcmFrames")==0);
                assert(field(member,"processingEpoch")==revision);
            }
            assert(host.arrangement(handle,1,0));
            const auto initial=field(state,"globalFrame");
            while(field(host.state(handle),"globalFrame")<initial+8192) {
                assert(std::chrono::steady_clock::now()<deadline);out->block();std::this_thread::yield();
            }
            assert(out->finiteSamples>0 && out->energy>.01);
            assert(host.arrangement(handle,2,0));out->block();
            std::cout<<"PASS "<<name<<" strict refusals, exact source positions, two real tempo workers and finite audible PCM\n";
        }
        assert(host.close(handle));assert(testDecoders==0);
    }
    assert(cases==7);
    return failed?1:0;
}
int main(int argc,char**) {
    if(argc>1)return producerPayloads();
    constexpr uint32_t rate=44100;
    constexpr double original=120.25;
    for (double held : {137.1234567, 101.9876543}) {
    const double ratio=held/original;
    t::ScheduleClip clip{1,0,22050,463050,0,320000,32000,320000,0,0,1};
    clip.tempo={true,0,original,held,held,22050,66150,1234.5};
    auto schedule=t::Schedule::compile(1,rate,{clip});assert(schedule);
    const auto& compiled=schedule->clips.front();
    assert(compiled.tempo.startBpm==held && compiled.tempo.endBpm==held);
    const auto expectedEnd=clip.start+static_cast<uint64_t>(std::ceil(320000.0/32000*rate/ratio));
    assert(compiled.end==expectedEnd);
    for(double frame:{22050.,44100.,66150.,200000.}) {
        assert(std::abs(t::tempoRate(compiled,frame)-ratio)<1e-14);
        const double expected=(frame-22050.)/rate*32000*ratio;
        assert(std::abs(t::sourceAt(compiled,frame,rate)-expected)<1e-8);
    }
    assert(t::sourceAt(compiled,compiled.end-1,rate)<320000);
    assert(t::sourceAt(compiled,compiled.end,rate)>=320000);
    std::cout<<"PASS precise held BPM, non-unit map, inverse endpoint and source anchor\n";
    // Execute the worker's real processed PCM through the engine. The source is
    // a phase-continuous 440 Hz tone, not a rate-one/constant-sample surrogate.
    t::Engine engine(rate); uint64_t sequence=0;t::Snapshot snap{};
    float output[512]{};
    assert(engine.installSchedule(++sequence,schedule.get(),clip.start));
    engine.render(output,0);assert(engine.snapshot(snap));
    const std::vector<std::string> paths{"/fake/tone"};
    {
        ScheduleWorker worker(0,*schedule,paths,engine,sequence);
        const auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(10);
        while(!worker.ready(snap)) {
            worker.pump(snap);engine.render(output,0);assert(engine.snapshot(snap));
            assert(std::chrono::steady_clock::now()<deadline);std::this_thread::yield();
        }
        assert(engine.scheduleTransport(++sequence,1,1,0));
        std::vector<float> samples;
        // This exercises streaming callback coverage, not an eager offline render.
        // Pace one output second by the declared output clock so the asynchronous
        // refill worker is not asked to supply it in a few milliseconds.
        const auto renderStart=std::chrono::steady_clock::now();
        while(samples.size()<rate) {
            worker.pump(snap);engine.render(output,256);assert(engine.snapshot(snap));
            for(unsigned i=0;i<256;++i)samples.push_back(output[i*2]);
            std::this_thread::sleep_until(renderStart+std::chrono::nanoseconds(samples.size()*1000000000ULL/rate));
        }
        assert(snap.decks[0].processingEpoch==1);
        assert(std::abs(snap.decks[0].effectiveBpm-held)<1e-10);
        assert(std::abs(snap.decks[0].sourceFrame-t::sourceAt(compiled,snap.globalFrame,rate))<1e-8);
        // Ignore startup/edge priming. Positive zero crossings give a period
        // independent of production timing math. Test both tempo directions below.
        std::vector<double> crossings;
        for(size_t i=rate/4;i<samples.size();++i) if(samples[i-1]<=0 && samples[i]>0)
            crossings.push_back(i-1+double(-samples[i-1])/(samples[i]-samples[i-1]));
        assert(crossings.size()>100);
        const double hz=(crossings.size()-1)*rate/(crossings.back()-crossings.front());
        assert(std::abs(hz-440)<2);
        assert(std::abs(hz-440*ratio)>30); // ordinary resampling would fail
        assert(snap.decks[0].missingPcmFrames==0);
        std::cout<<"PASS actual processed held tempo ratio="<<ratio<<" pitch="<<hz<<"Hz epoch="<<snap.decks[0].processingEpoch<<'\n';
        assert(engine.installSchedule(++sequence,nullptr,0));engine.render(output,0);
    }
    assert(testDecoders==0);
    Registry host;auto probe=std::make_unique<OutputProbe>();auto* out=probe.get();
    const auto handle=host.open(std::move(probe));assert(handle);
    // Same six-long/eight-double payload the Android authoring path sends.
    assert(host.prepareScheduleV2(handle,1,{"/fake/tone"},{500,0,10000,0,0,0},
        {original,held,held,500,1500,38.578125,1,0}));
    assert(host.arrangement(handle,4,0));
    const auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(10);
    while(host.state(handle).find("\"scheduleReady\":true")==std::string::npos) {
        assert(std::chrono::steady_clock::now()<deadline);out->block();std::this_thread::yield();
    }
    assert(host.arrangement(handle,1,0));out->block();
    assert(host.close(handle));assert(testDecoders==0);
    std::cout<<"PASS exact native V2 constant payload admission/install/play/close\n";
    }
}

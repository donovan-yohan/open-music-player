// Generated source boundary, real WorkerDeck + speed processor + callback Engine.
#include "worker_deck.hpp"
#include <atomic>
#include <cassert>
#include <chrono>
#include <cmath>
#include <iostream>
#include <thread>
using namespace soundq::nativeengine;
using namespace soundq::transport;
namespace soundq::nativeengine::test {void workerJoin() noexcept {}}
struct Generated final:PcmReader {
    static inline std::atomic<uint64_t> reads{0},samples{0},lowest{~uint64_t{0}},opens{0},closes{0};
    static constexpr uint64_t length=48000ULL*12600; // 3.5 hours, no recording-sized allocation
    uint64_t end=0;
    Generated(){++opens;}~Generated() override{++closes;}
    uint32_t sampleRate()const override{return 48000;}
    uint64_t endFrames()const override{return end;}
    int read(uint64_t first,uint32_t count,float* out,size_t bytes,uint32_t& n)override {
        assert(bytes>=size_t{count}*8);++reads;samples+=count;
        auto low=lowest.load();while(first<low&&!lowest.compare_exchange_weak(low,first)){}
        n=first>=length?0:static_cast<uint32_t>(std::min<uint64_t>(count,length-first));
        for(uint32_t i=0;i<n;++i)out[2*i]=out[2*i+1]=float(.125*std::sin(2*3.141592653589793*440*(first+i)/48000));
        if(first+n>=length)end=length;
        return 0;
    }
};
int main(int argc,char**) {
    const bool fast=argc>1;
    Engine engine(48000);uint64_t seq=0;
    WorkerDeck worker(0,engine,seq);
    auto factory=std::make_shared<const PcmReaderFactory>([]{return std::make_unique<Generated>();});
    const uint64_t target=48000ULL*10800; // direct 3-hour resume
    assert(worker.replaceReader(factory,7,1,10800000,fast?1.5:1));
    Snapshot s{};
    const auto until=std::chrono::steady_clock::now()+std::chrono::seconds(20);
    auto step=[&]{engine.render(nullptr,0);assert(engine.snapshot(s));worker.pump(s);std::this_thread::sleep_for(std::chrono::milliseconds(1));};
    while(!worker.ready(s)){assert(worker.stats().error==0);assert(std::chrono::steady_clock::now()<until);step();}
    assert(s.decks[0].sourceFrame==target);
    assert(worker.sourceFrames()==0); // tail never touched, not a duration estimate
    assert(Generated::lowest>target-48000*4); // bounded preroll, not whole-prefix discard
    assert(Generated::samples<48000*12);
    assert(worker.stats().poolBytes==8ULL*48000*8);
    assert(engine.submit({Operation::Play,0,++seq,1}));
    float out[4096]{};engine.render(out,2048);assert(engine.snapshot(s));
    double energy=0;unsigned crossings=0;
    for(unsigned i=1;i<2048;++i){energy+=out[i*2]*out[i*2];if((out[(i-1)*2]<0)!=(out[i*2]<0))++crossings;}
    assert(energy>1 && s.decks[0].naturalEndCount==0);
    assert(s.decks[0].sourceFrame==target+(fast?3072:2048));
    const double pitch=crossings/2.0/(2047.0/48000);assert(std::abs(pitch-440)<30);
    std::cout<<"PASS generated 3.5h direct 3h resume: source samples="<<Generated::samples<<" reads="<<Generated::reads<<" pitch="<<pitch<<" first nonzero samples before EOS; pool="<<worker.stats().poolBytes<<"\n";
    assert(worker.retire());engine.render(nullptr,0);assert(worker.retired());
}

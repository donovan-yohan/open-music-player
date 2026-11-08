#include "callback_host.hpp"
#include "soundq_transport.hpp"
#include <array>
#include <atomic>
#include <cassert>
#include <chrono>
#include <cmath>
#include <iostream>
#include <thread>
using namespace soundq::nativeengine;
using namespace soundq::transport;
extern std::atomic<int> testDecoders;
extern std::atomic<bool> testHoldRead,testReadEntered;
std::atomic<bool> joining{false};
namespace soundq::nativeengine::test {void workerJoin() noexcept {if(testHoldRead.load())joining=true;}}
struct Controlled final:Output {
    Callbacks* cb=nullptr;
    bool open(Callbacks& c,uint32_t& rate)override{cb=&c;rate=48000;return true;}
    bool start()override{return true;}bool stopClose()override{return true;}
    int32_t xRuns()const noexcept override{return 0;}
    std::array<float,512> render(uint32_t n=256){std::array<float,512> pcm{};cb->render(pcm.data(),n);return pcm;}
};
std::string deck(const std::string& s,int index) {
    auto at=s.find("\"decks\":[")+9;
    for(int i=0;i<index;++i)at=s.find('}',at)+2;
    return s.substr(at,s.find('}',at)-at+1);
}
template<class Test>void wait(Test test) {
    const auto end=std::chrono::steady_clock::now()+std::chrono::seconds(8);
    while(!test()){assert(std::chrono::steady_clock::now()<end);std::this_thread::yield();}
}
void exactCore() {
    Engine e(48000);std::array<float,128> a{},b{};
    for(unsigned i=0;i<64;++i){a[2*i]=float(i+1)/256;b[2*i+1]=float(i+2)/256;}
    PcmWindow aw{},bw{};aw.count=bw.count=1;aw.pages[0]={a.data(),0,64};bw.pages[0]={b.data(),0,64};
    assert(e.assignPaged(0,1,1,{64,48000,11},aw));assert(e.assignPaged(1,2,2,{64,48000,12},bw));
    std::array<float,128> pcm{};e.render(pcm.data(),1);
    assert(e.crossfade(3,0,1,1,2,32));assert(!e.crossfade(4,0,9,1,2,32));
    assert(e.submit({Operation::Play,0,5,1}));e.render(pcm.data(),40);
    for(unsigned f=0;f<40;++f){const auto phase=std::max(0.,double(f)-32)/32*1.57079632679489661923;
        assert(std::abs(pcm[2*f]-a[2*f]*std::cos(phase))<1e-7);
        assert(std::abs(pcm[2*f+1]-(f<32?0:b[2*(f-32)+1]*std::sin(phase)))<1e-7);}
    Snapshot before;assert(e.snapshot(before));assert(before.decks[1].sourceFrame==8);
    // Revoke one side's residency mid-fade: silence/hold BOTH, no false EOF.
    PcmWindow absent{};assert(e.publishWindow(1,6,2,absent));e.render(pcm.data(),8);
    for(unsigned i=0;i<16;++i)assert(pcm[i]==0);
    Snapshot held;assert(e.snapshot(held));assert(held.decks[0].sourceFrame==before.decks[0].sourceFrame&&held.decks[1].sourceFrame==8);
    assert(held.decks[0].eofCount==0&&held.decks[1].eofCount==0);
    assert(e.publishWindow(1,7,2,bw));assert(e.submit({Operation::Pause,1,8,2}));e.render(pcm.data(),1);
    assert(e.snapshot(held));assert(!held.decks[0].playing&&!held.decks[1].playing);
    assert(e.submit({Operation::Play,1,9,2}));e.render(pcm.data(),24);
    assert(e.snapshot(held));assert(held.decks[0].eofCount==1&&held.decks[1].sourceFrame==32);
    // Cancel keeping incoming. Other is stopped; gain is unity on same cursor.
    assert(e.crossfade(10,1,2,0,1,0));e.render(pcm.data(),1);
    assert(std::abs(pcm[1]-b[65])<1e-7);assert(e.completedStructuralSequence()>=10);
}
int main() {
    exactCore();Registry registry;auto output=std::make_unique<Controlled>();auto* out=output.get();const auto h=registry.open(std::move(output));assert(h);
    assert(registry.load(h,0,"/fake/outgoing",11,1,6000));
    wait([&]{out->render(1);return deck(registry.state(h),0).find("\"ready\":true")!=std::string::npos;});
    assert(registry.control(h,1,0,0,0));auto audible=out->render();assert(audible[0]==.125f);
    // Actual second WorkerDeck decoder read held across its own retirement.
    testReadEntered=false;testHoldRead=true;
    assert(registry.load(h,1,"/fake/incoming",12,2,0));registry.state(h);
    wait([&]{return testReadEntered.load();});assert(testDecoders==2);
    assert(registry.control(h,8,1,0,0));std::atomic<bool> settled{false};
    std::thread cleanup([&]{registry.state(h);settled=true;});
    wait([&]{return joining.load();});assert(!settled.load());assert(testDecoders==2);
    audible=out->render();assert(audible[0]==.125f); // existing output continues; no second player
    testHoldRead=false;cleanup.join();assert(settled&&testDecoders==1);
    assert(deck(registry.state(h),1).find("\"identity\":0")!=std::string::npos);
    assert(registry.load(h,1,"/fake/incoming",13,3,0));
    wait([&]{out->render(1);return deck(registry.state(h),1).find("\"ready\":true")!=std::string::npos;});
    assert(registry.crossfade(h,0,1,1,3,2000));
    for(unsigned i=0;i<1000;++i){registry.state(h);out->render();std::this_thread::sleep_for(std::chrono::microseconds(100));}
    assert(testDecoders==2); // natural EOF or dominance cannot destroy borrowed source
    assert(registry.control(h,8,0,0,0));
    assert(deck(registry.state(h),0).find("\"identity\":11")!=std::string::npos);
    wait([&]{out->render(1);return deck(registry.state(h),0).find("\"identity\":0")!=std::string::npos;});
    assert(testDecoders==1);assert(registry.close(h));assert(testDecoders==0);
    std::cout<<"PASS ordinary pair every-sample gains, missing-page atomic hold, pause/resume, stale generation, exact EOF, held second-decoder read/join and source unassign retirement\n";
}

#include "callback_host.hpp"
#include <cassert>
#include <chrono>
#include <cmath>
#include <fstream>
#include <iostream>
#include <thread>
#include <vector>
using namespace soundq::nativeengine;
struct FakeOutput : Output {
    Callbacks* callback=nullptr;
    bool open(Callbacks& c,uint32_t& rate)override{callback=&c;rate=48000;return true;}
    bool start()override{return true;}bool stopClose()override{return true;}int32_t xRuns()const noexcept override{return 0;}
    void render(float* p,uint32_t n){callback->render(p,n);}
};
int main(int argc,char**argv) {
    assert(argc==4); Registry registry;
    auto owned=std::make_unique<FakeOutput>();auto* output=owned.get();const auto h=registry.open(std::move(owned));assert(h);
    // Five successive groups of four instances. All share verified immutable file
    // bytes but retain independent decoder/cursor/bank identity.
    std::vector<std::string> paths;std::vector<int64_t> values;
    for(int group=0;group<5;++group) for(int deck=0;deck<4;++deck) {
        paths.emplace_back(argv[1+deck%2]);
        values.insert(values.end(),{group*3000,100,3100,100,100});
    }
    auto invalid=values;invalid[2]=999999;
    assert(!registry.prepareSchedule(h,100,paths,invalid));
    assert(registry.prepareSchedule(h,101,paths,values));assert(registry.arrangement(h,4,0));
    float silence[512]{};
    std::string state;
    for(unsigned i=0;i<20000;++i){state=registry.state(h);output->render(silence,1);if(state.find("\"scheduleReady\":true")!=std::string::npos)break;std::this_thread::sleep_for(std::chrono::microseconds(100));}
    assert(state.find("\"scheduleReady\":true")!=std::string::npos);
    // Prime staged successors without advancing the paused global clock.
    for(unsigned i=0;i<100;++i){registry.state(h);output->render(silence,1);std::this_thread::sleep_for(std::chrono::microseconds(100));}
    assert(registry.arrangement(h,1,0));
    std::vector<float> samples(720000*2);
    for(unsigned at=0;at<720000;at+=256){const auto count=std::min(256U,720000-at);registry.state(h);output->render(samples.data()+size_t{at}*2,count);std::this_thread::sleep_for(std::chrono::microseconds(100));}
    state=registry.state(h);std::cout<<state<<'\n';
    assert(state.find("\"scheduleEnded\":true")!=std::string::npos);
    assert(state.find("\"missingPcmFrames\":0")!=std::string::npos);
    std::ofstream capture(argv[3],std::ios::binary);capture.write(reinterpret_cast<const char*>(samples.data()),static_cast<std::streamsize>(samples.size()*sizeof(float)));capture.close();
    // Paused global seek, all active sources primed before explicit resume.
    assert(registry.arrangement(h,3,1500));
    for(unsigned i=0;i<20000;++i){state=registry.state(h);output->render(silence,1);if(state.find("\"scheduleReady\":true")!=std::string::npos && state.find("\"globalFrame\":72000")!=std::string::npos)break;std::this_thread::sleep_for(std::chrono::microseconds(100));}
    assert(state.find("\"globalFrame\":72000")!=std::string::npos);
    assert(registry.arrangement(h,1,0));output->render(silence,256);
    std::ofstream seek(std::string(argv[3])+".seek",std::ios::binary);seek.write(reinterpret_cast<const char*>(silence),sizeof(silence));seek.close();
    assert(registry.arrangement(h,2,0));output->render(silence,256);
    assert(registry.state(h).find("\"globalFrame\":72256")!=std::string::npos);
    for(float x:silence)assert(x==0);
    assert(registry.arrangement(h,5,0));
    for(unsigned i=0;i<100;++i){output->render(silence,1);state=registry.state(h);if(state.find("\"scheduleRevision\":0")!=std::string::npos)break;}
    assert(state.find("\"scheduleRevision\":0")!=std::string::npos);
    assert(registry.load(h,0,argv[1],200,200,0));
    assert(registry.close(h));
    std::cout<<"PASS real file decoder + sole Host/Engine output: 20 metadata, four simultaneous, current/next turnover, EOF bounds, seek, retirement, ordinary return\n";
}

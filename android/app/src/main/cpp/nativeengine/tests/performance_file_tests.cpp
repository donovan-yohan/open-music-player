#include "callback_host.hpp"
#include <cassert>
#include <chrono>
#include <fstream>
#include <iostream>
#include <thread>
#include <vector>
using namespace soundq::nativeengine;
struct Device final:Output {
    Callbacks* callback=nullptr;
    bool open(Callbacks& c,uint32_t& r)override{callback=&c;r=48000;return true;}
    bool start()override{return true;}bool stopClose()override{return true;}int32_t xRuns()const noexcept override{return 0;}
};
uint64_t now(){return static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now().time_since_epoch()).count());}
int main(int argc,char** argv){
    assert(argc==6);Registry r;auto dev=std::make_unique<Device>();auto* d=dev.get();auto h=r.open(std::move(dev));assert(h);
    std::vector<std::string> paths{argv[1],argv[2],argv[3],argv[4]};
    std::vector<int64_t> values;for(int i=0;i<4;++i)values.insert(values.end(),{0,100,12100,0,0});
    assert(r.prepareSchedule(h,1,paths,values));assert(r.arrangement(h,4,0));
    float buffer[512]{};std::string state;
    auto ready=[&]{for(int i=0;i<1000;++i){d->callback->render(buffer,1);state=r.state(h);if(state.find("\"scheduleReady\":true")!=std::string::npos)return;std::this_thread::sleep_for(std::chrono::milliseconds(1));}assert(false);};
    ready();assert(r.arrangement(h,3,3000));ready();assert(r.arrangement(h,1,0));
    std::ofstream audio(std::string(argv[5])+".f32",std::ios::binary),trace(std::string(argv[5])+".jsonl");
    uint64_t global=144000;unsigned blocks=0;
    auto render=[&](unsigned count){d->callback->render(buffer,count);audio.write(reinterpret_cast<char*>(buffer),count*2*sizeof(float));global+=count;++blocks;std::this_thread::sleep_for(std::chrono::milliseconds(6));};
    auto action=[&](int op,double rate){const auto t=now();assert(r.scratch(h,op,1,1,t,rate));trace<<"{\"global\":"<<global<<",\"operation\":"<<op<<",\"rate\":"<<rate<<",\"eventNanos\":"<<t<<"}\n";};
    // Prime playback so Begin captures an acknowledged active cursor.
    render(256);action(1,0);render(256);
    for(int i=0;i<260;++i){const double rate=i<20?.00001:i<130?-2.:i<240?2.:0.;action(2,rate);render(256);}
    action(2,1);render(256);for(int i=0;i<8;++i)render(256); // watchdog without ANY Kotlin/state polls
    action(3,0);render(256);
    trace<<"{\"global\":"<<global<<",\"sync\":true}\n";
    assert(r.sync(h,2,3,1,127,150, -1,103,225,-1));
    // Actual maintenance alone must stage distant sync target and refill peers.
    for(int i=0;i<500;++i)render(256);
    state=r.state(h);std::cout<<state<<'\n';
    assert(state.find("\"syncState\":2")!=std::string::npos);
    assert(state.find("\"scratching\":true")==std::string::npos);
    assert(state.find("\"missingPcmFrames\":0")!=std::string::npos);
    // Full worker budget cannot be bypassed by a synchronous metadata probe.
    assert(!r.prepareSchedule(h,2,paths,values));
    assert(r.state(h).find("\"decoderPermits\":4")!=std::string::npos);
    trace<<"{\"global\":"<<global<<",\"finalState\":"<<state<<"}\n";
    assert(!r.scratch(h,2,1,1,now(),1));
    assert(r.arrangement(h,2,0));d->callback->render(buffer,256);
    assert(r.arrangement(h,5,0));for(int i=0;i<100;++i){d->callback->render(buffer,1);if(r.state(h).find("\"scheduleRevision\":0")!=std::string::npos)break;std::this_thread::sleep_for(std::chrono::milliseconds(1));}
    assert(r.close(h));std::cout<<"PASS generated actual files four-voice reverse refill, native maintenance without UI poll, live sync, bounded telemetry, retire blocks="<<blocks<<'\n';
}

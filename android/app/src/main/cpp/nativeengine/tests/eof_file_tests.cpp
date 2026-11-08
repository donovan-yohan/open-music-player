#include "callback_host.hpp"
#include "sq_file_decoder.h"
#include <cassert>
#include <chrono>
#include <fstream>
#include <iostream>
#include <thread>
#include <vector>
using namespace soundq::nativeengine;
struct OutputFixture : Output {
    Callbacks* callback=nullptr;
    bool open(Callbacks& c,uint32_t& rate)override{callback=&c;rate=48000;return true;}
    bool start()override{return true;}bool stopClose()override{return true;}int32_t xRuns()const noexcept override{return 0;}
    void render(float* p,uint32_t n){callback->render(p,n);}
};
int main(int argc,char**argv) {
    assert(argc==5);
    const std::vector<std::string> paths{argv[1],argv[2]};
    uint64_t frames[2]{};uint32_t rates[2]{};
    for(unsigned i=0;i<2;++i) {
        sq_file_decoder* d=nullptr;assert(sq_file_decoder_open(paths[i].c_str(),SQ_FILE_MAX_FILE_BYTES,&d)==0);
        frames[i]=sq_file_decoder_frame_count(d);rates[i]=sq_file_decoder_sample_rate(d);sq_file_decoder_destroy(d);
        assert(frames[i]>0 && rates[i]>0);
    }
    Registry registry;auto owned=std::make_unique<OutputFixture>();auto* output=owned.get();const auto h=registry.open(std::move(owned));assert(h);
    // Catalog rounds 3.8s / 3.608...s to 4s. Sixth value marks only a full-source end.
    std::vector<int64_t> values{123,100,4000,100,200,4000, 1500,100,4000,100,200,4000};
    if(std::string(argv[4])=="controls") {
        auto explicitEnd=values;explicitEnd[5]=0;assert(!registry.prepareSchedule(h,1,paths,explicitEnd));
        auto tinyExplicit=values;tinyExplicit[2]=3801;tinyExplicit[5]=0;assert(!registry.prepareSchedule(h,1,paths,tinyExplicit));
        auto tinyFull=values;tinyFull[2]=tinyFull[5]=3801;
        auto large=values;large[2]=large[5]=5000;assert(!registry.prepareSchedule(h,1,paths,large));
        auto threshold=values;threshold[2]=threshold[5]=4800;assert(!registry.prepareSchedule(h,1,paths,threshold));
        auto atEnd=values;atEnd[1]=3800;assert(!registry.prepareSchedule(h,1,paths,atEnd));
        auto empty=values;empty[1]=3900;assert(!registry.prepareSchedule(h,1,paths,empty));
        auto forged=values;forged[5]=3999;assert(!registry.prepareSchedule(h,1,paths,forged));
        // A refused candidate cannot poison the next admission or retain decoders.
        assert(registry.prepareSchedule(h,1,paths,{0,100,2000,0,0, 1500,100,2000,0,0}));
        assert(registry.arrangement(h,6,0));
        auto within=values;within[2]=within[5]=4799;
        assert(registry.prepareSchedule(h,2,paths,within));assert(registry.arrangement(h,6,0));
        auto under=values;under[2]=under[5]=3000;
        assert(registry.prepareSchedule(h,3,paths,under));assert(registry.arrangement(h,6,0));
        assert(registry.prepareSchedule(h,4,paths,tinyFull));assert(registry.arrangement(h,6,0));
        assert(registry.close(h));
        std::cout<<"PASS explicit overshoot, >=1s discrepancy, empty decoded selection, malformed end marker, legacy strict payload and discard\n";return 0;
    }
    if(std::string(argv[4])=="legacy-rounded") {
        values={123,100,4000,100,200,1500,100,4000,100,200};
        assert(registry.prepareSchedule(h,1,paths,values));
        return 0;
    }
    assert(registry.prepareSchedule(h,1,paths,values));assert(registry.arrangement(h,4,0));
    float scratch[512]{};std::string state;
    for(unsigned i=0;i<20000;++i){state=registry.state(h);output->render(scratch,1);if(state.find("\"scheduleReady\":true")!=std::string::npos)break;std::this_thread::sleep_for(std::chrono::microseconds(100));}
    assert(state.find("\"scheduleReady\":true")!=std::string::npos);
    // Native duration uses ceil of exact fractional duration, not floor(decoded ms).
    uint64_t duration=0;
    for(unsigned i=0;i<2;++i) {
        const uint64_t numerator=(frames[i]*1000-uint64_t{100}*rates[i])*48000;
        const uint64_t denominator=uint64_t{1000}*rates[i];
        const uint64_t end=uint64_t{i?1500U:123U}*48+(numerator+denominator-1)/denominator;
        duration=std::max(duration,end);
        std::cout<<"source "<<i<<" frames="<<frames[i]<<" rate="<<rates[i]<<" end="<<end<<'\n';
    }
    assert(state.find("\"durationFrames\":"+std::to_string(duration))!=std::string::npos);
    assert(registry.arrangement(h,1,0));std::vector<float> samples((duration+256)*2);
    for(uint64_t at=0;at<duration+256;at+=256){const auto count=static_cast<uint32_t>(std::min(uint64_t{256},duration+256-at));registry.state(h);output->render(samples.data()+at*2,count);std::this_thread::sleep_for(std::chrono::microseconds(150));}
    state=registry.state(h);std::cout<<state<<'\n';assert(state.find("\"scheduleEnded\":true")!=std::string::npos);
    assert(state.find("\"scheduleError\":0")!=std::string::npos);
    std::ofstream capture(argv[3],std::ios::binary);capture.write(reinterpret_cast<const char*>(samples.data()),samples.size()*sizeof(float));capture.close();
    assert(registry.arrangement(h,5,0));
    for(unsigned i=0;i<100;++i){output->render(scratch,1);state=registry.state(h);if(state.find("\"scheduleRevision\":0")!=std::string::npos)break;}
    assert(state.find("\"openDecoders\":0")!=std::string::npos);assert(registry.close(h));
    std::cout<<"PASS rounded full-source EOF actual Host, exact frame duration, callback capture and decoder retirement\n";
}

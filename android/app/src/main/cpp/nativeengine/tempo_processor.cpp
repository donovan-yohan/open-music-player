#include "tempo_processor.hpp"
#include "soundq_tempo_map.hpp"
#include "signalsmith-stretch.h"
#include <algorithm>
#include <array>
#include <cmath>
#include <vector>
namespace soundq::nativeengine {
struct TempoProcessor::Impl {
    const transport::ScheduleClip c;const uint32_t outputRate;
    const uint64_t extent;
    signalsmith::stretch::SignalsmithStretch<float> stretch{12345};
    std::array<std::vector<float>,2> cache;
    std::array<std::vector<float>,2> input;
    std::array<std::array<float,128>,2> output{};
    std::vector<float> decoded;
    uint64_t cacheFirst=~uint64_t{0}, origin=0, produced=0;
    int64_t previous=0, decodedFirst=-1;uint32_t decodedCount=0;
    unsigned inputLatency=0, outputLatency=0;
    int status=0;
    Impl(const transport::ScheduleClip& clip,uint32_t rate):c(clip),outputRate(rate),extent(transport::preparedExtent(c,rate)),decoded(16384*2) {
        stretch.presetDefault(2,c.sourceRate,true);stretch.setTransposeFactor(1);
        inputLatency=stretch.inputLatency();outputLatency=stretch.outputLatency();
        for(auto& v:input)v.resize(std::max<unsigned>(inputLatency,512));
        for(auto& v:cache)v.resize(tempoPageFrames*2);
    }
    double map(double u)const {
        return transport::sourceAt(c,static_cast<double>(c.start)+u*outputRate/c.sourceRate,outputRate);
    }
    float sample(sq_file_decoder* decoder,int64_t frame,unsigned channel) {
        if(status)return 0;
        if(frame<static_cast<int64_t>(std::ceil(c.trimIn)) || frame>=static_cast<int64_t>(std::ceil(c.trimOut)))return 0;
        if(decodedFirst<0 || frame<decodedFirst || frame>=decodedFirst+decodedCount) {
            decodedFirst=frame/16384*16384;
            const auto count=static_cast<uint32_t>(std::min<uint64_t>(16384,c.sourceFrames-static_cast<uint64_t>(decodedFirst)));
            status=sq_file_decoder_read_window(decoder,decodedFirst,count,decoded.data(),decoded.size()*sizeof(float),&decodedCount);
            if(status || decodedCount!=count){status=status?status:SQ_FILE_DECODE;return 0;}
        }
        return decoded[size_t(frame-decodedFirst)*2+channel];
    }
    void reset(sq_file_decoder* decoder,uint64_t first) {
        // Re-prime only for a discontinuous seek/bank reassignment. Normal forward
        // refills retain exact processor history and the overlapping cached page.
        const uint64_t history=uint64_t{inputLatency+outputLatency}*2;
        origin=first>history?first-history:0;produced=0;decodedFirst=-1;status=0;
        stretch.reset();
        const int64_t start=static_cast<int64_t>(std::llround(map(static_cast<double>(origin))));
        for(unsigned n=0;n<inputLatency;++n)for(unsigned ch=0;ch<2;++ch)input[ch][n]=sample(decoder,start+n,ch);
        float* in[]={input[0].data(),input[1].data()};
        const double global=static_cast<double>(c.start)+static_cast<double>(origin)*outputRate/c.sourceRate;
        stretch.seek(in,static_cast<int>(inputLatency),transport::tempoRate(c,global));
        previous=start+inputLatency;
    }
    void process(sq_file_decoder* decoder,uint64_t first,uint32_t count,float* target) {
        const uint64_t wantedEnd=first+count+outputLatency;
        while(origin+produced<wantedEnd && !status) {
            const auto n=static_cast<unsigned>(std::min<uint64_t>(128,wantedEnd-origin-produced));
            const auto end=static_cast<int64_t>(inputLatency)+static_cast<int64_t>(std::llround(map(static_cast<double>(origin+produced+n))));
            const auto take=end-previous;
            if(take<0 || take>static_cast<int64_t>(input[0].size())){status=SQ_FILE_LIMIT;break;}
            for(int64_t j=0;j<take;++j)for(unsigned ch=0;ch<2;++ch)input[ch][j]=sample(decoder,previous+j,ch);
            float* in[]={input[0].data(),input[1].data()};float* out[]={output[0].data(),output[1].data()};
            stretch.process(in,static_cast<int>(take),out,static_cast<int>(n));
            for(unsigned j=0;j<n;++j) {
                const int64_t u=static_cast<int64_t>(origin+produced+j)-outputLatency;
                if(u<static_cast<int64_t>(first) || u>=static_cast<int64_t>(first+count))continue;
                // Strict finite half-open output and a 128-PCM-frame edge declick.
                // This clips spectral tails deliberately, it is not natural EOF.
                const double edge=std::clamp(std::min(static_cast<double>(u)/128.,static_cast<double>(extent-1-static_cast<uint64_t>(u))/128.),0.,1.);
                for(unsigned ch=0;ch<2;++ch){const double v=output[ch][j]*edge;if(!std::isfinite(v)){status=SQ_FILE_DECODE;break;}target[size_t(u-static_cast<int64_t>(first))*2+ch]=static_cast<float>(std::clamp(v,-1.,1.));}
            }
            previous=end;produced+=n;
        }
    }
    int window(sq_file_decoder* decoder,uint64_t first,float* a,uint32_t& na,float* b,uint32_t& nb) {
        if(first>=extent)return SQ_FILE_INVALID_ARGUMENT;
        na=static_cast<uint32_t>(std::min<uint64_t>(tempoPageFrames,extent-first));
        nb=static_cast<uint32_t>(std::min<uint64_t>(tempoPageFrames,extent-first-na));
        if(cacheFirst!=first) {
            if(cacheFirst!=~uint64_t{0} && first==cacheFirst+tempoPageFrames) {
                cache[0].swap(cache[1]);
            }else {reset(decoder,first);process(decoder,first,na,cache[0].data());}
            if(nb)process(decoder,first+na,nb,cache[1].data());
            cacheFirst=first;
        }
        if(status)return status;
        std::copy_n(cache[0].data(),size_t{na}*2,a);if(nb)std::copy_n(cache[1].data(),size_t{nb}*2,b);
        return 0;
    }
};
TempoProcessor::TempoProcessor(const transport::ScheduleClip& c,uint32_t outputRate):impl(std::make_unique<Impl>(c,outputRate)){}
TempoProcessor::~TempoProcessor()=default;
int TempoProcessor::window(sq_file_decoder* d,uint64_t first,float* a,uint32_t& na,float* b,uint32_t& nb){return impl->window(d,first,a,na,b,nb);}
}

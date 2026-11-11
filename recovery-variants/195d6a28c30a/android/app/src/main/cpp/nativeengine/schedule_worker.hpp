#pragma once
#include "soundq_transport.hpp"
#include "soundq_tempo_map.hpp"
#include "tempo_processor.hpp"
#include "sq_file_decoder.h"
#include "decoder_budget.hpp"
#include <algorithm>
#include <array>
#include <atomic>
#include <condition_variable>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <vector>
namespace soundq::nativeengine {
#ifdef SOUNDQ_CALLBACK_TEST_BARRIERS
namespace test { void workerJoin() noexcept; }
#endif
// One worker/decoder per colored slot. Current and next sources each retain
// two resident + two refill pages. Reopening a decoder never replaces a current
// descriptor, so staged source IO cannot unassign an on-air peer.
class ScheduleWorker {
    using Schedule=transport::Schedule;
    static constexpr uint32_t N=transport::maxPcmPageFrames;
    struct Bank {
        int clip=-1; unsigned half=0; uint64_t first=~uint64_t{0}, second=~uint64_t{0}, receipt=0;
        bool ready=false; int error=0; transport::PcmWindow window{};
        // A queued refill has not replaced the callback's immutable residency.
        // Retain only the acknowledged predecessor descriptor until its replacing
        // post-block receipt; these views borrow the existing two page halves.
        int acknowledgedClip=-1; transport::PcmWindow acknowledgedWindow{};
    };
    struct Task { unsigned bank=0,half=0; int clip=-1; uint64_t first=0,second=0; transport::ScheduleClip descriptor{}; uint64_t tag=0,currentTag=0; bool stage=false,replay=false; transport::PcmWindow oldWindow{}; transport::ScheduleClip oldClip{}; uint64_t boundary=0; };
    struct Reply { Task task; transport::PcmWindow window; int error=0; };
    const Schedule* schedule; const uint32_t outputRate; const std::vector<std::string>& paths;
    transport::Engine& engine; uint64_t& sequence; unsigned slot;
    std::array<std::unique_ptr<float[]>,8> pages;
    bool slotHasTempo=false;
    std::array<std::unique_ptr<float[]>,4> livePages;
    uint64_t lawTag=0,stagedTag=0,continuityUntil=0,stageBoundary=0;unsigned liveHalf=0;int stagedClip=-1,continuationClip=-1;
    uint64_t lastFrame=0;bool replayHistory=false;
    bool stageHeld=false;transport::PcmWindow stagedWindow{};int stageError=0;
    std::array<Bank,2> banks{};
    std::mutex mutex; std::condition_variable changed;
    std::optional<Task> task; std::optional<Reply> reply;
    bool stop=false,busy=false; std::thread thread;
    std::atomic<uint32_t> openCount{0};
    void run() {
        sq_file_decoder* decoder=nullptr; int openedClip=-1;DecoderPermit permit;
        std::array<std::unique_ptr<TempoProcessor>,2> processors;std::array<int,2> processorClips{{-1,-1}};
        std::array<uint64_t,2> processorTags{},processorFirst{};std::array<bool,2> processorReplay{};std::unique_ptr<TempoProcessor> stagedProcessor;uint64_t processorStageTag=0,processorStageFirst=0;int processorStageClip=-1;
        for(;;) {
            Task t;
            {std::unique_lock<std::mutex> lock(mutex);changed.wait(lock,[&]{return stop||task.has_value();});if(stop)break;t=*task;task.reset();}
            Reply r{t,{},0}; const auto& c=t.descriptor;
            if(openedClip!=t.clip) {
                sq_file_decoder_destroy(decoder); decoder=nullptr;openCount.store(0,std::memory_order_relaxed);
                if(!permit.acquire())r.error=SQ_FILE_LIMIT;
                else r.error=sq_file_decoder_open(paths[t.clip].c_str(),SQ_FILE_MAX_FILE_BYTES,&decoder);
                if(decoder)openCount.store(1,std::memory_order_relaxed);
                openedClip=t.clip;
            }
            if(!r.error && !decoder)r.error=SQ_FILE_DECODE;
            // Stage with the continuation law, as before. Historical prefix is
            // only for explicit replay; including it in DSP pre-roll changes attacks.
            try { if(c.tempo.preserve && !r.error) {
                TempoProcessor* processor=nullptr;
                if(t.stage){if(stagedProcessor && processorStageTag==t.currentTag && processorStageClip==t.clip){processors[t.bank]=std::move(stagedProcessor);processorClips[t.bank]=t.clip;processorTags[t.bank]=t.currentTag;processorFirst[t.bank]=processorStageFirst;}stagedProcessor.reset();auto continuation=c;continuation.tempoHistory.clear();stagedProcessor=std::make_unique<TempoProcessor>(continuation,outputRate);processorStageTag=t.tag;processorStageClip=t.clip;processorStageFirst=t.first;processor=stagedProcessor.get();}
                else {
                    if(processorClips[t.bank]!=t.clip || processorTags[t.bank]!=t.tag || t.first<processorFirst[t.bank] || processorReplay[t.bank]!=t.replay){
                        if(stagedProcessor && processorStageTag==t.tag && processorStageClip==t.clip && !t.replay)processors[t.bank]=std::move(stagedProcessor);
                        else {processors[t.bank].reset();auto descriptor=c;if(!t.replay)descriptor.tempoHistory.clear();processors[t.bank]=std::make_unique<TempoProcessor>(descriptor,outputRate);}
                        processorClips[t.bank]=t.clip;processorTags[t.bank]=t.tag;processorReplay[t.bank]=t.replay;
                    }
                    processor=processors[t.bank].get();processorFirst[t.bank]=t.first;
                }
                auto* a=t.stage?livePages[t.half*2].get():pages[t.bank*4+t.half*2].get();auto* b=t.stage?livePages[t.half*2+1].get():pages[t.bank*4+t.half*2+1].get();uint32_t na=0,nb=0;
                r.error=processor->window(decoder,t.first,a,na,b,nb);
                if(t.stage && !r.error){
                    const auto boundary=static_cast<uint64_t>(transport::preparedAt(c,t.boundary,outputRate));
                    for(uint64_t at=std::max(t.first,boundary);at<std::min(t.first+na+nb,boundary+512);++at){
                        const double global=c.start+double(at)*outputRate/c.sourceRate;
                        const double old=t.oldClip.tempo.preserve?double(global-t.oldClip.start)*c.sourceRate/outputRate:transport::sourceAt(t.oldClip,global,outputRate);
                        const auto tap=static_cast<uint64_t>(std::max(0.,old));const float* x=nullptr;const float* y=nullptr;
                        for(unsigned j=0;j<t.oldWindow.count;++j){const auto& p=t.oldWindow.pages[j];if(tap>=p.firstFrame && tap-p.firstFrame<p.frames)x=p.samples+(tap-p.firstFrame)*2;if(tap+1>=p.firstFrame && tap+1-p.firstFrame<p.frames)y=p.samples+(tap+1-p.firstFrame)*2;}
                        if(!x || !y){r.error=SQ_FILE_LIMIT;break;}
                        float* dest=at<t.first+na?a+(at-t.first)*2:b+(at-t.first-na)*2;
                        const double mix=double(at-boundary)/512,frac=old-tap;
                        for(unsigned ch=0;ch<2;++ch)dest[ch]=static_cast<float>((1-mix)*(x[ch]*(1-frac)+y[ch]*frac)+mix*dest[ch]);
                    }
                }
                if(!r.error){r.window.pages[r.window.count++]={a,t.first,na};if(nb)r.window.pages[r.window.count++]={b,t.first+na,nb};}
            }
            for(unsigned i=0;i<2 && !r.error && !c.tempo.preserve;++i) {
                const auto first=i?t.second:t.first; if(first>=c.sourceFrames || (i && first==t.first))break;
                const auto count=static_cast<uint32_t>(std::min<uint64_t>(N,c.sourceFrames-first));
                auto* data=pages[t.bank*4+t.half*2+i].get(); uint32_t read=0;
                r.error=sq_file_decoder_read_window(decoder,static_cast<int64_t>(first),count,data,size_t{N}*8,&read);
                if(!r.error && count!=read)r.error=SQ_FILE_DECODE;
                if(!r.error)r.window.pages[r.window.count++]={data,first,count};
            }
            } catch(...) {r.error=SQ_FILE_OUT_OF_MEMORY;r.window={};}
            if(r.window.count==2 && r.window.pages[0].firstFrame>r.window.pages[1].firstFrame)std::swap(r.window.pages[0],r.window.pages[1]);
            {std::lock_guard<std::mutex> lock(mutex); reply=r;}
        }
        sq_file_decoder_destroy(decoder);
    }
public:
    ScheduleWorker(unsigned slot,const Schedule& s,const std::vector<std::string>& p,transport::Engine& e,uint64_t& seq)
        :schedule(&s),outputRate(s.outputRate),paths(p),engine(e),sequence(seq),slot(slot) {
        for(const auto& c:schedule->clips)if(c.slot==slot && c.tempo.preserve)slotHasTempo=true;
        for(auto& p:pages)p=std::make_unique<float[]>(size_t{N}*2);
        for(auto& p:livePages)p=std::make_unique<float[]>(size_t{tempoPageFrames}*2);
        thread=std::thread([this]{run();});
    }
    ~ScheduleWorker(){
        {std::lock_guard<std::mutex> lock(mutex);stop=true;}changed.notify_one();
#ifdef SOUNDQ_CALLBACK_TEST_BARRIERS
        test::workerJoin();
#endif
        thread.join();
    }
    bool idle()const{return !busy && !stageHeld;}
    bool stageTempo(const Schedule& graph,uint64_t tag,uint64_t boundary) {
        if(!idle())return false;
        for(size_t i=0;i<graph.clips.size();++i){const auto& c=graph.clips[i];if(c.slot!=slot || boundary<c.start || boundary>=c.end)continue;
            const auto bank=graph.banks[i];const auto& b=banks[bank];
            if(!b.ready || b.clip!=static_cast<int>(i) || engine.completedStructuralSequence()<b.receipt)return false;
            const auto& old=schedule->clips[i];
            const auto sourceFirst=old.tempo.preserve?transport::preparedAt(old,boundary,outputRate):transport::sourceAt(old,boundary,outputRate);
            const auto sourceLast=old.tempo.preserve?sourceFirst+514:transport::sourceAt(old,boundary+static_cast<uint64_t>(std::ceil(514.*outputRate/c.sourceRate)),outputRate);
            auto has=[&](uint64_t tap){for(unsigned j=0;j<b.window.count;++j){const auto& p=b.window.pages[j];if(tap>=p.firstFrame && tap-p.firstFrame<p.frames)return true;}return false;};
            if(!has(static_cast<uint64_t>(sourceFirst)) || !has(static_cast<uint64_t>(sourceLast)+1))return false;
            const auto first=static_cast<uint64_t>(transport::preparedAt(c,boundary,outputRate))/tempoPageFrames*tempoPageFrames;
            Task next{};next.bank=bank;next.half=1-liveHalf;next.clip=static_cast<int>(i);next.first=first;next.descriptor=c;next.tag=tag;next.currentTag=lawTag;next.stage=true;next.oldWindow=b.window;next.oldClip=schedule->clips[i];next.boundary=boundary;
            {std::lock_guard<std::mutex> lock(mutex);task=next;busy=true;stageHeld=true;stagedTag=0;stageError=0;stagedWindow={};stageBoundary=boundary;stagedClip=static_cast<int>(i);}changed.notify_one();slotHasTempo=true;return true;
        }return false;
    }
    bool staged(uint64_t tag)const{return stagedTag==tag;}
    int stagedError()const{return stageError;}
    const transport::PcmWindow& tempoWindow()const{return stagedWindow;}
    void finishTempo(const Schedule& graph,uint64_t tag,bool applied,uint64_t receipt) {
        if(applied){
            schedule=&graph;lawTag=tag;continuationClip=stagedClip;
            for(size_t i=0;i<graph.clips.size();++i){const auto& c=graph.clips[i];if(static_cast<int>(i)!=stagedClip)continue;auto& b=banks[graph.banks[i]];if(b.clip!=static_cast<int>(i))continue;
                continuityUntil=stageBoundary+static_cast<uint64_t>(std::ceil(513.*outputRate/c.sourceRate));
                b.window=stagedWindow;b.first=stagedWindow.pages[0].firstFrame;b.second=b.first+tempoPageFrames;b.receipt=receipt;b.ready=true;b.error=0;b.acknowledgedClip=-1;break;
            }
            liveHalf=1-liveHalf;
        }
        stageHeld=false;stagedTag=0;stagedWindow={};stageError=0;stagedClip=-1;
    }
    void graphChanged(const Schedule& graph){schedule=&graph;}
    int error()const{for(const auto& b:banks)if(b.error)return b.error;return 0;}
    uint64_t errorInstance()const{for(const auto& b:banks)if(b.error && b.clip>=0)return schedule->clips[b.clip].instance;return 0;}
    uint32_t openDecoders()const{return openCount.load(std::memory_order_relaxed);}
    // Conservative two current-bank + one pending DSP reserve at 192k PCM rate.
    // Measured constructor upper-sum is 4045016 per bank; reserve rounds upward
    // for ABI/vector allocator overhead. This is a budget, not measured RSS.
    uint64_t tempoAllocationUpperBytes()const{return slotHasTempo?uint64_t{3}*8*1024*1024+uint64_t{4}*tempoPageFrames*2*sizeof(float):uint64_t{4}*tempoPageFrames*2*sizeof(float);}
    bool ready(const transport::Snapshot& snap)const {
        const auto frame=snap.globalFrame;
        const auto completed=engine.completedStructuralSequence();
        int wanted=-1;
        for(unsigned i=0;i<schedule->clips.size();++i){const auto& c=schedule->clips[i];if(c.slot==slot && c.end>frame && (wanted<0 || c.start<schedule->clips[wanted].start))wanted=static_cast<int>(i);}
        for(unsigned i=0;i<schedule->clips.size();++i) {const auto& c=schedule->clips[i];if(static_cast<int>(i)!=wanted)continue;
            const auto& b=banks[schedule->banks[i]];const auto cursor=c.tempo.preserve?transport::preparedAt(c,std::max(frame,c.start),schedule->outputRate):snap.decks[slot].identity==c.instance?snap.decks[slot].sourceFrame:transport::sourceAt(c,std::max(frame,c.start),schedule->outputRate);
            if(b.clip!=static_cast<int>(i)||!b.ready||b.error)return false;
            const bool pending=completed<b.receipt;
            if(pending && b.acknowledgedClip!=static_cast<int>(i))return false;
            const auto& window=pending?b.acknowledgedWindow:b.window;
            auto has=[&](uint64_t tap){for(unsigned j=0;j<window.count;++j){const auto& p=window.pages[j];if(tap>=p.firstFrame && tap-p.firstFrame<p.frames)return true;}return false;};
            const auto extent=c.tempo.preserve?transport::preparedExtent(c,schedule->outputRate):c.sourceFrames;
            const auto tap=static_cast<uint64_t>(std::clamp(cursor,0.,static_cast<double>(extent-1)));
            const auto next=c.tempo.preserve?static_cast<uint64_t>(std::min<double>(extent-1,cursor+256.*c.sourceRate/schedule->outputRate+1)):std::min(tap+1,extent-1);
            if(!has(tap)||!has(next))return false;
        }return true;
    }
    void pump(const transport::Snapshot& snap) {
        const auto frame=snap.globalFrame;
        if(frame<lastFrame){replayHistory=true;continuationClip=-1;continuityUntil=0;for(auto& b:banks)if(b.clip>=0 && schedule->clips[b.clip].tempo.preserve)b.ready=false;}
        lastFrame=frame;
        const auto completed=engine.completedStructuralSequence();
        {std::unique_lock<std::mutex> lock(mutex,std::try_to_lock);
         if(lock.owns_lock() && reply) {
            auto& r=*reply;auto& b=banks[r.task.bank];
            if(!r.task.stage && r.task.replay!=(replayHistory && r.task.clip!=continuationClip)){reply.reset();busy=false;return;}
            if(r.task.stage){stagedTag=r.task.tag;stagedWindow=r.window;stageError=r.error;reply.reset();busy=false;return;}
            if(r.error){
                if(!engine.bindSchedule(++sequence,schedule->revision,schedule->clips[r.task.clip].instance,{}))return;
                b.clip=r.task.clip;b.error=r.error;b.ready=false;b.receipt=sequence;reply.reset();busy=false;
            }
            else if(engine.bindSchedule(++sequence,schedule->revision,schedule->clips[r.task.clip].instance,r.window)) {
                b.acknowledgedClip=b.ready && completed>=b.receipt?b.clip:-1;
                b.acknowledgedWindow=b.acknowledgedClip>=0?b.window:transport::PcmWindow{};
                b.clip=r.task.clip;b.half=r.task.half;b.first=r.task.first;b.second=r.task.second;b.window=r.window;b.ready=true;b.error=0;b.receipt=sequence;reply.reset();busy=false;
            }
         }}
        if(busy || stageHeld)return;
        // Current or nearest future occurrence in each bank. More distant metadata
        // never overwrites a still-on-air bank, including four-active turnover.
        unsigned activeBank=0;
        for(unsigned i=0;i<schedule->clips.size();++i){const auto& c=schedule->clips[i];if(c.slot==slot && c.start<=frame && c.end>frame)activeBank=schedule->banks[i];}
        for(unsigned order=0;order<2;++order) {
            const unsigned bank=(activeBank+order)%2;
            int wanted=-1;
            for(unsigned i=0;i<schedule->clips.size();++i){const auto& c=schedule->clips[i];if(c.slot==slot && schedule->banks[i]==bank && c.end>frame && (wanted<0||c.start<schedule->clips[wanted].start))wanted=static_cast<int>(i);}
            if(wanted<0)continue;
            auto& b=banks[bank];const auto& c=schedule->clips[wanted];
            if(completed<b.receipt || (b.clip==wanted && b.error) || (frame>=stageBoundary && frame<continuityUntil))continue;
            if(b.clip!=wanted && b.clip>=0) {
                // A bank can be reused only once its old half-open interval ended,
                // or the graph is paused for a seek. Unbind ACK fences page reuse.
                if(!engine.bindSchedule(++sequence,schedule->revision,schedule->clips[b.clip].instance,{}))continue;
                b.receipt=sequence;b.clip=-1;b.ready=false;continue;
            }
            const auto& d=snap.decks[slot];
            const bool actual=d.identity==c.instance && frame>=c.start;
            const auto extent=c.tempo.preserve?transport::preparedExtent(c,schedule->outputRate):c.sourceFrames;
            const auto position=c.tempo.preserve?transport::preparedAt(c,std::max(frame,c.start),schedule->outputRate):actual?d.sourceFrame:transport::sourceAt(c,std::max(frame,c.start),schedule->outputRate);
            const auto cursor=static_cast<uint64_t>(std::clamp(position,0.,static_cast<double>(extent-1)));
            // Half-page quantization retains bidirectional headroom. Pending sync
            // stages a distant target in the second page without stealing a bank.
            auto centered=[&](uint64_t at){const auto bucket=at/(N/2)*(N/2);return bucket>N/4?bucket-N/4:uint64_t{0};};
            auto first=c.tempo.preserve?cursor/tempoPageFrames*tempoPageFrames:centered(cursor);
            uint64_t second=first+(c.tempo.preserve?tempoPageFrames:N);
            const double demand=actual && d.demandSourceFrame>=0?d.demandSourceFrame:actual && d.scratching?d.nominalSourceFrame:-1;
            if(demand>=0 && !c.tempo.preserve) {
                const auto target=static_cast<uint64_t>(std::clamp(demand,0.,static_cast<double>(c.sourceFrames-1)));
                if(target<first || target+1>=first+N)second=centered(target);
                if(second!=first && second<first+N && second+N>first){first=std::min(first,second);second=first+N;}
            }
            if(b.clip==wanted && b.ready && first==b.first && second==b.second)continue;
            Task next{};next.bank=bank;next.half=1-b.half;next.clip=wanted;next.first=first;next.second=second;next.descriptor=c;next.tag=lawTag;next.replay=replayHistory && wanted!=continuationClip;
            {std::lock_guard<std::mutex> lock(mutex);task=next;busy=true;}changed.notify_one();return;
        }
    }
};
}

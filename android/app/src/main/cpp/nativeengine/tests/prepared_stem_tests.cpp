#include "callback_host.hpp"
#include "sq_file_decoder.h"
#include "soundq_transport.hpp"
#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <functional>
#include <memory>
#include <mutex>
#include <set>
#include <thread>

namespace soundq::transport::test {
extern std::atomic<unsigned> holdStage, reachedStage;
}
namespace {
using namespace soundq::nativeengine;
using namespace soundq::transport;
using Clock = std::chrono::steady_clock;
constexpr uint32_t rate=48000, frames=4096, first=64, end=2640, ramp=480;
constexpr uint32_t page=8192, longFrames=6*page+997;
constexpr uint64_t identity=715, generation=19;
void require(bool ok, const char* label) {
    if(!ok) { std::fprintf(stderr,"FAIL: %s\n",label); std::exit(1); }
}
thread_local bool onOutput = false;
struct Sink final : Output {
    Callbacks* callbacks=nullptr;
    unsigned& stops;
    explicit Sink(unsigned& stopCount):stops(stopCount){}
    bool open(Callbacks& c,uint32_t& r) override {callbacks=&c;r=rate;return true;}
    bool start() override {return true;}
    bool stopClose() override {++stops;callbacks=nullptr;return true;}
    int32_t xRuns() const noexcept override {return 0;}
    void render(float* pcm,unsigned n) {
        onOutput=true;callbacks->render(pcm,n);onOutput=false;
    }
};
float stem(unsigned n,unsigned c) {return c ? -0.125f+float(n%7)/256 : 0.25f+float(n%11)/128;}
float dry(unsigned n,unsigned c) {return stem(n,c)+(c ? 0.375f-float(n%17)/128 : -0.125f+float(n%19)/256);}
void wav(const std::string& path,float (*sample)(unsigned,unsigned), unsigned length=frames) {
    std::ofstream out(path,std::ios::binary|std::ios::trunc);
    const auto le=[&](uint32_t value,unsigned bytes){for(unsigned i=0;i<bytes;++i)out.put(static_cast<char>(value>>(8*i)));};
    out.write("RIFF",4);le(36+length*8,4);out.write("WAVEfmt ",8);
    le(16,4);le(3,2);le(2,2);le(rate,4);le(rate*8,4);le(8,2);le(32,2);
    out.write("data",4);le(length*8,4);
    for(unsigned i=0;i<length;++i)for(unsigned c=0;c<2;++c){const float in=sample(i,c);uint32_t bits;std::memcpy(&bits,&in,4);le(bits,4);}
    out.close();require(bool(out),"generated WAV written");
}
std::vector<float> prepare(const std::string& path) {
    sq_file_decoder* raw=nullptr;
    require(sq_file_decoder_open(path.c_str(),SQ_FILE_MAX_FILE_BYTES,&raw)==SQ_FILE_OK,"real stem WAV decoder open");
    const std::unique_ptr<sq_file_decoder,decltype(&sq_file_decoder_destroy)> decoder(raw,sq_file_decoder_destroy);
    require(sq_file_decoder_channels(raw)==2 && sq_file_decoder_sample_rate(raw)==rate && sq_file_decoder_frame_count(raw)==frames,"exact decoded stem geometry");
    std::vector<float> pcm((end-first)*2);uint32_t count=0;
    require(sq_file_decoder_read_window(raw,first,end-first,pcm.data(),pcm.size()*sizeof(float),&count)==SQ_FILE_OK && count==end-first,"real stem decode window");
    for(unsigned i=first;i<end;++i)for(unsigned c=0;c<2;++c)require(pcm[(i-first)*2+c]==stem(i,c),"decoded member matches independent generator");
    return pcm;
}
struct Trial {
    unsigned stops=0;
    Registry registry;
    Sink* sink=nullptr;
    uint64_t handle=0;
    unsigned cursor=0;
    explicit Trial(const std::string& path,double speed=1,bool autoplay=true) {
        auto output=std::make_unique<Sink>(stops);sink=output.get();handle=registry.open(std::move(output));
        require(handle && registry.loadSpeed(handle,0,path,identity,generation,0,speed),"actual Host open and WorkerDeck load");
        ready();
        if(autoplay)require(registry.control(handle,1,0,0,0),"original Play");
    }
    std::string deck() {
        const auto state=registry.state(handle);
        const auto at=state.find("\"decks\":[{");
        require(at!=std::string::npos,"actual Host deck state");
        return state.substr(at,state.find('}',at)-at);
    }
    void ready() {
        const auto deadline=Clock::now()+std::chrono::seconds(3);
        std::array<float,256*2> paused{};
        while(deck().find("\"ready\":true")==std::string::npos) {
            require(Clock::now()<deadline,"original readiness deadline");
            sink->callbacks->render(paused.data(),256);
            std::this_thread::sleep_for(std::chrono::microseconds(100));
        }
    }
    void source(unsigned frame, uint64_t gen=generation) {
        const auto state=deck();
        require(state.find("\"sourceFrame\":"+std::to_string(frame)+",")!=std::string::npos &&
                state.find("\"generation\":"+std::to_string(gen)+",")!=std::string::npos &&
                state.find("\"identity\":"+std::to_string(identity)+",")!=std::string::npos &&
                state.find("\"missingPcmFrames\":0,")!=std::string::npos,"exact original position/generation and no dry PCM miss");
    }
    void ack(uint64_t seq,StemResult result,uint64_t binding,uint64_t misses=0) {
        StemReceipt receipt;
        require(seq && registry.readPreparedStem(handle,receipt) && receipt.sequence==seq && receipt.result==result &&
                receipt.binding==binding && receipt.missingFrames==misses,"post-block exact stem command receipt");
        std::printf("ack,%llu,%llu,%llu,%llu\n",static_cast<unsigned long long>(seq),static_cast<unsigned long long>(result),
                    static_cast<unsigned long long>(binding),static_cast<unsigned long long>(misses));
    }
    template<class Law> void play(unsigned until, const char* stage, Law delta,float cancellationTolerance=0) {
        while(cursor<until) {
            std::array<float,256*2> pcm{};
            const auto n=std::min(256U,until-cursor);
            const auto t=Clock::now();sink->render(pcm.data(),n);
            const auto ns=std::chrono::duration_cast<std::chrono::nanoseconds>(Clock::now()-t).count();
            if(n==256) std::printf("timing_ns,%s,%lld\n",stage,static_cast<long long>(ns));
            for(unsigned i=0;i<n;++i) {
                const unsigned f=cursor+i;const double d=delta(f);
                const float l=static_cast<float>(dry(f,0)+d*stem(f,0)),r=static_cast<float>(dry(f,1)+d*stem(f,1));
                if(i==0 || i==n-1 || std::memcmp(&l,&pcm[i*2],4) || std::memcmp(&r,&pcm[i*2+1],4))
                    std::printf("%s,%u,%.9g,%.9g,%.9g,%.9g\n",stage,f,pcm[i*2],pcm[i*2+1],l,r);
                const auto equal=[&](float expected,const float& actual){return !std::memcmp(&expected,&actual,4) ||
                    (cancellationTolerance && std::abs(actual-expected)<=cancellationTolerance);};
                require(equal(l,pcm[i*2]) && equal(r,pcm[i*2+1]),stage);
            }
            cursor+=n;
        }
    }
    void close() {require(registry.close(handle) && stops==1,"exact output stop and WorkerDeck drain");}
};
const auto unity=[](unsigned){return 0.;};
const auto muted=[](unsigned){return -1.;};
constexpr PreparedStemKey key{identity,generation,frames,rate};
void switches(const std::string& original,const std::vector<float>& pcm) {
    Trial t(original);
    t.play(73,"dry",unity);
    auto binding=t.registry.bindPreparedStem(t.handle,key,first,pcm);
    StemReceipt before;
    require(binding && t.registry.readPreparedStem(t.handle,before) && before.sequence==0 &&
            !t.registry.setPreparedStemGain(t.handle,binding,0),"bind admission is not native ACK");
    t.play(153,"bound_unity",unity);
    t.ack(binding,StemResult::Bound,binding);
    auto seq=t.registry.retirePreparedStem(t.handle,binding);
    t.play(181,"unity_off",unity);
    t.ack(seq,StemResult::Retired,0);
    const auto old=binding;
    {
        auto callerBytes=pcm;
        binding=t.registry.bindPreparedStem(t.handle,key,first,callerBytes);
        require(binding>old,"new window after retirement");
        std::fill(callerBytes.begin(),callerBytes.end(),-0.9f);
    }
    t.play(205,"rebound_unity",unity);
    t.ack(binding,StemResult::Bound,binding);
    require(!t.registry.setPreparedStemGain(t.handle,old,0),"retired binding cannot act on new window");
    seq=t.registry.setPreparedStemGain(t.handle,binding,0);
    t.play(1001,"mute",[](unsigned f){return -std::min(1.,double(f-204)/ramp);});
    t.ack(seq,StemResult::GainApplied,binding);
    seq=t.registry.retirePreparedStem(t.handle,binding);
    t.play(1018,"hard_bypass_refused",muted);
    t.ack(seq,StemResult::Refused,binding);
    seq=t.registry.setPreparedStemGain(t.handle,binding,1);
    t.play(1118,"partial_unmute",[](unsigned f){return -(1.-double(f-1017)/ramp);});
    t.ack(seq,StemResult::GainApplied,binding);
    seq=t.registry.setPreparedStemGain(t.handle,binding,0);
    t.play(1598,"reverse_ramp",[](unsigned f){return -(1.-(100./ramp)*(1.-double(f-1117)/ramp));});
    t.ack(seq,StemResult::GainApplied,binding);
    seq=t.registry.setPreparedStemGain(t.handle,binding,1);
    t.play(2078,"smooth_bypass",[](unsigned f){return -(1.-double(f-1597)/ramp);});
    t.ack(seq,StemResult::GainApplied,binding);
    t.source(2078);

    seq=t.registry.retirePreparedStem(t.handle,binding);
    require(seq,"post-ramp retirement admitted");
    test::reachedStage.store(0);test::holdStage.store(3);
    std::thread callback([&]{t.play(2115,"post_retire_dry",unity);});
    const auto deadline=Clock::now()+std::chrono::seconds(2);
    while(test::reachedStage.load()!=3 && Clock::now()<deadline) std::this_thread::yield();
    const bool held=test::reachedStage.load()==3;
    const bool prematureAck=held && t.registry.readPreparedStem(t.handle,before);
    const auto prematureBind=held ? t.registry.bindPreparedStem(t.handle,key,first,pcm) : 0;
    test::holdStage.store(0);callback.join();
    require(held && !prematureAck && !prematureBind,"published snapshot is not post-block ACK or storage release");
    t.ack(seq,StemResult::Retired,0);
    t.play(frames,"dry_through_eof",unity);
    t.source(frames);
    require(t.deck().find("\"naturalEndCount\":1,")!=std::string::npos,"original natural EOF once");
    std::array<float,256*2> after;
    after.fill(-10.f);t.sink->callbacks->render(after.data(),256);
    require(std::all_of(after.begin(),after.end(),[](float v){return v==0.f;}),"post-EOF output silence");
    t.close();
}
void misses(const std::string& original,const std::vector<float>& pcm) {
    Trial t(original);
    t.play(11,"miss_trial_dry",unity);
    const auto binding=t.registry.bindPreparedStem(t.handle,key,first,pcm);
    t.play(23,"future_window_unity",unity);
    t.ack(binding,StemResult::Bound,binding);
    auto seq=t.registry.setPreparedStemGain(t.handle,binding,0);
    t.play(73,"precoverage_refused",unity);
    t.ack(seq,StemResult::Refused,binding);
    seq=t.registry.setPreparedStemGain(t.handle,binding,0);
    t.play(end-1-ramp,"miss_trial_mute",[](unsigned f){return -std::min(1.,double(f-72)/ramp);});
    t.ack(seq,StemResult::GainApplied,binding);
    t.play(end,"window_end_taper",[](unsigned f){return -double(end-1-f)/ramp;});
    t.play(end+67,"missing_safe_dry",unity);
    t.ack(seq,StemResult::GainApplied,binding,67);
    seq=t.registry.setPreparedStemGain(t.handle,binding,0);
    t.play(end+98,"expired_window_refused",unity);
    t.ack(seq,StemResult::Refused,binding,98);
    seq=t.registry.retirePreparedStem(t.handle,binding);
    t.play(end+133,"expired_window_retired",unity);
    t.ack(seq,StemResult::Retired,0,98);
    t.source(end+133);
    t.close();
}
void stale(const std::string& original,const std::vector<float>& pcm) {
    Trial t(original);
    t.play(83,"generation_dry",unity);
    require(!t.registry.bindPreparedStem(t.handle,{identity+1,generation,frames,rate},first,pcm) &&
            !t.registry.bindPreparedStem(t.handle,{identity,generation,frames-1,rate},first,pcm) &&
            !t.registry.bindPreparedStem(t.handle,key,frames-1,pcm),"wrong occurrence, extent and window rejected");
    auto binding=t.registry.bindPreparedStem(t.handle,key,first,pcm);
    t.play(97,"pre_replace_unity",unity);
    t.ack(binding,StemResult::Bound,binding);
    require(t.registry.load(t.handle,0,original,identity,generation+1,0),"same identity, newer generation replacement admitted");
    auto seq=t.registry.setPreparedStemGain(t.handle,binding,0);
    std::array<float,512> paused{};t.sink->callbacks->render(paused.data(),256);
    t.ack(seq,StemResult::Refused,binding);
    seq=t.registry.retirePreparedStem(t.handle,binding);
    t.sink->callbacks->render(paused.data(),256);
    t.ack(seq,StemResult::Retired,0);
    t.ready();t.cursor=0;
    require(!t.registry.bindPreparedStem(t.handle,key,first,pcm),"stale generation window rejected even with same source identity and size");
    require(t.registry.control(t.handle,1,0,0,0),"same identity successor Play");
    t.play(301,"replacement_dry",unity);
    t.source(301,generation+1);
    binding=t.registry.bindPreparedStem(t.handle,{identity,generation+1,frames,rate},first,pcm);
    t.play(317,"successor_unity",unity);
    t.ack(binding,StemResult::Bound,binding);
    require(t.registry.control(t.handle,4,0,0,0) && t.registry.control(t.handle,5,0,-1,1),"ordinary backward scratch still admitted");
    seq=t.registry.setPreparedStemGain(t.handle,binding,0);
    t.sink->callbacks->render(paused.data(),256);
    t.ack(seq,StemResult::Refused,binding);
    require(t.deck().find("\"rate\":-1,")!=std::string::npos,"native signed rate consumed");
    seq=t.registry.retirePreparedStem(t.handle,binding);
    t.sink->callbacks->render(paused.data(),256);
    t.ack(seq,StemResult::Retired,0);
    t.close();
    Trial faster(original,1.25);
    require(!faster.registry.bindPreparedStem(faster.handle,key,first,pcm),"non-unit ordinary speed stem refused");
    faster.sink->callbacks->render(paused.data(),256);
    faster.source(320);
    faster.close();
}
struct MemberTrace {
    struct Read {uint64_t first;uint32_t count;const float* buffer;};
    std::mutex mutex;
    std::condition_variable changed;
    std::vector<Read> history;
    std::atomic<unsigned> opens{0},closes{0};
    std::atomic<uint64_t> shortAt{UINT64_MAX};
    const std::thread::id testThread=std::this_thread::get_id();
    uint64_t holdAt=UINT64_MAX;
    bool held=false;
    void hold(uint64_t firstFrame) {
        std::lock_guard<std::mutex> lock(mutex);holdAt=firstFrame;held=false;
    }
    void awaitHold() {
        std::unique_lock<std::mutex> lock(mutex);
        require(changed.wait_for(lock,std::chrono::seconds(3),[&]{return held;}),"actual member read positively held");
    }
    void release() {
        {std::lock_guard<std::mutex> lock(mutex);holdAt=UINT64_MAX;}
        changed.notify_all();
    }
    void record(Read read) {
        std::unique_lock<std::mutex> lock(mutex);
        history.push_back(read);
        if (read.first==holdAt) {
            held=true;changed.notify_all();
            changed.wait(lock,[&]{return holdAt!=read.first;});
        }
    }
    std::vector<Read> observed() {
        std::lock_guard<std::mutex> lock(mutex);return history;
    }
};
class RealMember final : public PcmReader {
    std::unique_ptr<sq_file_decoder,decltype(&sq_file_decoder_destroy)> decoder_{nullptr,sq_file_decoder_destroy};
    std::shared_ptr<MemberTrace> trace_;
public:
    explicit RealMember(const std::string& path,std::shared_ptr<MemberTrace> trace={}):trace_(std::move(trace)) {
        if(trace_)require(!onOutput && std::this_thread::get_id()!=trace_->testThread,"member open is off callback/control");
        sq_file_decoder* raw=nullptr;
        require(sq_file_decoder_open(path.c_str(),SQ_FILE_MAX_FILE_BYTES,&raw)==SQ_FILE_OK,"real rolling member open");
        decoder_.reset(raw);
        require(sq_file_decoder_channels(raw)==2,"real stereo rolling member");
        if(trace_)++trace_->opens;
    }
    ~RealMember() override {
        if(trace_) {
            require(!onOutput && std::this_thread::get_id()!=trace_->testThread,"member destroy is off callback/control");
            decoder_.reset();++trace_->closes;
        }
    }
    uint32_t sampleRate() const override {return sq_file_decoder_sample_rate(decoder_.get());}
    uint64_t endFrames() const override {return static_cast<uint64_t>(sq_file_decoder_frame_count(decoder_.get()));}
    int read(uint64_t firstFrame,uint32_t count,float* out,size_t capacity,uint32_t& got) override {
        if(trace_)require(!onOutput && std::this_thread::get_id()!=trace_->testThread,"member read is off callback/control");
        const auto result=sq_file_decoder_read_window(decoder_.get(),static_cast<int64_t>(firstFrame),count,out,capacity,&got);
        if(trace_) {
            trace_->record({firstFrame,count,out}); // hold after writes, before worker returns a publishable reply
            if(result==0 && got && firstFrame==trace_->shortAt.load())--got;
        }
        return result;
    }
};
constexpr PreparedStemKey longKey{identity,generation,longFrames,rate};
auto memberFactory(const std::string& member,const std::shared_ptr<MemberTrace>& trace) {
    return std::make_shared<const PcmReaderFactory>([member,trace]{return std::make_unique<RealMember>(member,trace);});
}
template<class Check> void await(Check check,const char* label) {
    const auto deadline=Clock::now()+std::chrono::seconds(3);
    while(!check()) {
        require(Clock::now()<deadline,label);
        std::this_thread::sleep_for(std::chrono::microseconds(100));
    }
}
void drain(Trial& t) {t.sink->render(nullptr,0);}
StemReceipt window(Trial& t,uint64_t firstFrame,uint64_t endFrame) {
    StemReceipt state;
    await([&]{
        t.registry.state(t.handle);drain(t);
        return t.registry.readPreparedStem(t.handle,state) && state.windowFirst==firstFrame && state.windowEnd==endFrame;
    },"exact rolling window acknowledged");
    require(state.windowSequence && state.windowApplied==state.windowSequence,"window has own post-block outcome");
    std::printf("window,%llu,%llu,%llu\n",static_cast<unsigned long long>(state.windowSequence),
        static_cast<unsigned long long>(state.windowFirst),static_cast<unsigned long long>(state.windowEnd));
    return state;
}
void seek(Trial& t,unsigned ms) {
    require(t.registry.control(t.handle,3,0,ms,0),"actual original seek");
    drain(t);t.cursor=48*ms;t.source(t.cursor);
}
void retire(Trial& t,uint64_t binding,uint64_t misses) {
    const auto seq=t.registry.retirePreparedStem(t.handle,binding);
    require(seq,"explicit rolling retire admitted");
    drain(t);StemReceipt state;
    await([&]{return t.registry.readPreparedStem(t.handle,state) && state.sequence==seq;},"rolling decoder drain and structural retire");
    t.ack(seq,StemResult::Retired,0,misses);
}
void holdPostBlock(Trial& t,const std::function<void()>& observe) {
    test::reachedStage.store(0);test::holdStage.store(3);
    std::thread callback([&]{drain(t);});
    await([]{return test::reachedStage.load()==3;},"callback held after snapshot, before FIFO completion");
    observe();
    test::holdStage.store(0);callback.join();
}
void rolling(const std::string& directory) {
    const auto original=directory+"/rolling-stem-original.wav",member=directory+"/rolling-stem-member.wav";
    wav(original,dry,longFrames);wav(member,stem,longFrames);
    Trial t(original,1,false);
    const auto trace=std::make_shared<MemberTrace>();
    const auto factory=memberFactory(member,trace);
    trace->hold(0);
    const auto binding=t.registry.bindRollingPreparedStem(t.handle,longKey,factory);
    require(binding,"explicit rolling attachment");
    drain(t);
    t.ack(binding,StemResult::Bound,binding);
    trace->awaitHold();
    const auto premature=t.registry.setPreparedStemGain(t.handle,binding,0);
    drain(t);t.ack(premature,StemResult::Refused,binding);
    trace->release();window(t,0,2*page);
    const auto gain=t.registry.setPreparedStemGain(t.handle,binding,0);
    require(t.registry.control(t.handle,1,0,0,0),"play rolling original");
    t.play(ramp,"rolling_initial_ramp",[](unsigned f){return -double(f+1)/ramp;});
    t.ack(gain,StemResult::GainApplied,binding);
    t.play(page+256,"rolling_first_contiguous_edge",muted);
    for(unsigned i=1;i<=5;++i) {
        const auto endFrame=std::min((i+2)*page,longFrames);
        window(t,i*page,endFrame);
        t.play(std::min((i+1)*page+11,endFrame-ramp),"rolling_contiguous_edge",muted);
    }
    const auto reads=trace->observed();std::set<const float*> buffers;
    require(reads.size()==7 && trace->opens==1,"seven bounded windows through one real member decoder");
    for(unsigned i=0;i<reads.size();++i) {
        buffers.insert(reads[i].buffer);
        require(reads[i].first==i*page && reads[i].count==std::min(page,longFrames-i*page),"aligned reads and exact partial tail");
    }
    require(buffers.size()==3,"fixed two callback pages plus one spare, recycled across refills");
    t.play(longFrames,"rolling_partial_final_taper",[](unsigned f){return -std::min(1.,double(longFrames-1-f)/ramp);});
    t.source(longFrames);
    require(t.deck().find("\"naturalEndCount\":1,")!=std::string::npos,"rolling original natural end exactly once");
    retire(t,binding,0);
    require(trace->closes==1,"ACK returned after actual member close");
    t.close();
}
void rollingCustody(const std::string& directory) {
    const auto original=directory+"/custody-stem-original.wav",member=directory+"/custody-stem-member.wav";
    wav(original,dry,longFrames);wav(member,stem,longFrames);
    Trial t(original,1,false);
    const auto trace=std::make_shared<MemberTrace>();
    const auto factory=memberFactory(member,trace);
    const auto binding=t.registry.bindRollingPreparedStem(t.handle,longKey,factory);
    window(t,0,2*page);
    trace->hold(2*page);
    auto seq=t.registry.setPreparedStemGain(t.handle,binding,0);
    require(t.registry.control(t.handle,1,0,0,0),"play custody original");
    t.play(ramp,"starvation_start_ramp",[](unsigned f){return -double(f+1)/ramp;});
    t.ack(seq,StemResult::GainApplied,binding);
    t.play(page+23,"starvation_before_held_fill",muted);
    t.registry.state(t.handle);trace->awaitHold();
    t.play(2*page,"starvation_preemptive_taper",[](unsigned f){return -std::min(1.,double(2*page-1-f)/ramp);});
    t.play(2*page+67,"starvation_exact_dry_no_stall",unity);
    t.source(2*page+67);
    t.ack(seq,StemResult::GainApplied,binding,67);
    trace->release();
    uint64_t refill=0;
    await([&]{return (refill=t.registry.testStemRefillPending(t.handle))!=0;},"replacement submitted by actual Host maintenance");
    holdPostBlock(t,[&]{
        StemReceipt state;
        require(!t.registry.readPreparedStem(t.handle,state),"published replacement alone is not a receipt");
        require(t.registry.testStemRefillPending(t.handle)==refill && trace->observed().size()==3,
                "pending descriptors cannot recycle into next lookahead while callback ACK held");
    });
    auto state=window(t,2*page,4*page);
    require(state.missingFrames==67 && state.sequence==seq,"refills do not supersede command result or dry miss count");
    const auto recovery=t.cursor;
    t.play(recovery+ramp,"recover_on_same_running_clock",[=](unsigned f){return -double(f-recovery+1)/ramp;});
    trace->hold(4*page);
    t.play(3*page+17,"post_recovery_contiguous_edge",muted);
    t.registry.state(t.handle);trace->awaitHold();
    seek(t,900); // 43,200; old 32,768 reply no longer belongs to this traversal
    t.play(43219,"forward_seek_ignores_held_predecessor",unity);
    trace->release();
    state=window(t,5*page,longFrames);
    require(state.missingFrames==86 && trace->observed().size()==7,"old seek reply never published; successor staged exact demand");
    t.play(43477,"forward_seek_recovery",[](unsigned f){return -double(f-43218)/ramp;});
    trace->hold(0);
    seek(t,2);
    t.registry.state(t.handle);trace->awaitHold();
    t.play(123,"backward_seek_is_dry_until_real_reacquire",unity);
    trace->release();window(t,0,2*page);
    t.play(123+ramp,"backward_seek_recovery",[](unsigned f){return -double(f-122)/ramp;});
    trace->hold(2*page);
    t.play(page+1,"before_same_identity_reassignment",muted);
    t.registry.state(t.handle);trace->awaitHold();
    require(t.registry.load(t.handle,0,original,identity,generation+1,0),"same identity reassigned while real member fill held");
    drain(t);t.ready();t.cursor=0;
    require(t.registry.readPreparedStem(t.handle,state) && state.revoked && !state.windowEnd,"new generation revokes old window");
    const PreparedStemKey nextKey{identity,generation+1,longFrames,rate};
    require(t.registry.control(t.handle,1,0,0,0),"play reassigned original");
    t.play(137,"reassigned_generation_dry",unity);t.source(137,generation+1);
    seq=t.registry.retirePreparedStem(t.handle,binding);
    require(seq,"retire revoked rolling binding");
    holdPostBlock(t,[&]{
        require(!t.registry.readPreparedStem(t.handle,state) && !t.registry.bindRollingPreparedStem(t.handle,nextKey,factory),
                "cannot recycle before native retire post-block receipt");
    });
    require(!t.registry.readPreparedStem(t.handle,state) && !t.registry.bindRollingPreparedStem(t.handle,nextKey,factory) && trace->closes==0,
            "native retire alone cannot forget the worker still holding the write lease");
    trace->release();
    await([&]{return t.registry.readPreparedStem(t.handle,state) && state.sequence==seq;},"held member worker actually exited");
    t.ack(seq,StemResult::Retired,0,113);
    require(trace->closes==1 && !t.registry.bindRollingPreparedStem(t.handle,longKey,factory),"old generation never readmitted");
    const auto successor=t.registry.bindRollingPreparedStem(t.handle,nextKey,factory);
    require(successor && successor!=binding,"fresh generation attaches only after both fences");
    window(t,0,2*page);
    t.play(181,"fresh_generation_default_unity",unity);
    seq=t.registry.setPreparedStemGain(t.handle,successor,0);
    t.play(181+ramp,"fresh_generation_qualified_wet",[](unsigned f){return -double(f-180)/ramp;});
    t.ack(seq,StemResult::GainApplied,successor,113);
    seq=t.registry.setPreparedStemGain(t.handle,successor,1);
    // Closed-form and incremented double gains cancel to different ~1e-16
    // residuals mid-ramp. The clamped unity terminal is still bit-exact.
    t.play(181+2*ramp-1,"fresh_generation_smooth_bypass",[](unsigned f){return -(1.-double(f-180-ramp)/ramp);},1e-14f);
    t.play(181+2*ramp+64,"fresh_generation_exact_bypass",unity);
    t.ack(seq,StemResult::GainApplied,successor,113);
    retire(t,successor,113);t.close();
}
void rollingRefusal(const std::string& directory) {
    const auto original=directory+"/refusal-stem-original.wav",member=directory+"/refusal-stem-member.wav";
    const auto badMember=directory+"/refusal-short-extent.wav";
    wav(original,dry,longFrames);wav(member,stem,longFrames);wav(badMember,stem,longFrames-1);
    Trial t(original,1,false);
    const auto trace=std::make_shared<MemberTrace>();
    const auto bad=memberFactory(badMember,trace), good=memberFactory(member,trace);
    require(!t.registry.bindRollingPreparedStem(t.handle,{identity,generation,longFrames-1,rate},good) &&
            !t.registry.bindRollingPreparedStem(t.handle,{identity,generation,longFrames,44100},good),"wrong original key extent/rate refused before worker");
    const auto firstBinding=t.registry.bindRollingPreparedStem(t.handle,longKey,bad);
    require(firstBinding,"attachment does not imply member geometry qualified");
    drain(t);StemReceipt state;
    await([&]{return t.registry.readPreparedStem(t.handle,state) && state.refillError==SQ_FILE_INVALID_STREAM;},"mismatched decoded extent refused");
    require(!state.windowEnd && !state.windowSequence && trace->observed().empty(),"wrong geometry publishes/decodes no window");
    retire(t,firstBinding,0);
    trace->shortAt.store(2*page);
    const auto binding=t.registry.bindRollingPreparedStem(t.handle,longKey,good);
    window(t,0,2*page);
    require(t.registry.control(t.handle,1,0,0,0),"play while refusing later refill");
    const auto mute=t.registry.setPreparedStemGain(t.handle,binding,0);
    t.play(ramp,"refusal_initial_ramp",[](unsigned f){return -double(f+1)/ramp;});
    t.ack(mute,StemResult::GainApplied,binding);
    t.play(page+1,"refusal_before_short_decode",muted);
    await([&]{return t.registry.readPreparedStem(t.handle,state) && state.refillError==SQ_FILE_INVALID_STREAM;},"successful short decode refused before descriptor publication");
    require(state.windowEnd==2*page && trace->observed().size()==3,"short replacement never consumed; predecessor still acknowledged");
    t.play(2*page,"refusal_retains_old_coverage_then_tapers",[](unsigned f){return -std::min(1.,double(2*page-1-f)/ramp);});
    t.play(2*page+71,"refused_member_stays_dry",unity);
    t.source(2*page+71);retire(t,binding,71);t.close();
    const auto openCount=trace->opens.load();
    Trial faster(original,1.25,false);
    require(!faster.registry.bindRollingPreparedStem(faster.handle,longKey,good),"non-unit original refused for rolling");
    faster.close();
    Trial withPeer(original,1,false);
    require(withPeer.registry.load(withPeer.handle,1,original,identity+1,generation,0),"real peer admitted");
    require(!withPeer.registry.bindRollingPreparedStem(withPeer.handle,longKey,good) && trace->opens==openCount,
            "peer assignment refuses rolling before another member decoder opens");
    withPeer.close();
}
}
int main(int argc,char** argv) {
    require(argc==2 || (argc==3 && std::strcmp(argv[2],"--rolling")==0),"private build output directory argument");
    if(argc==3){rolling(argv[1]);rollingCustody(argv[1]);rollingRefusal(argv[1]);return 0;}
    const std::string original=std::string(argv[1])+"/prepared-stem-original.wav",member=std::string(argv[1])+"/prepared-stem-member.wav";
    wav(original,dry);wav(member,stem);
    const auto pcm=prepare(member);
    std::puts("stage,source_frame,actual_L,actual_R,expected_L,expected_R");
    switches(original,pcm);misses(original,pcm);stale(original,pcm);
    std::puts("PASS: switch/mute/reverse/bypass, source/callback custody, bounded miss, generation and speed refusal");
}

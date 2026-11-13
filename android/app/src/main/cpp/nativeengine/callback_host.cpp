#include "callback_host.hpp"
#include "worker_deck.hpp"
#include "schedule_worker.hpp"
#include "decoder_budget.hpp"
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <iomanip>
#include <limits>
#include <locale>
#include <mutex>
#include <sstream>
#include <utility>
#include <thread>
namespace soundq::nativeengine {
namespace {
using namespace transport;
constexpr uint64_t fixedPoolBytes = uint64_t{4} * 8 * maxPcmPageFrames * 2 * sizeof(float);
constexpr int32_t internalError = -10001;
constexpr int32_t closedError = -10002;
// Product-qualified ordinary listening range (engine envelope is wider).
constexpr double minSpeed = 0.5, maxSpeed = 2.0;
bool admittedSpeed(double value) noexcept { return std::isfinite(value) && value >= minSpeed && value <= maxSpeed; }
uint64_t nanos() noexcept {
    return static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::nanoseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count());
}
int64_t milliseconds(long double frame, uint32_t rate) noexcept {
    if (rate == 0 || !std::isfinite(frame) || frame <= 0) return 0;
    const auto ms = frame * 1000.0L / rate;
    return ms >= static_cast<long double>(std::numeric_limits<int64_t>::max()) ? std::numeric_limits<int64_t>::max()
                                                   : static_cast<int64_t>(ms);
}
struct Intent {
    uint64_t generation = 0, identity = 0, positionMs = 0, gesture = 0;
    std::string path;
    double gain = 1, speed = 1;
    bool play = false, gainDirty = false, playDirty = false, unloading = false;
};
struct Host final : Callbacks {
    std::unique_ptr<Output> output;
    std::unique_ptr<Engine> engine;
    std::array<std::unique_ptr<WorkerDeck>, 4> workers;
    std::array<Intent, 4> intents;
    Snapshot last{};
    std::unique_ptr<Schedule> candidate, schedule;
    std::vector<std::string> candidatePaths, schedulePaths;
    std::array<std::unique_ptr<ScheduleWorker>,4> scheduleWorkers;
    struct TempoTarget {uint64_t instance=0,tag=0,glide=0;double sourceBpm=0,bpm=0;};
    TempoTarget tempoTarget{};uint64_t latestTempoTag=0,tempoRefused=0;
    struct TempoReservation {uint64_t token=0,revision=0,instance=0,terminalTag=0;double source=0,origin=0;};
    TempoReservation tempoReservation{};uint64_t reservationSequence=0;
    std::unique_ptr<Schedule> tempoGraph;
    uint64_t tempoStageTag=0,tempoBoundary=0,tempoReceipt=0;unsigned tempoSlot=0;
    uint64_t scheduleReceipt=0, retireReceipt=0, admittedScheduleRevision=0;
    bool scheduleRetiring=false, scheduleReady=false;
    bool routeRecovery = false, outputQuiesced = false;
    uint64_t sequence = 0;
    uint32_t sampleRate = 0;
    std::atomic<int32_t> error{0};
    std::atomic<bool> gated{true};
    std::atomic<uint64_t> overruns{0};
    std::atomic<uint64_t> nonSilentCallbacks{0};
    explicit Host(std::unique_ptr<Output> o) : output(std::move(o)) {}
    void outputError(int32_t e) noexcept override {
        int32_t expected = 0;
        error.compare_exchange_strong(expected, e == 0 ? internalError : e, std::memory_order_acq_rel);
        gated.store(true, std::memory_order_release);
    }
    bool open() {
        if (!output || !output->open(*this, sampleRate) || sampleRate == 0) return false;
        engine = std::make_unique<Engine>(sampleRate);
        for (uint32_t i = 0; i < 4; ++i) workers[i] = std::make_unique<WorkerDeck>(i, *engine, sequence);
        gated.store(false, std::memory_order_release);
        return output->start();
    }
    void render(float* stereo, uint32_t frames) noexcept override {
        const auto start = nanos();
        // No decoder, worker, JNI, allocation, lock or source IO on the callback.
        if (gated.load(std::memory_order_acquire) || error.load(std::memory_order_acquire) != 0) {
            for (uint64_t i = 0; i < uint64_t{frames} * 2; ++i) stereo[i] = 0;
            return;
        }
#ifdef SOUNDQ_CALLBACK_TEST_SCHEDULE_DRIVER
        if(!frames){engine->render(stereo,0);return;}
#endif
        for(uint32_t at=0;at<frames;) {const auto count=std::min(256U,frames-at);engine->render(stereo+size_t{at}*2,count);at+=count;}
        bool nonSilent = false;
        for (uint64_t i = 0; i < uint64_t{frames} * 2; ++i)
            nonSilent = nonSilent || std::abs(stereo[i]) > 0.000001f;
        if (nonSilent) nonSilentCallbacks.fetch_add(1, std::memory_order_relaxed);
        if (nanos() - start > uint64_t{frames} * 1000000000ULL / sampleRate)
            overruns.fetch_add(1, std::memory_order_relaxed);
    }
    // Only the serialized producer may take over consumption, after the output
    // callback-exit receipt. Zero-frame drains apply/ACK commands without moving
    // any source cursor or borrowing a decoder buffer on this thread.
    bool quiesce() {
        gated.store(true, std::memory_order_release);
        if (!outputQuiesced) {
            if (!output->stopClose()) { outputError(closedError); return false; }
            outputQuiesced = true;
        }
        engine->render(nullptr, 0);
        Snapshot stopped{};
        if (!capture(stopped)) return false;
        bool settleRate = false;
        if (schedule && !scheduleRetiring) {
            if (!engine->scheduleTransport(next(), schedule->revision, 2, 0)) return false;
        } else if (!schedule) {
            for (unsigned i = 0; i < 4; ++i) {
                auto& intent = intents[i];
                const auto& deck = stopped.decks[i];
                const auto submit = [&](Operation operation, double value = 0) {
                    Command c{}; c.operation=operation; c.deck=i; c.sequence=next();
                    c.generation=deck.generation; c.gesture=deck.gesture; c.value=value;
                    return c.sequence && engine->submit(c);
                };
                // The worker's intended successor generation can be newer than
                // the currently rendered assignment during turnover. Fence the
                // captured engine assignment, not that future worker generation.
                if (deck.scratching && !submit(Operation::CancelScratch)) return false;
                intent.gesture = 0; intent.play = false; intent.playDirty = false;
                if (deck.identity) {
                    // Cancel may restore pre-gesture play/rate. Pause and the
                    // ordinary listening rate follow it, including any queued
                    // Move. The rate is the one matching the submitted pages.
                    const double rate = workers[i] ? workers[i]->appliedSpeed() : 1;
                    if (!submit(Operation::Pause) || !submit(Operation::SetRate, rate)) return false;
                    settleRate = settleRate || deck.rate != rate;
                }
            }
        }
        engine->render(nullptr, 0);
        // CancelScratch restores its saved signed rate. SetRate has a 128-frame
        // smoothing tail, so settle that tail with every deck paused before a
        // fresh Play can arrive. No source cursor moves and no PCM is emitted.
        if (settleRate) engine->render(nullptr, 128);
        return true;
    }
    bool recoverOutput() {
        if (error.load(std::memory_order_acquire) == 0 && !routeRecovery) return true;
        routeRecovery = true;
        if (!quiesce()) return false;
        const auto previousError = error.exchange(0, std::memory_order_acq_rel);
        uint32_t actualRate = sampleRate;
        // open creates a fresh, independently revocable callback proxy. Never
        // revive the obsolete stream's callback authority.
        outputQuiesced = false; // even a failed open may own a partial stream
        bool opened = false;
        try { opened = output->open(*this, actualRate); }
        catch (...) { outputError(internalError); }
        if (!opened || actualRate != sampleRate || error.load() != 0) {
            outputError(actualRate != sampleRate ? -10003 : previousError ? previousError : internalError);
            return false;
        }
        bool started = false;
        try { started = output->start(); } catch (...) { outputError(internalError); }
        if (!started || error.load() != 0) {
            outputError(previousError ? previousError : internalError);
            return false;
        }
        routeRecovery = false;
        gated.store(false, std::memory_order_release);
        return error.load(std::memory_order_acquire) == 0;
    }
    bool close() {
        gated.store(true, std::memory_order_release);
        if (!outputQuiesced && !output->stopClose()) { outputError(closedError); return false; }
        outputQuiesced = true;
        // stopClose is the callback-exit fence. Joins finish decoder destroy before
        // source/page storage can disappear. Never delete Engine before workers.
        for (auto& worker : workers) worker.reset();
        if(retainedPlatformDecoders.load(std::memory_order_acquire)!=0)return false;
        for (auto& worker : scheduleWorkers) worker.reset();
        schedule.reset(); candidate.reset();tempoGraph.reset();
        engine.reset();
        output.reset();
        return true;
    }
    uint64_t next() noexcept {
        return sequence == std::numeric_limits<uint64_t>::max() ? 0 : ++sequence;
    }
    bool command(Operation op, uint32_t deck, double value = 0, uint64_t gesture = 0) noexcept {
        Command c{};
        c.operation = op; c.deck = deck; c.sequence = next();
        c.generation = workers[deck]->generation(); c.value = value; c.gesture = gesture;
        return c.sequence != 0 && engine->submit(c);
    }
    bool capture(Snapshot& snap) noexcept {
        for (unsigned i = 0; i < 4; ++i) if (engine->snapshot(snap)) return true;
        return false;
    }
    void pump() {
        // Route failure stops callback consumption. Drain only after the concrete
        // close fence so Unload/retirement receipts remain reachable without Play.
        if (error.load(std::memory_order_acquire) != 0 && !quiesce()) return;
        Snapshot snap = last;
        if (capture(snap)) last = snap;
        if(scheduleRetiring) {
            if(engine->completedStructuralSequence()>=retireReceipt) {
                for(auto& w:scheduleWorkers)w.reset();
                schedule.reset();tempoGraph.reset();tempoStageTag=tempoReceipt=0;schedulePaths.clear();scheduleRetiring=false;scheduleReady=false;
                for(unsigned i=0;i<4;++i) if(!workers[i])workers[i]=std::make_unique<WorkerDeck>(i,*engine,sequence);
            } else return;
        }
        if(schedule) {
            if(snap.scheduleRevision!=schedule->revision) {scheduleReady=false;return;}
            bool ready=engine->completedStructuralSequence()>=scheduleReceipt;
            for(auto& w:scheduleWorkers) {w->pump(snap);ready=ready&&w->ready(snap);}
            scheduleReady=ready;pumpTempo(snap);return;
        }
        for (uint32_t i = 0; i < 4; ++i) {
            auto& worker = workers[i];
            auto& intent = intents[i];
            if (!worker) continue;
            worker->pump(snap);
            if (intent.unloading && worker->retired()) {
                // Unassign's separate post-block receipt covers every descriptor.
                // Destructor joins the obsolete fill and closes the decoder. Only
                // then allocate the successor empty worker, keeping the RAM bound.
                worker.reset();
                if(retainedPlatformDecoders.load(std::memory_order_acquire)!=0) {
                    // Keep original identity/unloading visible. A failed codec
                    // release must never satisfy explicit original-delete drain.
                    outputError(closedError);continue;
                }
                intent.identity = 0; intent.path.clear(); intent.unloading = false;
                try { worker = std::make_unique<WorkerDeck>(i, *engine, sequence); }
                catch (...) { outputError(internalError); }
                continue;
            }
            if (error.load(std::memory_order_acquire) != 0 || !worker->stats().ready) continue;
            if (intent.gainDirty && command(Operation::SetGain, i, intent.gain)) intent.gainDirty = false;
            if (intent.playDirty && !intent.gainDirty &&
                command(intent.play ? Operation::Play : Operation::Pause, i)) intent.playDirty = false;
        }
    }
    uint64_t reserveTempo(uint64_t revision,uint64_t instance,double sourceBpm,double origin) {
        pump();
        if(tempoReservation.token || tempoTarget.tag || tempoGraph || !schedule || scheduleRetiring || schedule->revision!=revision || error.load()!=0 || reservationSequence==uint64_t{INT64_MAX} || !std::isfinite(sourceBpm) || !std::isfinite(origin) || sourceBpm<10 || sourceBpm>600 || origin<10 || origin>600 || origin/sourceBpm<.8 || origin/sourceBpm>1.5)return 0;
        Snapshot snap;if(!capture(snap) || snap.scheduleRevision!=revision || !snap.schedulePlaying)return 0;
        const auto it=std::find_if(schedule->clips.begin(),schedule->clips.end(),[&](const ScheduleClip& c){return c.instance==instance;});
        if(it==schedule->clips.end() || snap.globalFrame<it->start || snap.globalFrame>=it->end || it->tempoHistory.size()>=maxTempoSegments)return 0;
        const auto& d=snap.decks[it->slot];const auto& law=it->tempo;
        if(d.identity!=instance || d.generation!=revision || d.scratching || d.syncState || (law.preserve && (law.overlapPolicy!=TempoOverlapPolicy::IndependentConstant || law.sourceBpm!=sourceBpm || (law.startBpm!=law.endBpm && snap.globalFrame<law.end))) || std::abs(tempoRate(*it,snap.globalFrame)*sourceBpm-origin)>1e-6)return 0;
        for(const auto& c:schedule->clips)if(c.instance!=instance && c.tempo.preserve && c.tempo.overlapPolicy!=TempoOverlapPolicy::IndependentConstant)return 0;
        tempoReservation={++reservationSequence,revision,instance,0,sourceBpm,origin};return tempoReservation.token;
    }
    bool releaseTempo(uint64_t token) {
        if(!token || tempoReservation.token!=token)return false;
        tempoReservation={};return true;
    }
    bool restoreTempo(uint64_t token,uint64_t tag) {
        if(!token || tempoReservation.token!=token || tempoReservation.terminalTag)return false;
        const auto captured=tempoReservation;
        // Only this captured capability selects the admitted origin. No caller
        // may turn a terminal flag into arbitrary target/stale-owner authority.
        if(!liveTempo(captured.revision,captured.instance,tag,captured.source,captured.origin,0,token,true))return false;
        return true;
    }
    bool liveTempo(uint64_t revision,uint64_t instance,uint64_t tag,double sourceBpm,double bpm,uint64_t glide,uint64_t reservation=0,bool terminal=false) {
        pump(); // Settle a just-consumed graph before validating the next source law.
        if(!schedule || scheduleRetiring || schedule->revision!=revision || error.load()!=0 || !tag || tag<=latestTempoTag || !std::isfinite(sourceBpm) || !std::isfinite(bpm) || sourceBpm<10 || sourceBpm>600 || bpm<10 || bpm>600 || bpm/sourceBpm<.8 || bpm/sourceBpm>1.5 || glide>sampleRate*10ULL)return false;
        if(tempoReservation.token) {
            if(reservation!=tempoReservation.token || revision!=tempoReservation.revision || instance!=tempoReservation.instance || sourceBpm!=tempoReservation.source || tempoReservation.terminalTag)return false;
        } else if(reservation || terminal)return false;
        Snapshot snap;if(!capture(snap))return false;
        const auto it=std::find_if(schedule->clips.begin(),schedule->clips.end(),[&](const ScheduleClip& c){return c.instance==instance;});
        if(it==schedule->clips.end() || snap.globalFrame<it->start || snap.globalFrame>=it->end)return false;
        if(it->tempo.preserve && (it->tempo.overlapPolicy!=TempoOverlapPolicy::IndependentConstant || std::abs(it->tempo.sourceBpm-sourceBpm)>1e-9))return false;
        // Connected pulse graphs remain unsupported. Sequential reuse is safe
        // only if the compiled continuation retains every slot and bank below.
        for(const auto& c:schedule->clips)if(c.instance!=instance && c.tempo.preserve && c.tempo.overlapPolicy!=TempoOverlapPolicy::IndependentConstant)return false;
        const auto& d=snap.decks[it->slot];if(d.identity!=instance || d.scratching || d.syncState || std::abs(d.sourceFrame-sourceAt(*it,snap.globalFrame,sampleRate))>1e-5)return false;
        if(!engine->tempoIntent(revision,tag))return false;
        if(terminal)tempoReservation.terminalTag=tag;
        latestTempoTag=tag;tempoTarget={instance,tag,glide,sourceBpm,bpm};pump();return true;
    }
    void pumpTempo(const Snapshot& snap) {
        if(!tempoGraph && tempoReservation.terminalTag && snap.tempoApplied==tempoReservation.terminalTag)tempoReservation={};
        if(tempoGraph){
            auto& worker=*scheduleWorkers[tempoSlot];
            if(!worker.staged(tempoStageTag))return;
            if(!tempoReceipt){
                if(worker.stagedError() || tempoStageTag!=tempoTarget.tag || snap.globalFrame+256>=tempoBoundary){
                    if(worker.stagedError()){tempoRefused=tempoStageTag;if(tempoTarget.tag==tempoStageTag)tempoTarget={};}
                    worker.finishTempo(*schedule,tempoStageTag,false,0);tempoGraph.reset();tempoStageTag=0;return;
                }
                std::array<PcmWindow,4> windows{};windows[tempoSlot]=worker.tempoWindow();
                const auto seq=next();if(!engine->handoffTempo(seq,tempoGraph.get(),tempoStageTag,tempoBoundary,1U<<tempoSlot,windows))return;
                tempoReceipt=seq;
            }
            if(snap.tempoTerminal<tempoStageTag || engine->completedStructuralSequence()<tempoReceipt)return;
            if(!engine->settleTempo(tempoStageTag))return;
            const bool applied=snap.tempoApplied==tempoStageTag;
            worker.finishTempo(applied?*tempoGraph:*schedule,tempoStageTag,applied,tempoReceipt);
            if(applied){schedule=std::move(tempoGraph);for(auto& w:scheduleWorkers)w->graphChanged(*schedule);if(tempoTarget.tag==tempoStageTag)tempoTarget={};}
            else tempoGraph.reset();
            if(applied && tempoReservation.terminalTag==tempoStageTag)tempoReservation={};
            tempoStageTag=tempoReceipt=0;
        }
        if(!tempoTarget.tag)return;
        const auto it=std::find_if(schedule->clips.begin(),schedule->clips.end(),[&](const ScheduleClip& c){return c.instance==tempoTarget.instance;});
        if(it==schedule->clips.end()) {tempoTarget={};return;}
        auto& worker=*scheduleWorkers[it->slot];if(!worker.idle())return;
        // Check the whole forward law, not merely its endpoint. Interrupting an
        // unfinished glide is a real edit even when its target is unchanged.
        const auto& law=it->tempo;
        const bool forward=it->tempoHistory.empty() || snap.globalFrame>=it->mapFrame;
        const bool unchanged=forward && (!law.preserve ? tempoTarget.bpm==tempoTarget.sourceBpm :
            (law.startBpm==law.endBpm || snap.globalFrame>=law.end) && law.endBpm/law.sourceBpm==tempoTarget.bpm/tempoTarget.sourceBpm);
        if(unchanged) {
            if(engine->acknowledgeTempo(next(),schedule->revision,it->instance,tempoTarget.tag,tempoTarget.sourceBpm,tempoTarget.bpm))tempoTarget={};
            return;
        }
        // Bounded 50 ms output lead. Old pages remain on-air while DSP primes.
        const auto boundary=snap.globalFrame+std::max<uint64_t>(512,sampleRate/20);
        if(boundary+512>=it->end){tempoRefused=tempoTarget.tag;tempoTarget={};return;}
        auto clips=schedule->clips;const auto index=static_cast<size_t>(it-schedule->clips.begin());auto& c=clips[index];
        const auto* held=tempoSegment(*it,boundary);
        const TempoSegment prefix=held?*held:TempoSegment{it->tempo,it->mapFrame>=0?it->mapFrame:double(it->start),it->mapFrame>=0?it->mapSource:it->trimIn};
        c.tempoHistory.erase(std::lower_bound(c.tempoHistory.begin(),c.tempoHistory.end(),double(boundary),[](const TempoSegment& s,double f){return s.frame<f;}),c.tempoHistory.end());
        if(c.tempoHistory.empty() || c.tempoHistory.back().frame!=prefix.frame)c.tempoHistory.push_back(prefix);
        // Ordinary previews may never spend the captured terminal's slot.
        const auto limit=tempoReservation.token && tempoTarget.tag!=tempoReservation.terminalTag?maxTempoSegments-1:maxTempoSegments;
        if(c.tempoHistory.size()>limit){tempoRefused=tempoTarget.tag;tempoTarget={};return;}
        c.mapFrame=static_cast<double>(boundary);c.mapSource=sourceAt(*it,boundary,sampleRate);
        const double current=it->tempo.preserve?tempoRate(*it,boundary)*tempoTarget.sourceBpm:tempoTarget.sourceBpm;
        c.tempo={true,1,tempoTarget.sourceBpm,tempoTarget.glide?current:tempoTarget.bpm,tempoTarget.bpm,double(boundary),double(boundary+std::max<uint64_t>(1,tempoTarget.glide)),it->tempo.preserve?it->tempo.sourceAnchor:0,TempoOverlapPolicy::IndependentConstant};
        // Anchored independent runtime ramps do not claim shared phase.
        auto graph=Schedule::compile(schedule->revision,sampleRate,clips);
        // Independent ramps are admitted by the runtime continuation contract,
        // not by weakening the immutable independent-constant authoring policy.
        if(!graph){tempoRefused=tempoTarget.tag;tempoTarget={};return;}
        for(size_t i=0;i<clips.size();++i)if(graph->clips[i].slot!=schedule->clips[i].slot || graph->banks[i]!=schedule->banks[i]){tempoRefused=tempoTarget.tag;tempoTarget={};return;}
        if(!worker.stageTempo(*graph,tempoTarget.tag,boundary))return;
        tempoSlot=c.slot;tempoBoundary=boundary;tempoStageTag=tempoTarget.tag;tempoGraph=std::move(graph);
    }
    bool prepareSchedule(uint64_t revision,const std::vector<std::string>& paths,const std::vector<int64_t>& values,const std::vector<double>* tempo=nullptr) {
        if(!revision || revision<=admittedScheduleRevision || candidate || paths.empty() || paths.size()>500 || error.load()!=0)return false;
        // Legacy five-field callers remain strict. The sixth field is zero for an
        // explicit trim, otherwise the catalog duration of a full-source end.
        const size_t stride=values.size()==paths.size()*6?6:5;
        if(values.size()!=paths.size()*stride)return false;
        if(tempo && (stride!=6 || tempo->size()!=paths.size()*8))return false;
        if(tempo)for(size_t i=0;i<paths.size();++i) {
            const auto* t=tempo->data()+i*8;
            for(unsigned j=0;j<8;++j)if(!std::isfinite(t[j]))return false;
            if(t[6]==0){for(unsigned j=0;j<8;++j)if(t[j]!=0)return false;}
            else if((t[6]!=1 && t[6]!=2 && t[6]!=3) || (t[7]!=0 && t[7]!=1) ||
                (t[6]==2 && t[1]!=t[2]) || t[3]<0 || t[4]<=t[3] || t[4]>302400604800. || t[5]<0)return false;
        }
        std::vector<ScheduleClip> clips;
        for(size_t i=0;i<paths.size();++i) {
            for(size_t j=0;j<stride;++j)if(values[i*stride+j]<0 || values[i*stride+j]>302400604800LL)return false;
            if(paths[i].empty() || paths[i][0]!='/' || paths[i].find('\0')!=std::string::npos)return false;
            sq_file_decoder* decoder=nullptr;
            DecoderPermit permit;if(!permit.acquire())return false;
            const auto status=sq_file_decoder_open(paths[i].c_str(),SQ_FILE_MAX_FILE_BYTES,&decoder);
            if(status || !decoder){sq_file_decoder_destroy(decoder);return false;}
            const auto frames=sq_file_decoder_frame_count(decoder);const auto hz=sq_file_decoder_sample_rate(decoder);
            const auto channels=sq_file_decoder_channels(decoder);sq_file_decoder_destroy(decoder);
            permit.release();
            if(frames<=0 || !hz || channels!=2)return false;
            const auto* v=&values[i*stride];
            if(v[2]<=v[1])return false;
            const auto start=static_cast<uint64_t>(v[0])*sampleRate/1000;
            auto end=static_cast<uint64_t>(v[0]+v[2]-v[1])*sampleRate/1000;
            double trimOut=v[2]*double(hz)/1000;
            if(stride==6 && v[5]!=0) {
                if(v[5]!=v[2])return false;
                // Compare in exact source-frame thousandths. Only a full-source
                // selection may resolve a strictly sub-second catalog rounding
                // difference, in either direction, to the decoder's real EOF.
                const auto limit=std::numeric_limits<uint64_t>::max();
                if(static_cast<uint64_t>(frames)>limit/1000 || static_cast<uint64_t>(v[2])>limit/hz)return false;
                const uint64_t decoded=static_cast<uint64_t>(frames)*1000;
                const uint64_t catalog=static_cast<uint64_t>(v[2])*hz;
                const uint64_t difference=decoded>catalog?decoded-catalog:catalog-decoded;
                if(difference>=uint64_t{hz}*1000)return false;
                const uint64_t first=static_cast<uint64_t>(v[1])*hz;
                if(first>=decoded)return false;
                const uint64_t remaining=decoded-first, denominator=uint64_t{hz}*1000;
                if(remaining>limit/sampleRate)return false;
                const uint64_t numerator=remaining*sampleRate;
                // Half-open output: include each mapped sample strictly before
                // exact EOF, including the last fractional-rate output point.
                const uint64_t length=numerator/denominator+(numerator%denominator!=0);
                if(length>limit-start)return false;
                end=start+length;trimOut=static_cast<double>(frames);
            }
            clips.push_back({i+1,0,start,end,v[1]*double(hz)/1000,trimOut,hz,static_cast<uint64_t>(frames),static_cast<uint64_t>(v[3])*sampleRate/1000,static_cast<uint64_t>(v[4])*sampleRate/1000,1});
        }
        if(tempo)for(size_t i=0;i<clips.size();++i) {
            const auto* t=tempo->data()+i*8;if(t[6]==0)continue;
            clips[i].tempo={true,static_cast<uint32_t>(t[7]),t[0],t[1],t[2],
                t[3]*sampleRate/1000.,t[4]*sampleRate/1000.,t[5]*clips[i].sourceRate/1000.,static_cast<TempoOverlapPolicy>(static_cast<uint32_t>(t[6]))};
        }
        auto compiled=Schedule::compile(revision,sampleRate,clips);if(!compiled)return false;
        candidatePaths=paths;candidate=std::move(compiled);admittedScheduleRevision=revision;return true;
    }
    bool arrangement(int op,uint64_t value) {
        if(op==6){candidate.reset();candidatePaths.clear();return true;}
        if(op==5) {
            if(scheduleRetiring)return true;
            if(!schedule)return true;
            const auto seq=next();if(!engine->installSchedule(seq,nullptr,0))return false;
            tempoReservation={};tempoTarget={};retireReceipt=seq;scheduleRetiring=true;scheduleReady=false;return true;
        }
        if(op==4) {
            if(!candidate || schedule || scheduleRetiring)return false;
            for(const auto& i:intents)if(i.identity || i.unloading)return false;
            for(auto& w:workers)w.reset();
            schedule=std::move(candidate);schedulePaths=std::move(candidatePaths);
            try {for(unsigned i=0;i<4;++i)scheduleWorkers[i]=std::make_unique<ScheduleWorker>(i,*schedule,schedulePaths,*engine,sequence);}
            catch(...) {for(auto& w:scheduleWorkers)w.reset();schedule.reset();throw;}
            scheduleReceipt=next();
            if(!engine->installSchedule(scheduleReceipt,schedule.get(),0)) {for(auto& w:scheduleWorkers)w.reset();schedule.reset();return false;}
            scheduleReady=false;return true;
        }
        if(!schedule || scheduleRetiring || error.load()!=0 || op<1 || (op>3 && op!=7) || (op==7 && value>1000000))return false;
        if(op==1 && !scheduleReady)return false;
        if(op==2 || op==3){tempoTarget={};tempoReservation={};}
        const auto frame=op==7?value:op==3?static_cast<uint64_t>(std::min(static_cast<long double>(schedule->duration),static_cast<long double>(value)*sampleRate/1000)):0;
        const auto seq=next();if(!engine->scheduleTransport(seq,schedule->revision,static_cast<uint32_t>(op),frame))return false;
        scheduleReceipt=seq;if(op==3)scheduleReady=false;return true;
    }
    bool load(int deck, const std::string& path, uint64_t identity, uint64_t generation, uint64_t position, double speed = 1) {
        if (schedule || scheduleRetiring || deck < 0 || deck >= 4 || error.load() != 0 || identity == 0 || generation == 0 ||
            path.empty() || path[0] != '/' || path.find('\0') != std::string::npos || !admittedSpeed(speed)) return false;
        auto& intent = intents[deck];
        if (!workers[deck] || intent.unloading || generation < intent.generation) return false;
        if (generation == intent.generation)
            return identity == intent.identity && path == intent.path && position == intent.positionMs && speed == intent.speed;
        // Preallocate/copy all throwing state before the worker accepts turnover.
        Intent accepted{generation, identity, position, 0, path, intent.gain, speed, false, true, true, false};
        if (!workers[deck]->replace(path, identity, generation, position, speed)) return false;
        intent = std::move(accepted);
        return true;
    }
    bool loadReader(int deck,std::shared_ptr<const PcmReaderFactory> factory,uint64_t identity,uint64_t generation,uint64_t position,double speed) {
        if(schedule || scheduleRetiring || deck<0 || deck>=4 || error.load()!=0 || !identity || !generation || !factory || !admittedSpeed(speed))return false;
        auto& intent=intents[deck];
        if(!workers[deck] || intent.unloading || generation<=intent.generation)return false;
        Intent accepted{generation,identity,position,0,{},intent.gain,speed,false,true,true,false};
        if(!workers[deck]->replaceReader(std::move(factory),identity,generation,position,speed))return false;
        intent=std::move(accepted);return true;
    }
    bool crossfade(int out,uint64_t og,int in,uint64_t ig,uint64_t ms) {
        pump();
        if(schedule || scheduleRetiring || out<0 || out>1 || in<0 || in>1 || out==in || ms>12000 ||
            intents[out].generation!=og || intents[in].generation!=ig || intents[out].unloading || intents[in].unloading)return false;
        if(ms && (error.load()!=0 || !workers[out]->stats().ready || !workers[in]->stats().ready))return false;
        if(!engine->crossfade(next(),static_cast<uint32_t>(out),og,static_cast<uint32_t>(in),ig,ms*sampleRate/1000))return false;
        // The callback owns incoming onset, not a dirty producer Play command.
        intents[in].play=false;intents[in].playDirty=false;
        return true;
    }
    bool scratch(int op,uint64_t instance,uint64_t gesture,uint64_t event,double rate) {
        const auto now=nanos();
        if(!schedule || scheduleRetiring || error.load()!=0 || event==0 || event>now || now-event>2000000000ULL)return false;
        return engine->scratch(next(),schedule->revision,static_cast<uint32_t>(op),instance,gesture,event,rate);
    }
    bool sync(const LiveSync& request) {
        if(!schedule || scheduleRetiring || error.load()!=0)return false;
        pump();return engine->sync(next(),schedule->revision,request);
    }
    bool control(int operation, int deck, double value, uint64_t eventNanos) {
        if (deck < 0 || deck >= 4 || !std::isfinite(value)) return false;
        if (operation == 9) return deck == 0 && value == 0 && recoverOutput();
        if(schedule || scheduleRetiring)return false;
        auto& w = workers[deck]; auto& intent = intents[deck];
        if (operation == 10) {
            // Ordinary listening speed for this exact assignment. Admission is
            // not acceptance: the snapshot's engine rate is the receipt.
            if (!w || !admittedSpeed(value) || error.load(std::memory_order_acquire) != 0 || intent.unloading ||
                intent.identity == 0 || intent.gesture != 0 || !w->setSpeed(value)) return false;
            intent.speed = value; pump(); return true;
        }
        if (!w) return operation == 8;
        // Cleanup remains available after a route error, but no new motion/load.
        if (operation == 8) {
            if (intent.unloading) return true;
            if (!w->retire()) return false;
            intent.gesture = 0; intent.play = false; intent.playDirty = false;
            intent.gainDirty = false; intent.unloading = true;
            return true;
        }
        if (error.load(std::memory_order_acquire) != 0 || intent.unloading) return false;
        if (operation == 7) {
            if (value < 0 || value > 1) return false;
            intent.gain = value; intent.gainDirty = true; pump(); return true;
        }
        if (intent.identity == 0) return false;
        if (operation == 1 || operation == 2) {
            if (operation == 2 && intent.gesture != 0) {
                if (!command(Operation::CancelScratch, static_cast<uint32_t>(deck), 0, intent.gesture)) return false;
                intent.gesture = 0; // EndScratch can no longer restore pre-Pause play.
            }
            intent.play = operation == 1; intent.playDirty = true; pump(); return true;
        }
        if (!w->stats().ready) return false;
        switch (operation) {
        case 3: {
            if (value < 0 || w->sourceRate() == 0) return false;
            const auto frame = std::min(static_cast<long double>(w->sourceFrames()?w->sourceFrames():(uint64_t{1}<<52)),
                static_cast<long double>(value) * w->sourceRate() / 1000.0L);
            const bool accepted=command(Operation::Seek, static_cast<uint32_t>(deck), static_cast<double>(frame));
            if(accepted)w->fenceSeek();
            return accepted;
        }
        case 4: {
            if (intent.gesture != 0) return false;
            const auto gesture = next();
            if (gesture == 0 || !command(Operation::BeginScratch, static_cast<uint32_t>(deck), 0, gesture)) return false;
            intent.gesture = gesture; return true;
        }
        case 5: {
            if (intent.gesture == 0 || value < -8 || value > 8 || eventNanos == 0) return false;
            ScratchMove m{}; m.deck = static_cast<uint32_t>(deck); m.generation = w->generation();
            m.gesture = intent.gesture; m.sequence = next(); m.eventNanos = eventNanos; m.rate = value;
            return m.sequence != 0 && engine->move(m);
        }
        case 6:
            if (intent.gesture == 0 || !command(Operation::EndScratch, static_cast<uint32_t>(deck), 0, intent.gesture)) return false;
            intent.gesture = 0; return true;
        default: return false;
        }
    }
    std::string state() {
        pump();
        Snapshot snap = last;
        const bool coherent = capture(snap);
        if (coherent) last = snap;
        uint32_t decoders = retainedPlatformDecoders.load(std::memory_order_acquire);
        for (const auto& w : workers) if (w) decoders += w->stats().openDecoders;
        for (const auto& w : scheduleWorkers) if (w) decoders += w->openDecoders();
        std::ostringstream out; out.imbue(std::locale::classic()); out << std::setprecision(17);
        out << "{\"error\":" << error.load() << ",\"sampleRate\":" << sampleRate
            << ",\"naturalEndVersion\":1"
            << ",\"speedMin\":" << minSpeed << ",\"speedMax\":" << maxSpeed
            << ",\"renderedFrames\":" << snap.renderedFrames << ",\"xRuns\":" << output->xRuns()
            << ",\"callbackOverruns\":" << overruns.load()
            << ",\"nonSilentCallbacks\":" << nonSilentCallbacks.load() << ",\"pcmPoolBytes\":" << fixedPoolBytes
            << ",\"tempoAllocationUpperBytes\":" << ([&]{uint64_t n=0;for(const auto& w:scheduleWorkers)if(w)n+=w->tempoAllocationUpperBytes();return n;})()
            << ",\"tempoApplied\":" << snap.tempoApplied << ",\"tempoTerminal\":" << snap.tempoTerminal << ",\"tempoRefused\":" << tempoRefused
            << ",\"tempoHistorySegments\":" << ([&]{size_t n=0;if(schedule)for(const auto& c:schedule->clips)n+=c.tempoHistory.size();return n;})()
            << ",\"scheduleRevision\":" << (schedule?schedule->revision:0)
            << ",\"globalFrame\":" << snap.globalFrame << ",\"durationFrames\":" << snap.durationFrames
            << ",\"scheduleReady\":" << (scheduleReady && coherent && schedule && snap.scheduleRevision==schedule->revision && engine->completedStructuralSequence()>=scheduleReceipt && [&]{for(const auto& w:scheduleWorkers)if(!w || !w->ready(snap))return false;return true;}()?"true":"false")
            << ",\"scheduleBuffering\":" << (snap.scheduleBuffering?"true":"false")
            << ",\"schedulePlaying\":" << (snap.schedulePlaying?"true":"false")
            << ",\"scheduleEnded\":" << (snap.scheduleEnded?"true":"false")
            << ",\"scheduleRetiring\":" << (scheduleRetiring?"true":"false")
            << ",\"scheduleError\":" << ([&]{int e=0;for(const auto& w:scheduleWorkers)if(w && w->error())e=w->error();return e;})()
            << ",\"decoderPermits\":" << decoderPermits.load(std::memory_order_acquire)
            << ",\"latencyCount\":" << snap.latencyCount << ",\"latencyDropped\":" << (snap.latencyCount>64?snap.latencyCount-64:0)
            << ",\"movesCoalesced\":" << snap.movesCoalesced << ",\"refusedCommands\":" << snap.refusedCommands << ",\"syncReschedules\":" << snap.syncReschedules
            << ",\"latencySamples\":[";
        const auto count=std::min<uint64_t>(64,snap.latencyCount);
        for(uint64_t i=0;i<count;++i){if(i)out<<',';const auto& v=snap.latency[(snap.latencyCount-count+i)%64];out<<"{\"eventNanos\":"<<v.eventNanos<<",\"appliedNanos\":"<<v.appliedNanos<<",\"sequence\":"<<v.sequence<<'}';}
        out << "],\"openDecoders\":" << decoders << ",\"coherent\":" << (coherent ? "true" : "false") << ",\"decks\":[";
        for (unsigned i = 0; i < 4; ++i) {
            if (i) out << ',';
            if(schedule) {
                const auto& d=snap.decks[i];
                const auto it=std::find_if(schedule->clips.begin(),schedule->clips.end(),[&](const ScheduleClip& c){return c.instance==d.identity;});
                const auto rate=it==schedule->clips.end()?0:it->sourceRate;const auto extent=it==schedule->clips.end()?0:it->sourceFrames;
                const bool ready=scheduleWorkers[i] && scheduleWorkers[i]->ready(snap);
                out<<"{\"generation\":"<<d.generation<<",\"identity\":"<<d.identity<<",\"sourceFrame\":"<<d.sourceFrame
                   <<",\"sourceRate\":"<<rate<<",\"sourceFrames\":"<<extent<<",\"positionMs\":"<<milliseconds(d.sourceFrame,rate)
                   <<",\"durationMs\":"<<milliseconds(extent,rate)<<",\"playing\":"<<(d.playing?"true":"false")
                   <<",\"tempoGeneration\":"<<d.tempoGeneration<<",\"processingEpoch\":"<<d.processingEpoch<<",\"pitchPreserved\":"<<(d.processingEpoch?"true":"false")<<",\"effectiveBpm\":"<<d.effectiveBpm
                   <<",\"rate\":"<<d.rate<<",\"nominalSourceFrame\":"<<d.nominalSourceFrame<<",\"scratching\":"<<(d.scratching?"true":"false")<<",\"gesture\":"<<d.gesture
                   <<",\"lastMoveEventNanos\":"<<d.lastMoveEventNanos<<",\"lastMoveAppliedNanos\":"<<d.lastMoveAppliedNanos<<",\"lastMoveSequence\":"<<d.lastMoveSequence<<",\"heldZero\":"<<(d.heldZero?"true":"false")
                   <<",\"syncReference\":"<<d.syncReference<<",\"syncBeats\":"<<d.syncBeats<<",\"syncState\":"<<d.syncState<<",\"syncPhaseErrorFrames\":"<<d.syncPhaseErrorFrames<<",\"syncBoundaryFrame\":"<<d.syncBoundaryFrame
                   <<",\"ready\":"<<(ready?"true":"false")<<",\"preparing\":"<<(!ready?"true":"false")
                   <<",\"eofCount\":0,\"missingPcmFrames\":"<<d.missingPcmFrames<<",\"openDecoders\":"<<(scheduleWorkers[i]?scheduleWorkers[i]->openDecoders():0)<<",\"errorInstance\":"<<(scheduleWorkers[i]?scheduleWorkers[i]->errorInstance():0)<<",\"error\":"<<(scheduleWorkers[i]?scheduleWorkers[i]->error():0)<<'}';continue;
            }
            const auto& w = workers[i]; const auto stats = w ? w->stats() : WorkerStats{}; const auto& d = snap.decks[i];
            const auto& intent = intents[i];
            const bool matching = w && d.identity != 0 && d.identity == w->identity() && d.generation == w->generation();
            const bool ready = coherent && matching && w->ready(snap) && !intent.unloading && error.load() == 0;
            // Control intent can already name a replacement while the callback
            // still owns the retiring worker. Never relabel its evidence.
            const bool completionSource = coherent && matching && !intent.unloading &&
                intent.identity == d.identity && intent.generation == d.generation &&
                error.load() == 0 && stats.error == 0;
            const auto frame = matching ? d.sourceFrame : 0;
            const auto rate = w ? w->sourceRate() : 0;
            const auto extent = w ? w->sourceFrames() : 0;
            out << "{\"generation\":" << intent.generation << ",\"identity\":" << intent.identity
                << ",\"boundaryGain\":" << d.boundaryGain << ",\"sourceFrame\":" << frame << ",\"sourceRate\":" << rate
                << ",\"sourceFrames\":" << extent << ",\"positionMs\":" << milliseconds(frame, rate)
                << ",\"durationMs\":" << milliseconds(extent, rate)
                << ",\"playing\":" << (matching && d.playing ? "true" : "false")
                << ",\"speed\":" << intent.speed
                << ",\"rate\":" << d.rate << ",\"scratching\":" << (d.scratching ? "true" : "false")
                << ",\"ready\":" << (ready ? "true" : "false")
                << ",\"preparing\":" << (stats.preparing || intent.unloading ? "true" : "false")
                << ",\"eofCount\":" << (matching ? d.eofCount : 0)
                << ",\"traversalRevision\":" << (completionSource ? d.traversalRevision : 0)
                << ",\"naturalEndCount\":" << (completionSource ? d.naturalEndCount : 0)
                << ",\"naturalEndGeneration\":" << (completionSource ? d.naturalEndGeneration : 0)
                << ",\"naturalEndIdentity\":" << (completionSource ? d.naturalEndIdentity : 0)
                << ",\"naturalEndTraversalRevision\":" << (completionSource ? d.naturalEndTraversalRevision : 0)
                << ",\"missingPcmFrames\":" << (matching ? d.missingPcmFrames : 0)
                << ",\"openDecoders\":" << stats.openDecoders << ",\"error\":" << stats.error << '}';
        }
        out << "]}"; return out.str();
    }
};
}
struct Registry::Impl {
    std::mutex mutex; // Defends accidental concurrent JNI callers, never callback.
    std::unique_ptr<Host> host;
    uint64_t handle = 0, counter = 0;
    std::atomic<bool> stopping{false};
    std::thread maintenance;
    Impl():maintenance([this]{
        while(!stopping.load(std::memory_order_acquire)) {
            std::this_thread::sleep_for(std::chrono::milliseconds(5));
            std::unique_lock<std::mutex> lock(mutex,std::try_to_lock);
            if(lock.owns_lock() && host && host->engine && !host->gated.load()) {
                try{host->pump();}catch(...){host->outputError(internalError);}
            }
        }
    }){}
    void join(){stopping.store(true,std::memory_order_release);if(maintenance.joinable())maintenance.join();}
    ~Impl(){join();}
    bool valid(uint64_t h) const noexcept { return h != 0 && h == handle && host && host->engine; }
};
Registry::Registry() : impl_(std::make_unique<Impl>()) {}
Registry::~Registry() {
    impl_->join(); // Join outside the serialized producer mutex.
    // A failed OS close must not turn process/static teardown into unsafe release.
    if (impl_->host && !impl_->host->close()) (void)impl_.release();
}
uint64_t Registry::open(std::unique_ptr<Output> output) {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (impl_->host || impl_->counter == static_cast<uint64_t>(std::numeric_limits<int64_t>::max())) return 0;
    impl_->host = std::make_unique<Host>(std::move(output));
    try {
        if (impl_->host->open()) { impl_->handle = ++impl_->counter; return impl_->handle; }
    } catch (...) { impl_->host->outputError(internalError); }
    if (impl_->host->close()) impl_->host.reset(); // failure deliberately retains the singleton
    return 0;
}
bool Registry::load(uint64_t h, int d, const std::string& p, uint64_t id, uint64_t g, uint64_t ms) {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    return impl_->valid(h) && impl_->host->load(d, p, id, g, ms);
}
bool Registry::loadSpeed(uint64_t h, int d, const std::string& p, uint64_t id, uint64_t g, uint64_t ms, double speed) {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    return impl_->valid(h) && impl_->host->load(d, p, id, g, ms, speed);
}
bool Registry::loadReader(uint64_t h,int d,std::shared_ptr<const PcmReaderFactory> factory,uint64_t id,uint64_t g,uint64_t ms,double speed) {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    return impl_->valid(h) && impl_->host->loadReader(d,std::move(factory),id,g,ms,speed);
}
bool Registry::control(uint64_t h, int op, int d, double v, uint64_t t) {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    return impl_->valid(h) && impl_->host->control(op, d, v, t);
}
bool Registry::crossfade(uint64_t h,int out,uint64_t og,int in,uint64_t ig,uint64_t ms) {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    return impl_->valid(h) && impl_->host->crossfade(out,og,in,ig,ms);
}
bool Registry::prepareSchedule(uint64_t h,uint64_t revision,const std::vector<std::string>& paths,const std::vector<int64_t>& values) {
    std::lock_guard<std::mutex> lock(impl_->mutex);return impl_->valid(h)&&impl_->host->prepareSchedule(revision,paths,values);
}
bool Registry::prepareScheduleV2(uint64_t h,uint64_t revision,const std::vector<std::string>& paths,const std::vector<int64_t>& values,const std::vector<double>& tempo) {
    std::lock_guard<std::mutex> lock(impl_->mutex);return impl_->valid(h)&&impl_->host->prepareSchedule(revision,paths,values,&tempo);
}
bool Registry::arrangement(uint64_t h,int op,uint64_t value) {
    std::lock_guard<std::mutex> lock(impl_->mutex);return impl_->valid(h)&&impl_->host->arrangement(op,value);
}
bool Registry::scratch(uint64_t h,int op,uint64_t instance,uint64_t gesture,uint64_t event,double rate) {
    std::lock_guard<std::mutex> lock(impl_->mutex);return impl_->valid(h)&&impl_->host->scratch(op,instance,gesture,event,rate);
}
bool Registry::sync(uint64_t h,uint64_t incoming,uint64_t reference,int beats,double rb,double ra,double ro,double ib,double ia,double io) {
    if(beats<0)return false;
    std::lock_guard<std::mutex> lock(impl_->mutex);return impl_->valid(h)&&impl_->host->sync({incoming,reference,static_cast<uint32_t>(beats),rb,ra,ro,ib,ia,io});
}
#ifdef SOUNDQ_CALLBACK_TEST_SCHEDULE_DRIVER
bool Registry::testScheduleSnapshot(uint64_t h,TestScheduleSnapshot& result) {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if(!impl_->valid(h))return false;
    auto& host=*impl_->host;host.pump();
    if(!host.capture(result.value))return false;
    result.refused=host.tempoRefused;result.history=0;result.error=0;result.revision=host.schedule?host.schedule->revision:0;
    if(host.schedule)for(const auto& clip:host.schedule->clips)result.history+=clip.tempoHistory.size();
    result.ready=host.scheduleReady && host.schedule && result.value.scheduleRevision==host.schedule->revision && host.engine->completedStructuralSequence()>=host.scheduleReceipt;
    for(const auto& worker:host.scheduleWorkers){
        result.ready=result.ready && worker && worker->ready(result.value);
        if(worker && worker->error())result.error=worker->error();
    }
    return true;
}
bool Registry::testScheduleWorkPending(uint64_t h) {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if(!impl_->valid(h))return true;
    auto& host=*impl_->host;
    bool pending=host.engine->completedStructuralSequence()<host.sequence ||
        (host.tempoGraph && !host.tempoReceipt) || (host.tempoTarget.tag && !host.tempoGraph) || (host.schedule && !host.scheduleReady);
    for(const auto& worker:host.scheduleWorkers)pending=pending || (worker && worker->testWorkPending());
    if(!pending)return false;
    host.pump();
    for(const auto& worker:host.scheduleWorkers)if(worker && worker->testWorkPending())return true;
    return host.engine->completedStructuralSequence()<host.sequence || (host.tempoGraph && !host.tempoReceipt);
}
#endif
uint64_t Registry::reserveTempo(uint64_t h,uint64_t revision,uint64_t instance,double sourceBpm,double origin) {
    std::lock_guard<std::mutex> lock(impl_->mutex);return impl_->valid(h)?impl_->host->reserveTempo(revision,instance,sourceBpm,origin):0;
}
bool Registry::restoreTempo(uint64_t h,uint64_t reservation,uint64_t tag) {
    std::lock_guard<std::mutex> lock(impl_->mutex);return impl_->valid(h)&&impl_->host->restoreTempo(reservation,tag);
}
bool Registry::releaseTempo(uint64_t h,uint64_t reservation) {
    std::lock_guard<std::mutex> lock(impl_->mutex);return impl_->valid(h)&&impl_->host->releaseTempo(reservation);
}
bool Registry::liveTempo(uint64_t h,uint64_t revision,uint64_t instance,uint64_t tag,double sourceBpm,double bpm,uint64_t glide,uint64_t reservation) {
    std::lock_guard<std::mutex> lock(impl_->mutex);return impl_->valid(h)&&impl_->host->liveTempo(revision,instance,tag,sourceBpm,bpm,glide,reservation);
}
std::string Registry::state(uint64_t h) {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    return impl_->valid(h) ? impl_->host->state() : "{\"error\":-10002,\"decks\":[]}";
}
bool Registry::close(uint64_t h) {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (!impl_->valid(h) || !impl_->host->close()) return false;
    impl_->host.reset(); impl_->handle = 0; return true;
}
}

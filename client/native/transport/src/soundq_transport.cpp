#include "soundq_transport.hpp"
#include "soundq_tempo_map.hpp"

#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstddef>
#include <cstring>
#include <limits>
#include <stdexcept>
#include <set>
#include <chrono>

namespace soundq::transport {
#ifdef SOUNDQ_TRANSPORT_TEST_BARRIERS
namespace test {
std::atomic<unsigned> holdStage{0};
std::atomic<unsigned> reachedStage{0};
void barrier(unsigned stage) noexcept {
    if (holdStage.load(std::memory_order_acquire) != stage) return;
    reachedStage.store(stage, std::memory_order_release);
    while (holdStage.load(std::memory_order_acquire) == stage) {}
}
}
#endif
namespace {
constexpr uint64_t queueCapacity = 64;
constexpr std::size_t deckWords = 30;
constexpr std::size_t snapshotWords = 5 + 4 * deckWords + 10 + 64 * 3;
static_assert(std::atomic<uint64_t>::is_always_lock_free,
              "Transport requires lock-free 64-bit atomics");
uint64_t bits(double value) noexcept {
    uint64_t result;
    std::memcpy(&result, &value, sizeof(result));
    return result;
}
double number(uint64_t value) noexcept {
    double result;
    std::memcpy(&result, &value, sizeof(result));
    return result;
}
// All payload words are atomic. Sequential consistency orders the version and
// payload across overlapping reads; no non-atomic seqlock data races are possible.
template<std::size_t N> struct AtomicPublication {
    std::atomic<uint64_t> version{0};
    std::array<std::atomic<uint64_t>, N> words{};
    void store(const std::array<uint64_t, N>& input) noexcept {
        version.fetch_add(1);
        for (std::size_t i = 0; i < N; ++i) words[i].store(input[i]);
        version.fetch_add(1);
    }
    bool load(std::array<uint64_t, N>& output) const noexcept {
        for (unsigned attempt = 0; attempt < 8; ++attempt) {
            const auto before = version.load();
            if ((before & 1U) != 0) continue;
            for (std::size_t i = 0; i < N; ++i) output[i] = words[i].load();
            if (before == version.load()) return true;
        }
        return false;
    }
};
struct Ramp {
    double value = 1;
    double target = 1;
    double step = 0;
    uint32_t remaining = 0;
    void set(double next) noexcept {
        target = next; remaining = 128; step = (target - value) / 128;
    }
    void advance() noexcept {
        if (remaining != 0 && --remaining == 0) value = target;
        else if (remaining != 0) value += step;
    }
};
enum class EnvelopeKind { Command, AssignPaged, Window, Unassign, ScheduleInstall, ScheduleBind, ScheduleTransport, Scratch, Sync, TempoHandoff, TempoUnchanged, Crossfade };
struct Envelope {
    EnvelopeKind kind = EnvelopeKind::Command;
    Command command{};
    PcmWindow window{};
    const Schedule* schedule = nullptr;
    uint64_t frame = 0;
    uint32_t clip = 0;
    uint64_t eventNanos = 0;
    LiveSync sync{};
    uint64_t tempoTag=0; uint32_t changedMask=0;
    std::array<PcmWindow,4> tempoWindows{};
};
bool validExtent(uint64_t frames, uint32_t rate, uint64_t identity) noexcept {
    return frames != 0 && rate != 0 && identity != 0 && frames <= (uint64_t{1} << 52) &&
           frames <= std::numeric_limits<std::size_t>::max() / (2 * sizeof(float));
}
bool validWindow(const PcmWindow& window, uint64_t extent) noexcept {
    if (window.count > window.pages.size()) return false;
    uint64_t previousEnd = 0;
    for (uint32_t i = 0; i < window.count; ++i) {
        const auto& page = window.pages[i];
        if (!page.samples || page.frames == 0 || page.frames > maxPcmPageFrames ||
            page.firstFrame > extent || page.frames > extent - page.firstFrame ||
            page.firstFrame < previousEnd) return false;
        const auto bytes = static_cast<uint64_t>(page.frames) * 2 * sizeof(float);
        if (bytes > std::numeric_limits<std::size_t>::max() ||
            bytes > static_cast<uint64_t>(std::numeric_limits<std::ptrdiff_t>::max()) ||
            reinterpret_cast<std::uintptr_t>(page.samples) >
                std::numeric_limits<std::uintptr_t>::max() - bytes ||
            reinterpret_cast<std::uintptr_t>(page.samples) % alignof(float) != 0) return false;
        previousEnd = page.firstFrame + page.frames;
        for (uint64_t sample = 0; sample < static_cast<uint64_t>(page.frames) * 2; ++sample)
            if (!std::isfinite(page.samples[sample])) return false;
    }
    return true;
}
struct Deck {
    const ScheduleClip* scheduledClip = nullptr;
    Source source{};
    PcmWindow window{};
    bool paged = false;
    uint64_t missingPcmFrames = 0;
    const float* tap(uint64_t frame) const noexcept {
        if (!paged) return source.samples + static_cast<std::size_t>(frame) * 2;
        for (uint32_t i = 0; i < window.count; ++i) {
            const auto& page = window.pages[i];
            if (frame >= page.firstFrame && frame - page.firstFrame < page.frames)
                return page.samples + static_cast<std::size_t>(frame - page.firstFrame) * 2;
        }
        return nullptr;
    }
    uint64_t generation = 0;
    double cursor = 0;
    Ramp rate{};
    Ramp gain{};
    bool playing = false;
    bool scratching = false;
    bool savedPlaying = false;
    double savedRate = 1;
    uint64_t gesture = 0;
    uint64_t moveSequence = 0;
    uint64_t eofCount = 0;
    uint64_t traversalRevision = 0;
    uint64_t naturalEndCount = 0, naturalEndGeneration = 0, naturalEndIdentity = 0;
    uint64_t naturalEndTraversalRevision = 0;
    bool atEnd = false;
    bool performance = false;
    double nominal = 0;
    double sampleCursor = 0;
    bool residentNow = false;
    uint64_t moveEvent = 0, moveApplied = 0, moveFrame = 0, moveAge = 0;
    LiveSync link{};
    uint32_t syncState = 0;
    uint64_t boundary = 0;
    double targetCursor = -1, lockRate = 1, lockCursor = 0;
    uint64_t lockFrame = 0;
    double phaseError = 0;
    uint32_t fadeUp = 0;
};
struct ProducerDeck {
    uint64_t generation = 0;
    uint64_t frames = 0;
    uint64_t gesture = 0;
    uint64_t lastGesture = 0;
    uint64_t moveSequence = 0;
    bool paged = false;
};
} // namespace

struct Engine::Impl {
    explicit Impl(uint32_t rate) : outputRate(rate) { publish(); }
    const uint32_t outputRate;
    std::array<Envelope, queueCapacity> queue{};
    alignas(64) std::atomic<uint64_t> head{0};
    alignas(64) std::atomic<uint64_t> tail{0};
    std::array<Deck, 4> decks{};
    std::array<ProducerDeck, 4> producerDecks{}; // serialized control producer only
    struct Boundary { uint32_t out=0,in=1; uint64_t outGeneration=0,inGeneration=0,length=0,elapsed=0; double start=0; bool begun=false; } boundary;
    bool boundaryCurrent() const noexcept {
        return boundary.length && decks[boundary.out].generation==boundary.outGeneration &&
            decks[boundary.in].generation==boundary.inGeneration && decks[boundary.out].source.identity && decks[boundary.in].source.identity;
    }
    double boundaryGain(uint32_t slot) const noexcept {
        if(!boundaryCurrent())return 1;
        if(!boundary.begun)return slot==boundary.in?0:1;
        const auto phase=std::min(1.,double(boundary.elapsed)/boundary.length)*1.57079632679489661923;
        return slot==boundary.out?std::cos(phase):slot==boundary.in?std::sin(phase):1;
    }
    bool boundarySample() noexcept {
        if(!boundaryCurrent()) {boundary={};return true;}
        auto& a=decks[boundary.out];auto& b=decks[boundary.in];
        if(!a.playing || a.cursor>=a.source.frames)return true;
        if(!boundary.begun && a.cursor>=boundary.start) {boundary.begun=true;b.playing=true;}
        if(!boundary.begun || boundary.elapsed>=boundary.length)return true;
        // Missing PCM cannot advance just one side of an accepted overlap.
        for(auto* d:{&a,&b}) {const auto n=static_cast<uint64_t>(d->cursor);if(n>=d->source.frames || !d->tap(n) || !d->tap(std::min(n+1,d->source.frames-1))){++d->missingPcmFrames;return false;}}
        return true;
    }
    const Schedule* schedule = nullptr;
    const Schedule* producerSchedule = nullptr;
    uint64_t globalFrame = 0;
    Envelope pendingTempo{}; bool hasPendingTempo=false;
    std::atomic<uint64_t> latestTempo{0};
    const Schedule* producerTempoGraph=nullptr;uint64_t producerTempoSequence=0;
    uint64_t tempoApplied=0,tempoTerminal=0,producerTempoTag=0;
    std::array<uint64_t,4> tempoGenerations{},tempoInstances{};
    std::array<double,4> tempoSourceBpms{};
    bool schedulePlaying = false, scheduleBuffering = false;
    Ramp masterGain{};
    std::size_t span = 0;
    struct Binding { uint64_t instance = 0; PcmWindow window{}; };
    std::array<std::array<Binding,2>,4> bindings{};
    uint64_t renderedFrames = 0;
    uint64_t appliedSequence = 0;
    uint64_t admittedSequence = 0; // producer only
    uint64_t consumedStructuralSequence = 0; // render consumer only
    std::atomic<uint64_t> completedStructural{0};
    std::atomic<uint64_t> refused{0};
    AtomicPublication<snapshotWords> publication;
    std::array<AtomicPublication<5>, 4> moves{};
    uint64_t lastGestureSequence = 0;
    uint64_t lastGestureEventNanos = 0;
    uint64_t lastGestureAppliedFrame = 0;
    uint64_t callbackNanos = 0;
    uint64_t producerGesture = 0, producerInstance = 0, producerLastGesture = 0, producerEvent = 0;
    uint64_t producerBeginSequence = 0;
    uint64_t cancelledGesture = 0, cancelledInstance = 0, cancelledEvent = 0;
    uint64_t latencyCount = 0, syncReschedules = 0;
    std::array<LatencySample,64> latency{};
    std::atomic<uint64_t> movesCoalesced{0};
    std::array<std::atomic<uint64_t>,4> consumedMoves{};

    bool reject() noexcept { refused.fetch_add(1, std::memory_order_relaxed); return false; }
    void publish() noexcept {
        std::array<uint64_t, snapshotWords> data{};
        data[0] = renderedFrames; data[1] = appliedSequence;
        data[2] = lastGestureEventNanos; data[3] = lastGestureAppliedFrame;
        data[4] = refused.load(std::memory_order_relaxed);
        for (std::size_t i = 0; i < 4; ++i) {
            const auto& d = decks[i]; const auto at = 5 + i * deckWords;
            data[at] = d.generation; data[at + 1] = d.source.identity;
            data[at + 2] = bits(d.cursor); data[at + 3] = bits(d.rate.value);
            data[at + 4] = d.playing; data[at + 5] = d.scratching;
            data[at + 6] = d.gesture; data[at + 7] = d.eofCount;
            data[at + 8] = d.missingPcmFrames; data[at + 9] = d.paged ? d.window.count : 0;
            const auto* c=d.scheduledClip;
            data[at+10]=bits(c?std::min(c->trimOut,sourceAt(*c,static_cast<double>(std::max(globalFrame,c->start)),outputRate)):d.nominal); data[at+11]=d.moveEvent; data[at+12]=d.moveApplied;
            data[at+13]=d.moveSequence; data[at+14]=d.scratching && d.rate.value==0;
            data[at+15]=d.link.reference; data[at+16]=d.link.beats; data[at+17]=d.syncState;
            data[at+18]=bits(d.phaseError); data[at+19]=bits(d.targetCursor); data[at+20]=d.boundary;
            data[at+21]=c && c->tempo.preserve?schedule->revision:0; data[at+22]=bits(c && c->tempo.preserve?tempoRate(*c,globalFrame)*c->tempo.sourceBpm:(c && tempoInstances[i]==c->instance?tempoSourceBpms[i]:0));
            data[at+23]=tempoInstances[i]==d.source.identity?tempoGenerations[i]:0;
            data[at+24]=bits(boundaryGain(static_cast<uint32_t>(i)));
            data[at+25]=d.traversalRevision; data[at+26]=d.naturalEndCount;
            data[at+27]=d.naturalEndGeneration; data[at+28]=d.naturalEndIdentity;
            data[at+29]=d.naturalEndTraversalRevision;
        }
        constexpr auto at=5+4*deckWords;
        data[at] = schedule ? schedule->revision : 0;
        data[at+1] = globalFrame; data[at+2] = schedule ? schedule->duration : 0;
        data[at+3] = (schedulePlaying?1U:0U)|(scheduleBuffering?2U:0U); data[at+4] = schedule && globalFrame >= schedule->duration;
        data[at+5]=latencyCount; data[at+6]=movesCoalesced.load(); data[at+7]=syncReschedules;
        for(size_t i=0;i<latency.size();++i) {data[at+8+3*i]=latency[i].eventNanos;data[at+9+3*i]=latency[i].appliedNanos;data[at+10+3*i]=latency[i].sequence;}
        data[snapshotWords-2]=tempoApplied;data[snapshotWords-1]=tempoTerminal;
        publication.store(data);
    }
    void apply(const Command& c) noexcept {
        auto& d = decks[c.deck];
        if (c.operation == Operation::Assign) {
            d = Deck{}; d.source = c.source; d.generation = c.generation;
            d.traversalRevision = c.sequence;
        } else if (c.generation != d.generation) {
            refused.fetch_add(1, std::memory_order_relaxed); return;
        } else if (c.operation == Operation::Play) {
            d.playing = d.cursor < static_cast<double>(d.source.frames) || d.rate.target < 0 || !d.atEnd;
        } else if (c.operation == Operation::Pause) {
            d.playing = false;
        } else if (c.operation == Operation::Seek) {
            // Seeking positions the cursor. Completion belongs to admitted forward
            // motion, including Play after a paused seek to the exact endpoint.
            d.cursor = c.value; d.atEnd = false;
            d.traversalRevision = c.sequence;
        } else if (c.operation == Operation::SetRate) {
            d.traversalRevision = c.sequence;
            d.rate.set(c.value);
            d.moveSequence = std::max(d.moveSequence, c.sequence);
        } else if (c.operation == Operation::SetGain) {
            d.gain.set(c.value);
        } else if (c.operation == Operation::BeginScratch) {
            d.traversalRevision = c.sequence;
            d.savedPlaying = d.playing; d.savedRate = d.rate.target;
            d.scratching = true; d.gesture = c.gesture; d.moveSequence = c.sequence;
            d.playing = true;
        } else if (c.operation == Operation::EndScratch || c.operation == Operation::CancelScratch) {
            if (d.scratching && d.gesture == c.gesture) {
                d.scratching = false; d.gesture = 0;
                d.playing = d.savedPlaying && (d.cursor < static_cast<double>(d.source.frames) || d.savedRate < 0);
                d.rate.set(d.savedRate);
            }
        }
        appliedSequence = std::max(appliedSequence, c.sequence);
    }
    void apply(const Envelope& envelope) noexcept {
        const auto& c = envelope.command;
        if(envelope.kind==EnvelopeKind::Crossfade) {
            const auto out=c.deck,in=envelope.clip;
            if(decks[out].generation==c.generation && decks[in].generation==c.gesture) {
                if(!envelope.frame) {decks[in].playing=false;boundary={};}
                else {
                    auto& a=decks[out];auto& b=decks[in];
                    const auto remaining=static_cast<uint64_t>(std::ceil((a.source.frames-a.cursor)*outputRate/a.source.sourceRate));
                    const auto incoming=static_cast<uint64_t>(std::floor(b.source.frames*double(outputRate)/b.source.sourceRate/2));
                    const auto length=std::min({envelope.frame,remaining,incoming});
                    if(length && !b.playing && b.cursor==0 && !a.scratching && !b.scratching) {
                        boundary={out,in,c.generation,c.gesture,length,0,a.source.frames-double(length)*a.source.sourceRate/outputRate,false};
                    }
                }
            }
        } else if (envelope.kind == EnvelopeKind::ScheduleInstall) {
            boundary={};
            schedule = envelope.schedule; globalFrame = envelope.frame; schedulePlaying = false; span = 0;
            bindings = {}; decks = {};
            if(hasPendingTempo)tempoTerminal=std::max(tempoTerminal,pendingTempo.tempoTag);
            hasPendingTempo=false;tempoGenerations={};tempoInstances={};tempoSourceBpms={};
            if(schedule) span=static_cast<std::size_t>(std::upper_bound(schedule->spans.begin(),schedule->spans.end(),globalFrame,[](uint64_t f,const Schedule::Span& s){return f<s.end;})-schedule->spans.begin());
        } else if(envelope.kind==EnvelopeKind::TempoUnchanged) {
            if(schedule && schedule->revision==c.generation && envelope.tempoTag==latestTempo.load(std::memory_order_acquire)) {
                for(const auto& clip:schedule->clips)if(clip.instance==c.source.identity && globalFrame>=clip.start && globalFrame<clip.end) {
                    const auto& law=clip.tempo;
                    const bool constant=clip.tempoHistory.empty() || globalFrame>=clip.mapFrame;
                    if(constant && (!law.preserve ? c.value==1 : (law.startBpm==law.endBpm || globalFrame>=law.end) && law.endBpm/law.sourceBpm==c.value)) {
                        tempoApplied=envelope.tempoTag;tempoGenerations[clip.slot]=envelope.tempoTag;
                        tempoInstances[clip.slot]=clip.instance;tempoSourceBpms[clip.slot]=envelope.sync.incomingBpm;
                    }
                }
            }
            tempoTerminal=std::max(tempoTerminal,envelope.tempoTag);
        } else if(envelope.kind==EnvelopeKind::TempoHandoff) {
            if(hasPendingTempo)tempoTerminal=std::max(tempoTerminal,pendingTempo.tempoTag);
            pendingTempo=envelope;hasPendingTempo=true;
        } else if (envelope.kind == EnvelopeKind::ScheduleBind) {
            if (schedule && schedule->revision == c.generation) {
                const auto& clip = schedule->clips[envelope.clip];
                bindings[clip.slot][schedule->banks[envelope.clip]] = {clip.instance, envelope.window};
            }
        } else if (envelope.kind == EnvelopeKind::Scratch) {
            auto* d = active(c.source.identity);
            if (!d || !schedule || schedule->revision!=c.generation) { reject(); }
            else if(c.operation==Operation::BeginScratch) {
                bool master=false;for(const auto& peer:decks)if(peer.link.reference==d->source.identity && peer.syncState!=0 && peer.syncState!=5)master=true;
                if(master || d->scratching || !d->residentNow) {reject();consumedStructuralSequence=c.sequence;return;}
                d->savedPlaying=schedulePlaying; d->savedRate=d->rate.target;
                d->performance=true; d->scratching=true; d->gesture=c.gesture;
                d->rate=Ramp{}; d->rate.value=d->rate.target=0;
                d->moveSequence=c.sequence; d->moveEvent=envelope.eventNanos;
                d->moveApplied=callbackNanos; d->moveFrame=renderedFrames;
                d->moveAge=callbackNanos>envelope.eventNanos?std::min<uint64_t>(outputRate,(callbackNanos-envelope.eventNanos)*outputRate/1000000000):0;
                d->targetCursor=-1; d->boundary=0;
                if(d->link.reference)d->syncState=3;
                receipt(envelope.eventNanos,c.sequence);
            } else if(d->scratching && d->gesture==c.gesture) {
                // A terminal never depends on a conflated move being consumed.
                d->scratching=false; d->gesture=0; d->rate.set(d->savedRate);d->fadeUp=64;
                if(d->link.reference && d->savedPlaying && schedulePlaying) {d->syncState=4;d->boundary=0;}
                else if(!d->savedPlaying) {d->rate.value=d->rate.target=d->savedRate;d->rate.remaining=0;}
                receipt(envelope.eventNanos,c.sequence);
            }
        } else if (envelope.kind == EnvelopeKind::Sync) {
            if(auto* d=active(envelope.sync.incoming)) {
                auto* ref=active(envelope.sync.reference);
                bool master=false;for(const auto& peer:decks)if(peer.link.reference==d->source.identity && peer.syncState!=0 && peer.syncState!=5)master=true;
                if(envelope.sync.beats && (!ref || ref->scratching || d->scratching || master || ref->syncState==1 || ref->syncState==4 || ref->rate.remaining))reject();
                else {d->link=envelope.sync.beats?envelope.sync:LiveSync{}; d->boundary=0;d->targetCursor=-1;d->syncState=d->link.beats?1:0;}
            }
        } else if (envelope.kind == EnvelopeKind::ScheduleTransport) {
            if (schedule && schedule->revision == c.generation) {
                if((c.gesture==2 || c.gesture==3) && hasPendingTempo){tempoTerminal=std::max(tempoTerminal,pendingTempo.tempoTag);hasPendingTempo=false;}
                if (c.gesture == 3) { globalFrame = envelope.frame; span = static_cast<std::size_t>(std::upper_bound(schedule->spans.begin(),schedule->spans.end(),globalFrame,[](uint64_t f,const Schedule::Span& s){return f<s.end;})-schedule->spans.begin()); schedulePlaying = false;decks={}; }
                else if(c.gesture==7) masterGain.set(c.value);
                else schedulePlaying = c.gesture == 1 && globalFrame < schedule->duration;
                if(c.gesture==2)for(auto& d:decks) {
                    if(d.scratching){d.scratching=false;d.gesture=0;d.rate.value=d.rate.target=d.savedRate;d.rate.remaining=0;}
                    d.link={};d.syncState=0;d.boundary=0;d.targetCursor=-1;
                }
            }
        } else if (envelope.kind == EnvelopeKind::Command) {
            apply(c);
            if(boundaryCurrent() && (c.deck==boundary.out || c.deck==boundary.in)) {
                if(c.operation==Operation::Pause) {decks[boundary.out].playing=false;decks[boundary.in].playing=false;}
                if(c.operation==Operation::Play) {
                    auto& a=decks[boundary.out];auto& b=decks[boundary.in];
                    a.playing=a.cursor<a.source.frames;b.playing=boundary.begun && b.cursor<b.source.frames;
                }
            }
        } else {
            auto& d = decks[c.deck];
            if (envelope.kind == EnvelopeKind::AssignPaged) {
                d = Deck{}; d.source = c.source; d.generation = c.generation;
                d.traversalRevision = c.sequence;
                d.paged = true; d.window = envelope.window;
            } else if (envelope.kind == EnvelopeKind::Window) {
                d.window = envelope.window;
            } else {
                d = Deck{}; d.generation = c.generation;
            }
            appliedSequence = std::max(appliedSequence, c.sequence);
        }
        consumedStructuralSequence = c.sequence;
    }
    bool enqueue(const Envelope& envelope, const ProducerDeck& next) noexcept {
        const auto position = head.load(std::memory_order_relaxed);
        if (position - tail.load(std::memory_order_acquire) >= queueCapacity) return reject();
        queue[position % queueCapacity] = envelope;
        head.store(position + 1, std::memory_order_release);
        producerDecks[envelope.command.deck] = next;
        admittedSequence = envelope.command.sequence;
        return true;
    }
    Deck* active(uint64_t id) noexcept {
        if(!schedule)return nullptr;
        for(auto& d:decks)if(d.source.identity==id && d.scheduledClip && globalFrame>=d.scheduledClip->start && globalFrame<d.scheduledClip->end)return &d;
        return nullptr;
    }
    const ScheduleClip* clip(uint64_t id)const noexcept {
        for(const auto& d:decks)if(d.source.identity==id)return d.scheduledClip;
        return nullptr;
    }
    void receipt(uint64_t event,uint64_t seq) noexcept {
        latency[latencyCount++%latency.size()]={event,callbackNanos,seq};
        lastGestureEventNanos=event;lastGestureAppliedFrame=renderedFrames;
    }
    bool planBoundary(Deck& d,const ScheduleClip& c) noexcept {
        auto* ref=active(d.link.reference);const auto* rc=clip(d.link.reference);
        if(!ref || !rc || ref->scratching || ref->rate.target<=0 || ref->rate.remaining) return false;
        const double speed=ref->rate.target*d.link.referenceBpm/d.link.incomingBpm;
        if(speed<.25 || speed>4)return false;
        const double rp=rc->sourceRate*60./d.link.referenceBpm;
        const double ip=c.sourceRate*60./d.link.incomingBpm;
        const double referencePhase=(ref->sampleCursor-d.link.referenceAnchorMs*rc->sourceRate/1000.)/rp;
        const double incomingPhase=(d.sampleCursor-d.link.incomingAnchorMs*c.sourceRate/1000.)/ip;
        // Before the scheduled jump publish the actual phase residual, not an
        // assumed zero. The grouped residual is relative to explicit origins.
        d.phaseError=std::remainder(incomingPhase-referencePhase,static_cast<double>(d.link.beats))*60.*outputRate/(d.link.referenceBpm*ref->rate.target);
        const double ro=(d.link.beats==1?d.link.referenceAnchorMs:d.link.referenceOriginMs)*rc->sourceRate/1000.;
        const double io=(d.link.beats==1?d.link.incomingAnchorMs:d.link.incomingOriginMs)*c.sourceRate/1000.;
        const double step=ref->rate.target*rc->sourceRate/outputRate;
        const auto lead=std::max<uint64_t>(256,outputRate/10); // 100ms off-callback preparation lead.
        const double period=rp*d.link.beats;
        const double k=std::ceil((ref->sampleCursor+lead*step-ro)/period);
        const double rtarget=ro+k*period;
        const auto delta=static_cast<uint64_t>(std::ceil((rtarget-ref->sampleCursor)/step));
        if(delta>c.end-globalFrame || globalFrame+delta>=c.end || globalFrame+delta>=rc->end)return false;
        // Choose a legal incoming group nearest its forward continuation. No wrap.
        const double future=d.cursor+delta*speed*c.sourceRate/outputRate;
        const double first=std::ceil((c.trimIn-io)/(ip*d.link.beats));
        const double last=std::floor((std::nextafter(c.trimOut,c.trimIn)-io)/(ip*d.link.beats));
        if(first>last)return false;
        const double ik=std::clamp(std::round((future-io)/(ip*d.link.beats)),first,last);
        d.boundary=globalFrame+delta;
        // Subframe boundary correction keeps both pulse trains within one output frame.
        d.targetCursor=io+ik*ip*d.link.beats+(delta*step-(rtarget-ref->sampleCursor))*speed*c.sourceRate/(ref->rate.target*rc->sourceRate);
        d.lockRate=speed;
        return d.targetCursor>=c.trimIn && d.targetCursor<c.trimOut;
    }
    void consumeTempo() noexcept {
        if(!hasPendingTempo)return;
        const auto& p=pendingTempo;
        if(p.tempoTag!=latestTempo.load(std::memory_order_acquire) || !schedule || p.schedule->revision!=schedule->revision || globalFrame>p.frame) {
            tempoTerminal=std::max(tempoTerminal,p.tempoTag);hasPendingTempo=false;return;
        }
        if(globalFrame!=p.frame)return;
        schedule=p.schedule;
        for(size_t i=0;i<schedule->clips.size();++i){const auto& c=schedule->clips[i];if((p.changedMask&(1U<<c.slot)) && globalFrame>=c.start && globalFrame<c.end){bindings[c.slot][schedule->banks[i]]={c.instance,p.tempoWindows[c.slot]};tempoGenerations[c.slot]=p.tempoTag;tempoInstances[c.slot]=c.instance;}}
        for(auto& d:decks)if(d.scheduledClip){for(const auto& c:schedule->clips)if(c.instance==d.source.identity){d.scheduledClip=&c;break;}}
        span=static_cast<size_t>(std::upper_bound(schedule->spans.begin(),schedule->spans.end(),globalFrame,[](uint64_t f,const Schedule::Span& s){return f<s.end;})-schedule->spans.begin());
        tempoApplied=p.tempoTag;tempoTerminal=std::max(tempoTerminal,p.tempoTag);hasPendingTempo=false;
    }
    void scheduleSample(double& left, double& right, uint64_t outputFrame) noexcept {
        consumeTempo();
        masterGain.advance();
        for (auto& d : decks) d.playing = false;
        if (!schedule) return;
        while (span < schedule->spans.size() && globalFrame >= schedule->spans[span].end) ++span;
        // Establish the complete active set at this sample before consulting a
        // master. Slot order is not time order and must not add one-frame skew.
        if(span<schedule->spans.size())for(const auto ci:schedule->spans[span].clips) {
            if(ci<0)continue;const auto& c=schedule->clips[ci];auto& d=decks[c.slot];
            if(d.source.identity!=c.instance){d=Deck{};d.generation=schedule->revision;d.cursor=sourceAt(c,static_cast<double>(globalFrame),outputRate);}
            d.source={nullptr,c.sourceFrames,c.sourceRate,c.instance};d.scheduledClip=&c;
            const auto& b=bindings[c.slot][schedule->banks[ci]];d.paged=true;d.window=b.instance==c.instance?b.window:PcmWindow{};
            if(!d.performance)d.cursor=sourceAt(c,static_cast<double>(globalFrame),outputRate);
            d.sampleCursor=d.syncState==2?d.lockCursor+static_cast<double>(globalFrame-d.lockFrame)*d.lockRate*c.sourceRate/outputRate:d.cursor;
            const auto tap=static_cast<uint64_t>(std::clamp(d.sampleCursor,0.,static_cast<double>(c.sourceFrames-1)));
            d.residentNow=d.sampleCursor>=c.trimIn && d.sampleCursor<c.trimOut && d.tap(tap) && d.tap(std::min(tap+1,c.sourceFrames-1));
        }
        if (span < schedule->spans.size()) for (const auto ci : schedule->spans[span].clips) {
            if (ci < 0) continue;
            const auto& c = schedule->clips[ci];
            auto& d = decks[c.slot];
            const auto& binding = bindings[c.slot][schedule->banks[ci]];
            if (d.source.identity != c.instance) { d = Deck{}; d.generation = schedule->revision;d.cursor=sourceAt(c,static_cast<double>(globalFrame),outputRate); }
            d.source = {nullptr,c.sourceFrames,c.sourceRate,c.instance}; d.paged = true;
            d.scheduledClip=&c;
            d.window = binding.instance == c.instance ? binding.window : PcmWindow{};
            d.nominal = std::min(c.trimOut,sourceAt(c,static_cast<double>(globalFrame),outputRate));
            if(!d.performance)d.cursor=d.nominal;
            d.playing = schedulePlaying || d.scratching;
            if(c.tempo.preserve) {
                d.rate.value=d.rate.target=tempoRate(c,static_cast<double>(globalFrame));d.rate.remaining=0;
                const double position=preparedAt(c,globalFrame,outputRate);
                const auto index=static_cast<uint64_t>(position), last=preparedExtent(c,outputRate)-1;
                const auto* a=d.tap(index);const auto* b=d.tap(std::min(index+1,last));
                d.residentNow=a && b;
                if(d.playing && a && b) {
                    const auto local=globalFrame-c.start;
                    double shape=1;
                    if(c.fadeIn && local<c.fadeIn)shape=static_cast<double>(local)/c.fadeIn;
                    if(c.fadeOut && c.end-globalFrame<c.fadeOut)shape=std::min(shape,static_cast<double>(c.end-globalFrame)/c.fadeOut);
                    const double gain=masterGain.value*c.gain*std::sin(shape*1.57079632679489661923), f=position-index;
                    left+=gain*(a[0]*(1-f)+b[0]*f);right+=gain*(a[1]*(1-f)+b[1]*f);
                }
                d.cursor=d.nominal=std::min(c.trimOut,sourceAt(c,static_cast<double>(globalFrame+(schedulePlaying?1:0)),outputRate));
                d.rate.value=d.rate.target=tempoRate(c,static_cast<double>(globalFrame+(schedulePlaying?1:0)));
                continue;
            }
            if(d.scratching && outputFrame-d.moveFrame+d.moveAge>=uint64_t{outputRate}*40/1000-std::min<uint32_t>(128,outputRate*40/1000) && d.rate.target!=0)d.rate.set(0);
            d.rate.advance();
            if((d.syncState==1 || d.syncState==4) && schedulePlaying && !d.boundary) {
                if(!planBoundary(d,c)){d.syncState=5;d.targetCursor=-1;d.rate.value=d.rate.target=0;d.rate.remaining=0;d.performance=true;}
            }
            if((d.syncState==1 || d.syncState==4) && d.boundary && globalFrame>=d.boundary) {
                const auto* a=d.tap(static_cast<uint64_t>(d.targetCursor));
                const auto* b=d.tap(std::min(static_cast<uint64_t>(d.targetCursor)+1,c.sourceFrames-1));
                const auto* ref=active(d.link.reference);
                if(a && b && ref && ref->residentNow && !ref->scratching) {
                    d.cursor=d.targetCursor; d.rate.value=d.rate.target=d.lockRate;d.rate.remaining=0;
                    d.performance=true;d.lockFrame=globalFrame;d.lockCursor=d.cursor;d.syncState=2;d.fadeUp=64;d.targetCursor=-1;
                } else {++syncReschedules;d.boundary=0;d.targetCursor=-1;if(!planBoundary(d,c)){d.syncState=5;d.rate.value=d.rate.target=0;d.rate.remaining=0;d.performance=true;}}
            }
            if(d.syncState==2) {
                if(!active(d.link.reference)) {d.syncState=5;d.targetCursor=-1;d.rate.value=d.rate.target=0;d.rate.remaining=0;}
                else if(!active(d.link.reference)->residentNow){d.syncState=4;d.boundary=0;d.targetCursor=-1;}
                else {
                    d.cursor=d.lockCursor+static_cast<double>(globalFrame-d.lockFrame)*d.lockRate*c.sourceRate/outputRate;
                    const auto* ref=active(d.link.reference);const auto* rc=ref->scheduledClip;
                    const double ro=(d.link.beats==1?d.link.referenceAnchorMs:d.link.referenceOriginMs)*rc->sourceRate/1000.;
                    const double io=(d.link.beats==1?d.link.incomingAnchorMs:d.link.incomingOriginMs)*c.sourceRate/1000.;
                    const double rb=(ref->sampleCursor-ro)/rc->sourceRate*d.link.referenceBpm/60.;
                    const double ib=(d.cursor-io)/c.sourceRate*d.link.incomingBpm/60.;
                    d.phaseError=std::remainder(ib-rb,static_cast<double>(d.link.beats))*60.*outputRate/(d.link.referenceBpm*ref->rate.target);
                }
            }
            if (!d.playing) continue;
            const double position=d.cursor;
            if(d.syncState==2 && (position<c.trimIn || position>=c.trimOut)){d.syncState=5;d.cursor=std::clamp(d.cursor,c.trimIn,c.trimOut);}
            const bool audible=position>=c.trimIn && position<c.trimOut && d.rate.value!=0 && !(position==c.trimIn && d.rate.value<0);
            if(!audible) {
                if(d.performance && d.rate.value<0)d.cursor=std::clamp(d.cursor+d.rate.value*c.sourceRate/outputRate,c.trimIn,c.trimOut);
                continue;
            }
            const auto index = static_cast<uint64_t>(d.cursor);
            const auto next = std::min(index+1,c.sourceFrames-1);
            const auto* a = d.tap(index); const auto* b = d.tap(next);
            const bool resident=a && b;
            if(!resident) {++d.missingPcmFrames;if(d.syncState==2){d.syncState=4;d.boundary=0;d.targetCursor=-1;}}
            const auto local = globalFrame-c.start;
            double shape = 1;
            if (c.fadeIn && local < c.fadeIn) shape = static_cast<double>(local)/c.fadeIn;
            if (c.fadeOut && c.end-globalFrame < c.fadeOut) shape = std::min(shape,static_cast<double>(c.end-globalFrame)/c.fadeOut);
            double transition=1;
            if((d.syncState==1 || d.syncState==4) && d.boundary>globalFrame && d.boundary-globalFrame<=64)transition=static_cast<double>(d.boundary-globalFrame)/64;
            if(d.fadeUp){transition*=static_cast<double>(64-d.fadeUp)/64;--d.fadeUp;}
            const auto gain = masterGain.value * c.gain * std::sin(shape*1.57079632679489661923)*transition*(d.scratching?std::min(1.,std::abs(d.rate.value)):1.);
            const auto fraction = d.cursor-index;
            if(resident) {left += gain*(a[0]*(1-fraction)+b[0]*fraction);right += gain*(a[1]*(1-fraction)+b[1]*fraction);}
            if(d.performance) d.cursor=std::clamp(d.cursor+d.rate.value*c.sourceRate/outputRate,c.trimIn,c.trimOut);
            else d.cursor=std::min(c.trimOut,c.trimIn+static_cast<double>(globalFrame+1-c.start)*c.sourceRate/outputRate);
            d.nominal=std::min(c.trimOut,c.trimIn+static_cast<double>(globalFrame+1-c.start)*c.sourceRate/outputRate);
        }
        if (schedulePlaying && ++globalFrame >= schedule->duration) { schedulePlaying = false; for(auto& d:decks)d.playing=false; }
        for(auto& d:decks)if(d.source.identity) {const auto* c=d.scheduledClip;if(!c || globalFrame>=c->end){d.playing=false;d.scratching=false;d.gesture=0;d.link={};d.syncState=0;d.targetCursor=-1;d.boundary=0;}}
    }
    bool preparedBlock(uint32_t frames) noexcept {
        if(!schedule || !schedulePlaying)return true;
        if(!schedule->hasPreservedTempo && !hasPendingTempo)return true;
        size_t at=span;
        const uint64_t duration=hasPendingTempo && pendingTempo.tempoTag==latestTempo.load(std::memory_order_acquire)?std::max(schedule->duration,pendingTempo.schedule->duration):schedule->duration;
        for(uint32_t n=0;n<frames && globalFrame+n<duration;++n) {
            const uint64_t frame=globalFrame+n;
            const bool next=hasPendingTempo && pendingTempo.tempoTag==latestTempo.load(std::memory_order_acquire) && frame>=pendingTempo.frame && globalFrame<=pendingTempo.frame;
            const auto* graph=next?pendingTempo.schedule:schedule;
            if(next)at=static_cast<size_t>(std::upper_bound(graph->spans.begin(),graph->spans.end(),frame,[](uint64_t f,const Schedule::Span& s){return f<s.end;})-graph->spans.begin());
            else while(at<graph->spans.size() && frame>=graph->spans[at].end)++at;
            if(at==graph->spans.size())break;
            for(auto ci:graph->spans[at].clips)if(ci>=0) {
                const auto& c=graph->clips[ci];
                Binding b=bindings[c.slot][graph->banks[ci]];
                if(next && (pendingTempo.changedMask&(1U<<c.slot)) && pendingTempo.frame>=c.start && pendingTempo.frame<c.end)b={c.instance,pendingTempo.tempoWindows[c.slot]};
                // Raw performance keeps legacy independent residency semantics.
                // Its signed cursor/ramp can diverge from nominal global time and
                // is not a member of a preserved shared pulse.
                if(!c.tempo.preserve && decks[c.slot].source.identity==c.instance && decks[c.slot].performance)continue;
                double cursor=c.tempo.preserve?preparedAt(c,frame,outputRate):sourceAt(c,frame,outputRate);
                const auto extent=c.tempo.preserve?preparedExtent(c,outputRate):c.sourceFrames;
                const auto tap=static_cast<uint64_t>(std::clamp(cursor,0.,static_cast<double>(extent-1)));
                auto has=[&](uint64_t x){if(b.instance!=c.instance)return false;for(unsigned j=0;j<b.window.count;++j){const auto& p=b.window.pages[j];if(x>=p.firstFrame && x-p.firstFrame<p.frames)return true;}return false;};
                if(!has(tap) || !has(std::min(tap+1,extent-1))) {
                    decks[c.slot].missingPcmFrames+=frames;return false;
                }
            }
        }
        return true;
    }
    void applyMoves() noexcept {
        for (std::size_t i = 0; i < 4; ++i) {
            auto& d = decks[i];
            if (!d.scratching) continue; // Do not acknowledge pre-Begin payloads.
            std::array<uint64_t, 5> data{};
            if (!moves[i].load(data) || data[0] != d.generation || data[1] != d.gesture ||
                data[2] <= d.moveSequence) continue;
            d.rate.set(number(data[4])); d.moveSequence = data[2];
            if(schedule){d.moveEvent=data[3];d.moveApplied=callbackNanos;d.moveFrame=renderedFrames;d.moveAge=callbackNanos>data[3]?std::min<uint64_t>(outputRate,(callbackNanos-data[3])*outputRate/1000000000):0;receipt(data[3],data[2]);consumedMoves[i].store(data[2]);}
            appliedSequence = std::max(appliedSequence, data[2]);
            if (data[2] > lastGestureSequence) {
                lastGestureSequence = data[2];
                lastGestureEventNanos = data[3]; lastGestureAppliedFrame = renderedFrames;
            }
        }
    }
};

Engine::Engine(uint32_t outputRate) {
    if (outputRate == 0) throw std::invalid_argument("outputRate must be nonzero");
    impl_ = std::make_unique<Impl>(outputRate);
}
Engine::~Engine() = default;

bool Engine::submit(const Command& c) noexcept {
    auto& p = *impl_;
    if (p.producerSchedule || c.deck >= 4 || c.sequence == 0 || c.sequence <= p.admittedSequence || c.generation == 0 ||
        static_cast<uint32_t>(c.operation) > static_cast<uint32_t>(Operation::CancelScratch) ||
        !std::isfinite(c.value)) return p.reject();
    if ((c.operation == Operation::SetRate && (c.value < -8 || c.value > 8)) ||
        (c.operation == Operation::SetGain && (c.value < 0 || c.value > 8))) return p.reject();
    if (c.operation == Operation::Assign &&
        (!c.source.samples || !validExtent(c.source.frames, c.source.sourceRate, c.source.identity))) return p.reject();
    auto next = p.producerDecks[c.deck];
    if (c.operation == Operation::Assign) {
        if (c.generation <= next.generation) return p.reject();
        next = ProducerDeck{}; next.generation = c.generation; next.frames = c.source.frames;
    } else {
        if (c.generation != next.generation || next.frames == 0) return p.reject();
        if (c.operation == Operation::Seek && (c.value < 0 || c.value > static_cast<double>(next.frames)))
            return p.reject();
        if (c.operation == Operation::BeginScratch) {
            if (c.gesture == 0 || c.gesture <= next.lastGesture || next.gesture != 0) return p.reject();
            next.gesture = c.gesture; next.lastGesture = c.gesture; next.moveSequence = c.sequence;
        } else if (c.operation == Operation::EndScratch || c.operation == Operation::CancelScratch) {
            if (next.gesture == 0 || c.gesture != next.gesture) return p.reject();
            next.gesture = 0;
        }
    }
    const auto head = p.head.load(std::memory_order_relaxed);
    if (head - p.tail.load(std::memory_order_acquire) >= queueCapacity) return p.reject();
    // Source validation is intentionally control-side and linear in source extent.
    // The caller still owns valid storage and immutable PCM for Engine lifetime.
    if (c.operation == Operation::Assign) {
        for (uint64_t sample = 0; sample < c.source.frames * 2; ++sample)
            if (!std::isfinite(c.source.samples[sample])) return p.reject();
    }
    return p.enqueue({EnvelopeKind::Command, c, {}}, next);
}
bool Engine::assignPaged(uint32_t deck, uint64_t sequence, uint64_t generation,
                         const PagedSource& source, const PcmWindow& window) noexcept {
    auto& p = *impl_;
    if (p.producerSchedule || deck >= 4 || sequence == 0 || sequence <= p.admittedSequence || generation == 0 ||
        generation <= p.producerDecks[deck].generation ||
        !validExtent(source.frames, source.sourceRate, source.identity) ||
        !validWindow(window, source.frames)) return p.reject();
    Envelope envelope;
    envelope.kind = EnvelopeKind::AssignPaged;
    auto& c = envelope.command;
    c.deck = deck; c.sequence = sequence; c.generation = generation;
    c.source = {nullptr, source.frames, source.sourceRate, source.identity};
    envelope.window = window;
    ProducerDeck next;
    next.generation = generation; next.frames = source.frames; next.paged = true;
    return p.enqueue(envelope, next);
}
bool Engine::publishWindow(uint32_t deck, uint64_t sequence, uint64_t generation,
                           const PcmWindow& window) noexcept {
    auto& p = *impl_;
    if (p.producerSchedule || deck >= 4 || sequence == 0 || sequence <= p.admittedSequence || generation == 0)
        return p.reject();
    const auto& current = p.producerDecks[deck];
    if (generation != current.generation || current.frames == 0 || !current.paged ||
        !validWindow(window, current.frames)) return p.reject();
    Envelope envelope;
    envelope.kind = EnvelopeKind::Window;
    envelope.command.deck = deck; envelope.command.sequence = sequence;
    envelope.command.generation = generation; envelope.window = window;
    return p.enqueue(envelope, current);
}
bool Engine::unassign(uint32_t deck, uint64_t sequence, uint64_t generation) noexcept {
    auto& p = *impl_;
    if (p.producerSchedule || deck >= 4 || sequence == 0 || sequence <= p.admittedSequence || generation == 0)
        return p.reject();
    const auto& current = p.producerDecks[deck];
    if (generation != current.generation || current.frames == 0) return p.reject();
    Envelope envelope;
    envelope.kind = EnvelopeKind::Unassign;
    envelope.command.deck = deck; envelope.command.sequence = sequence;
    envelope.command.generation = generation;
    ProducerDeck next;
    next.generation = generation;
    return p.enqueue(envelope, next);
}
std::unique_ptr<Schedule> Schedule::compile(uint64_t revision, uint32_t outputRate, const std::vector<ScheduleClip>& input) {
    if (!revision || !outputRate || input.empty() || input.size()>500) return nullptr;
    auto result=std::make_unique<Schedule>(); result->revision=revision; result->outputRate=outputRate;
    result->clips=input; result->banks.resize(input.size());
    struct Event {uint64_t frame; bool start; uint32_t clip;};
    std::vector<Event> events; std::set<uint64_t> ids;
    for(uint32_t i=0;i<input.size();++i) {
        auto& c=result->clips[i];
        if(!std::isfinite(c.mapFrame) || !std::isfinite(c.mapSource) || (c.mapFrame>=0 && (c.mapFrame<c.start || c.mapFrame>=(uint64_t{1}<<52) || c.mapSource<c.trimIn || c.mapSource>=c.trimOut)))return nullptr;
        if(c.tempoHistory.size()>maxTempoSegments)return nullptr;
        if(!c.tempoHistory.empty()) {
            if(!c.tempo.preserve || c.mapFrame<0 || c.tempoHistory.front().frame!=c.start || c.tempoHistory.front().source!=c.trimIn)return nullptr;
            for(size_t j=0;j<c.tempoHistory.size();++j) {
                const auto& s=c.tempoHistory[j];const auto& t=s.tempo;
                const double end=j+1<c.tempoHistory.size()?c.tempoHistory[j+1].frame:c.mapFrame;
                const double source=j+1<c.tempoHistory.size()?c.tempoHistory[j+1].source:c.mapSource;
                if(!std::isfinite(s.frame) || !std::isfinite(s.source) || s.frame<c.start || end<=s.frame || s.source<c.trimIn || source>=c.trimOut)return nullptr;
                if(t.preserve && (t.overlapPolicy!=TempoOverlapPolicy::IndependentConstant || t.curve>1 || !std::isfinite(t.first) || !std::isfinite(t.end) || t.first<0 || t.end<=t.first || t.end>(uint64_t{1}<<52) || !std::isfinite(t.sourceBpm) || !std::isfinite(t.startBpm) || !std::isfinite(t.endBpm) || t.sourceBpm<10 || t.sourceBpm>600 || t.startBpm<10 || t.startBpm>600 || t.endBpm<10 || t.endBpm>600 || t.startBpm/t.sourceBpm<.8 || t.startBpm/t.sourceBpm>1.5 || t.endBpm/t.sourceBpm<.8 || t.endBpm/t.sourceBpm>1.5))return nullptr;
                const double mapped=s.source+(t.preserve?(tempoIntegral(t,end)-tempoIntegral(t,s.frame))/t.sourceBpm:end-s.frame)*c.sourceRate/outputRate;
                if(!std::isfinite(mapped) || std::abs(mapped-source)>1e-6)return nullptr;
            }
        }
        if(c.tempo.preserve) {
            result->hasPreservedTempo=true;
            if(c.start>=(uint64_t{1}<<52) || !validExtent(c.sourceFrames,c.sourceRate,c.instance) || c.sourceRate<8000 || c.sourceRate>192000)return nullptr;
            const auto& t=c.tempo;
            if((t.overlapPolicy!=TempoOverlapPolicy::StrictSharedPhase && t.overlapPolicy!=TempoOverlapPolicy::IndependentConstant &&
                t.overlapPolicy!=TempoOverlapPolicy::SharedSourceBounds) ||
               (t.overlapPolicy==TempoOverlapPolicy::IndependentConstant && c.mapFrame<0 && t.startBpm!=t.endBpm))return nullptr;
            if(t.curve>1 || !std::isfinite(t.first) || !std::isfinite(t.end) || t.first<0 || t.end<=t.first || t.end>(uint64_t{1}<<52) ||
               !std::isfinite(t.sourceBpm) || !std::isfinite(t.startBpm) || !std::isfinite(t.endBpm) ||
               t.sourceBpm<10 || t.sourceBpm>600 || t.startBpm<10 || t.startBpm>600 || t.endBpm<10 || t.endBpm>600 ||
               t.startBpm/t.sourceBpm<.8 || t.startBpm/t.sourceBpm>1.5 || t.endBpm/t.sourceBpm<.8 || t.endBpm/t.sourceBpm>1.5 ||
               !std::isfinite(t.sourceAnchor) || t.sourceAnchor<0 || t.sourceAnchor>=c.sourceFrames ||
               !std::isfinite(c.trimIn) || !std::isfinite(c.trimOut) || c.trimOut<=c.trimIn || c.trimIn<0 || !c.sourceRate)return nullptr;
            // First discrete output point at/after original selected EOF. Binary
            // inversion avoids unstable quadratic roots and supports both curves.
            uint64_t lo=c.start, hi=(uint64_t{1}<<52);
            if(sourceAt(c,static_cast<double>(hi),outputRate)<c.trimOut)return nullptr;
            while(hi-lo>1){const auto mid=lo+(hi-lo)/2;if(sourceAt(c,static_cast<double>(mid),outputRate)>=c.trimOut)hi=mid;else lo=mid;}
            c.end=hi;
        }
        if(!c.instance || !ids.insert(c.instance).second || c.slot>=4 || c.end<=c.start ||
           c.end>(uint64_t{1}<<52) || !validExtent(c.sourceFrames,c.sourceRate,c.instance) ||
           !std::isfinite(c.trimIn) || !std::isfinite(c.trimOut) || c.trimIn<0 || c.trimOut<=c.trimIn ||
           c.trimOut>c.sourceFrames || !std::isfinite(c.gain) || c.gain<0 || c.gain>1 ||
           c.fadeIn>c.end-c.start || c.fadeOut>c.end-c.start-c.fadeIn) return nullptr;
        // The final rendered point must be inside the exact selected source extent.
        if(sourceAt(c,static_cast<double>(c.end-1),outputRate)>=c.trimOut) return nullptr;
        events.push_back({c.start,true,i}); events.push_back({c.end,false,i});
        result->duration=std::max(result->duration,c.end);
    }
    for(size_t i=0;i<result->clips.size();++i)for(size_t j=0;j<i;++j) {
        const auto& a=result->clips[i];const auto& b=result->clips[j];
        if(!a.tempo.preserve || !b.tempo.preserve || a.end<=b.start || b.end<=a.start)continue;
        const auto& x=a.tempo;const auto& y=b.tempo;
        // No overlap can silently downgrade another member's pulse contract.
        if(x.overlapPolicy!=y.overlapPolicy)return nullptr;
        if(x.overlapPolicy==TempoOverlapPolicy::IndependentConstant)continue;
        if(x.first!=y.first || x.end!=y.end || x.curve!=y.curve || x.startBpm!=y.startBpm || x.endBpm!=y.endBpm)return nullptr;
        if(x.overlapPolicy==TempoOverlapPolicy::SharedSourceBounds)continue;
        const auto at=std::max(a.start,b.start);
        const double phase=(sourceAt(a,at,outputRate)-x.sourceAnchor)/a.sourceRate*x.sourceBpm/60.-(sourceAt(b,at,outputRate)-y.sourceAnchor)/b.sourceRate*y.sourceBpm/60.;
        if(std::abs(std::remainder(phase,1.))>1e-7)return nullptr;
    }
    std::sort(events.begin(),events.end(),[](const Event&a,const Event&b){return a.frame!=b.frame?a.frame<b.frame:a.start<b.start;});
    // Bound event work in any 256-frame callback block, independent of depth.
    for(size_t i=0,j=0;i<events.size();++i) {while(events[i].frame-events[j].frame>=256)++j; if(i-j>=64)return nullptr;}
    std::array<int32_t,4> active{{-1,-1,-1,-1}}; std::array<unsigned,4> bank{};
    uint64_t previous=0;
    for(size_t at=0;at<events.size();) {
        const auto frame=events[at].frame;
        if(frame>previous) result->spans.push_back({previous,frame,active});
        while(at<events.size() && events[at].frame==frame) {
            const auto e=events[at++]; auto& c=result->clips[e.clip];
            if(e.start) {
                // Caller slot is a hint only. Color all occurrence intervals here.
                auto it=std::find(active.begin(),active.end(),-1); if(it==active.end())return nullptr;
                c.slot=static_cast<uint32_t>(it-active.begin()); *it=e.clip;
                result->banks[e.clip]=bank[c.slot]++%2;
            } else {
                auto it=std::find(active.begin(),active.end(),static_cast<int32_t>(e.clip));
                if(it==active.end())return nullptr; *it=-1;
            }
        }
        previous=frame;
    }
    return result;
}
bool Engine::installSchedule(uint64_t sequence,const Schedule* schedule,uint64_t frame) noexcept {
    auto& p=*impl_;
    if(!sequence || sequence<=p.admittedSequence || (schedule && (schedule->outputRate!=p.outputRate || frame>schedule->duration)))return p.reject();
    Envelope e; e.kind=EnvelopeKind::ScheduleInstall; e.command.sequence=sequence; e.schedule=schedule; e.frame=frame;
    if(!p.enqueue(e,p.producerDecks[0]))return false;
    p.producerSchedule=schedule;p.producerGesture=p.producerInstance=0;p.cancelledGesture=p.cancelledInstance=p.cancelledEvent=0; return true;
}
bool Engine::crossfade(uint64_t sequence,uint32_t out,uint64_t og,uint32_t in,uint64_t ig,uint64_t frames) noexcept {
    auto& p=*impl_;
    if(p.producerSchedule || out>=4 || in>=4 || out==in || !og || !ig ||
        p.producerDecks[out].generation!=og || p.producerDecks[in].generation!=ig ||
        !sequence || sequence<=p.admittedSequence || frames>uint64_t{p.outputRate}*12)return p.reject();
    Envelope e;e.kind=EnvelopeKind::Crossfade;e.command.deck=out;e.command.generation=og;
    e.command.gesture=ig;e.command.sequence=sequence;e.clip=in;e.frame=frames;
    return p.enqueue(e,p.producerDecks[out]);
}
bool Engine::settleTempo(uint64_t tag) noexcept {
    Snapshot snap;if(tag!=impl_->producerTempoTag || !snapshot(snap) || snap.tempoTerminal<tag)return false;
    if(impl_->completedStructural.load(std::memory_order_acquire)<impl_->producerTempoSequence)return false;
    impl_->producerSchedule=snap.tempoApplied==tag?impl_->producerTempoGraph:impl_->producerSchedule;return true;
}
bool Engine::tempoIntent(uint64_t revision,uint64_t tag) noexcept {
    auto& p=*impl_;
    if(!p.producerSchedule || p.producerSchedule->revision!=revision || !tag || tag<=p.latestTempo.load())return p.reject();
    p.latestTempo.store(tag,std::memory_order_release);return true;
}
bool Engine::acknowledgeTempo(uint64_t sequence,uint64_t revision,uint64_t instance,uint64_t tag,double sourceBpm,double targetBpm) noexcept {
    auto& p=*impl_;
    if(!p.producerSchedule || p.producerSchedule->revision!=revision || !instance || !tag || tag!=p.latestTempo.load() || !sequence || sequence<=p.admittedSequence || !std::isfinite(sourceBpm) || sourceBpm<=0 || !std::isfinite(targetBpm))return p.reject();
    Envelope e;e.kind=EnvelopeKind::TempoUnchanged;e.command.sequence=sequence;e.command.generation=revision;
    e.command.source.identity=instance;e.command.value=targetBpm/sourceBpm;e.tempoTag=tag;e.sync.incomingBpm=sourceBpm;
    return p.enqueue(e,p.producerDecks[0]);
}
bool Engine::handoffTempo(uint64_t sequence,const Schedule* graph,uint64_t tag,uint64_t boundary,uint32_t mask,const std::array<PcmWindow,4>& windows) noexcept {
    auto& p=*impl_;const auto* old=p.producerSchedule;
    if(!old || !graph || !tag || !mask || mask>15 || !sequence || sequence<=p.admittedSequence || graph->revision!=old->revision || graph->outputRate!=p.outputRate || graph->clips.size()!=old->clips.size())return p.reject();
    Snapshot snap;if(!snapshot(snap) || boundary<=snap.globalFrame || boundary>=graph->duration)return p.reject();
    const auto latest=p.latestTempo.load();if(tag<latest)return p.reject();
    // Exactly one borrowed descriptor may be outstanding. A newer intent can
    // invalidate it, but its storage still waits for the callback terminal ACK.
    if(p.producerTempoTag && snap.tempoTerminal<p.producerTempoTag)return p.reject();
    uint32_t seen=0;
    for(size_t i=0;i<graph->clips.size();++i){
        const auto& a=old->clips[i];const auto& b=graph->clips[i];
        if(a.instance!=b.instance || a.slot!=b.slot || old->banks[i]!=graph->banks[i] || a.start!=b.start || a.trimIn!=b.trimIn || a.trimOut!=b.trimOut || a.fadeIn!=b.fadeIn || a.fadeOut!=b.fadeOut || a.gain!=b.gain || a.sourceRate!=b.sourceRate || a.sourceFrames!=b.sourceFrames)return p.reject();
        if((mask&(1U<<a.slot)) && boundary>=a.start && boundary<a.end){
            if(seen&(1U<<a.slot))return p.reject();seen|=1U<<a.slot;
            if(snap.decks[a.slot].scratching || snap.decks[a.slot].syncState || !b.tempo.preserve || boundary<a.start || boundary>=a.end || boundary>=b.end || std::abs(sourceAt(a,boundary,p.outputRate)-sourceAt(b,boundary,p.outputRate))>1e-6 || !validWindow(windows[b.slot],preparedExtent(b,p.outputRate)))return p.reject();
            const auto first=static_cast<uint64_t>(preparedAt(b,boundary,p.outputRate));
            const auto last=std::min(preparedExtent(b,p.outputRate)-1,first+static_cast<uint64_t>(std::ceil(257.*b.sourceRate/p.outputRate)));
            auto has=[&](uint64_t n){for(unsigned j=0;j<windows[b.slot].count;++j){const auto& w=windows[b.slot].pages[j];if(n>=w.firstFrame && n-w.firstFrame<w.frames)return true;}return false;};
            if(!has(first)||!has(last))return p.reject();
        }else{
            const auto& x=a.tempo;const auto& y=b.tempo;
            if(a.end!=b.end || a.mapFrame!=b.mapFrame || a.mapSource!=b.mapSource || !sameHistory(a,b) || x.preserve!=y.preserve || x.curve!=y.curve || x.sourceBpm!=y.sourceBpm || x.startBpm!=y.startBpm || x.endBpm!=y.endBpm || x.first!=y.first || x.end!=y.end || x.sourceAnchor!=y.sourceAnchor || x.overlapPolicy!=y.overlapPolicy)return p.reject();
        }
    }
    if(seen!=mask)return p.reject();
    Envelope e;e.kind=EnvelopeKind::TempoHandoff;e.command.sequence=sequence;e.schedule=graph;e.frame=boundary;e.tempoTag=tag;e.changedMask=mask;e.tempoWindows=windows;
    if(!p.enqueue(e,p.producerDecks[0]))return false;
    p.latestTempo.store(tag,std::memory_order_release);p.producerTempoTag=tag;p.producerTempoGraph=graph;p.producerTempoSequence=sequence;return true;
}
bool Engine::bindSchedule(uint64_t sequence,uint64_t revision,uint64_t instance,const PcmWindow& window) noexcept {
    auto& p=*impl_; const auto* s=p.producerSchedule;
    if(!s || revision!=s->revision || !sequence || sequence<=p.admittedSequence)return p.reject();
    auto it=std::find_if(s->clips.begin(),s->clips.end(),[instance](const ScheduleClip& c){return c.instance==instance;});
    if(it==s->clips.end() || !validWindow(window,it->tempo.preserve?preparedExtent(*it,s->outputRate):it->sourceFrames))return p.reject();
    Envelope e; e.kind=EnvelopeKind::ScheduleBind; e.command.sequence=sequence; e.command.generation=revision;
    e.clip=static_cast<uint32_t>(it-s->clips.begin()); e.window=window;
    return p.enqueue(e,p.producerDecks[0]);
}
bool Engine::scheduleTransport(uint64_t sequence,uint64_t revision,uint32_t op,uint64_t frame) noexcept {
    auto& p=*impl_; const auto* s=p.producerSchedule;
    if(!s || revision!=s->revision || !sequence || sequence<=p.admittedSequence || (op<1 || (op>3 && op!=7)) || (op!=7 && frame>s->duration) || (op==7 && frame>1000000))return p.reject();
    Envelope e; e.kind=EnvelopeKind::ScheduleTransport; e.command.sequence=sequence; e.command.generation=revision;
    e.command.gesture=op; e.command.value=static_cast<double>(frame)/1000000; e.frame=frame;
    if(!p.enqueue(e,p.producerDecks[0]))return false;
    if(op==2 || op==3)p.producerGesture=p.producerInstance=0;
    return true;
}
bool Engine::scratch(uint64_t sequence,uint64_t revision,uint32_t op,uint64_t instance,uint64_t gesture,uint64_t event,double rate) noexcept {
    auto& p=*impl_;const auto* s=p.producerSchedule;
    if(!s || revision!=s->revision || !sequence || sequence<=p.admittedSequence || op<1 || op>4 || !gesture || !event || !std::isfinite(rate) || rate< -8 || rate>8)return p.reject();
    // Exact Cancel replay is an idempotent ACK, not a new lease or callback event.
    if(op==4 && !p.producerGesture && gesture==p.cancelledGesture && instance==p.cancelledInstance && event==p.cancelledEvent)return true;
    Snapshot snap;if(!snapshot(snap) || snap.scheduleRevision!=revision)return p.reject();
    if(p.producerGesture && p.completedStructural.load(std::memory_order_acquire)>=p.producerBeginSequence) {
        const auto previous=std::find_if(snap.decks.begin(),snap.decks.end(),[&](const DeckSnapshot& d){return d.identity==p.producerInstance && d.scratching && d.gesture==p.producerGesture;});
        if(previous==snap.decks.end())p.producerGesture=p.producerInstance=0;
    }
    const auto it=std::find_if(s->clips.begin(),s->clips.end(),[&](const ScheduleClip& c){return c.instance==instance;});
    if(it==s->clips.end() || it->tempo.preserve || snap.decks[it->slot].processingEpoch || (p.producerTempoTag && snap.tempoTerminal<p.producerTempoTag) || snap.globalFrame<it->start || snap.globalFrame>=it->end)return p.reject();
    const auto slot=it->slot;const auto& d=snap.decks[slot];
    if(op==1) {
        if(p.producerGesture || gesture<=p.producerLastGesture || event<=p.producerEvent || d.identity!=instance || !d.residentPages)return p.reject();
        for(const auto& peer:snap.decks)if(peer.syncReference==instance && peer.syncState!=0 && peer.syncState!=5)return p.reject();
    } else if(p.producerGesture!=gesture || p.producerInstance!=instance || event<=p.producerEvent)return p.reject();
    if(op==2) {
        std::array<uint64_t,5> old{};
        if(p.moves[slot].load(old) && old[0]==revision && old[1]==gesture && old[2]>p.consumedMoves[slot].load())p.movesCoalesced.fetch_add(1);
        p.moves[slot].store({revision,gesture,sequence,event,bits(rate)});
        p.admittedSequence=sequence;p.producerEvent=event;return true;
    }
    Envelope e;e.kind=EnvelopeKind::Scratch;e.command.sequence=sequence;e.command.generation=revision;e.command.gesture=gesture;e.command.source.identity=instance;e.eventNanos=event;
    e.command.operation=op==1?Operation::BeginScratch:op==3?Operation::EndScratch:Operation::CancelScratch;
    if(!p.enqueue(e,p.producerDecks[0]))return false;
    p.producerEvent=event;
    if(op==1){p.producerGesture=gesture;p.producerInstance=instance;p.producerLastGesture=gesture;p.producerBeginSequence=sequence;}
    else {p.producerGesture=p.producerInstance=0;}
    if(op==4){p.cancelledGesture=gesture;p.cancelledInstance=instance;p.cancelledEvent=event;}
    return true;
}
bool Engine::sync(uint64_t sequence,uint64_t revision,const LiveSync& r) noexcept {
    auto& p=*impl_;const auto* s=p.producerSchedule;
    if(!s || revision!=s->revision || !sequence || sequence<=p.admittedSequence)return p.reject();
    Snapshot snap;if(!snapshot(snap) || snap.scheduleRevision!=revision)return p.reject();
    auto find=[&](uint64_t id)->const ScheduleClip*{for(const auto& c:s->clips)if(c.instance==id && snap.globalFrame>=c.start && snap.globalFrame<c.end)return &c;return nullptr;};
    const auto* incoming=find(r.incoming);if(!incoming || incoming->tempo.preserve || snap.decks[incoming->slot].processingEpoch || (p.producerTempoTag && snap.tempoTerminal<p.producerTempoTag))return p.reject();
    if(r.beats) {
        const auto* reference=find(r.reference);
        if(!reference || reference->tempo.preserve || snap.decks[reference->slot].processingEpoch || reference==incoming || (r.beats!=1 && r.beats!=4 && r.beats!=16 && r.beats!=32))return p.reject();
        if(!std::isfinite(r.referenceBpm) || !std::isfinite(r.incomingBpm) || r.referenceBpm<10 || r.referenceBpm>600 || r.incomingBpm<10 || r.incomingBpm>600)return p.reject();
        auto timing=[&](const ScheduleClip& c,double a,double o,double bpm){
            if(!std::isfinite(a)||!std::isfinite(o)||a<0||a>=c.sourceFrames*1000./c.sourceRate)return false;
            if(r.beats==1)return true;
            if(o<0||o>=c.sourceFrames*1000./c.sourceRate)return false;
            const double offset=(o-a)*bpm/60000.;
            return std::abs(offset-std::round(offset))*60.*c.sourceRate/bpm<=1.;
        };
        if(!timing(*reference,r.referenceAnchorMs,r.referenceOriginMs,r.referenceBpm)||!timing(*incoming,r.incomingAnchorMs,r.incomingOriginMs,r.incomingBpm))return p.reject();
        const auto& rd=snap.decks[reference->slot];const auto& id=snap.decks[incoming->slot];
        if(rd.identity!=r.reference || id.identity!=r.incoming || rd.scratching || id.scratching || !rd.residentPages || !id.residentPages || rd.rate<=0)return p.reject();
        const double rate=rd.rate*r.referenceBpm/r.incomingBpm;if(rate<.25 || rate>4)return p.reject();
        // Keep one constant master law. No cycles/chains or changing a live master.
        if(rd.syncState==1 || rd.syncState==4)return p.reject();
        for(const auto& d:snap.decks)if(d.syncReference==r.incoming && d.syncState!=0 && d.syncState!=5)return p.reject();
    }
    Envelope e;e.kind=EnvelopeKind::Sync;e.command.sequence=sequence;e.command.generation=revision;e.sync=r;
    return p.enqueue(e,p.producerDecks[0]);
}
uint64_t Engine::completedStructuralSequence() const noexcept {
    return impl_->completedStructural.load(std::memory_order_acquire);
}
bool Engine::move(const ScratchMove& movement) noexcept {
    auto& p = *impl_;
    if (p.producerSchedule || movement.deck >= 4 || movement.sequence == 0 || movement.sequence <= p.admittedSequence ||
        !std::isfinite(movement.rate) || movement.rate < -8 || movement.rate > 8) return p.reject();
    auto& d = p.producerDecks[movement.deck];
    if (movement.generation != d.generation || movement.gesture == 0 || movement.gesture != d.gesture ||
        movement.sequence <= d.moveSequence) return p.reject();
    p.moves[movement.deck].store({movement.generation, movement.gesture, movement.sequence,
                                 movement.eventNanos, bits(movement.rate)});
    d.moveSequence = movement.sequence; p.admittedSequence = movement.sequence;
    return true;
}

void Engine::render(float* output, uint32_t frames) noexcept {
    renderAt(output,frames,static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now().time_since_epoch()).count()));
}
void Engine::renderAt(float* output, uint32_t frames,uint64_t now) noexcept {
    auto& p = *impl_;
    p.callbackNanos=now;
    auto tail = p.tail.load(std::memory_order_relaxed);
    const auto end = p.head.load(std::memory_order_acquire);
#ifdef SOUNDQ_TRANSPORT_TEST_BARRIERS
    test::barrier(1); // Capture head independently from newer mailbox moves.
#endif
    while (tail != end) { p.apply(p.queue[tail % queueCapacity]); ++tail; }
    p.tail.store(tail, std::memory_order_release);
    p.applyMoves();
    if(p.hasPendingTempo && p.pendingTempo.tempoTag!=p.latestTempo.load(std::memory_order_acquire)){p.tempoTerminal=std::max(p.tempoTerminal,p.pendingTempo.tempoTag);p.hasPendingTempo=false;}
    const bool prepared=p.preparedBlock(frames);p.scheduleBuffering=!prepared;
    for (uint32_t frame = 0; frame < frames; ++frame) {
        double left = 0; double right = 0;
        const bool boundaryReady=p.schedule || p.boundarySample();
        const bool advanceBoundary=!p.schedule && boundaryReady && p.boundaryCurrent() && p.boundary.begun && p.decks[p.boundary.out].playing && p.boundary.elapsed<p.boundary.length;
        if (p.schedule) {if(prepared)p.scheduleSample(left,right,p.renderedFrames+frame);}
        else for (auto& d : p.decks) {
            d.rate.advance(); d.gain.advance();
            if (!d.playing || d.rate.value == 0 || (!boundaryReady && p.boundaryCurrent() && (&d==&p.decks[p.boundary.out] || &d==&p.decks[p.boundary.in]))) continue;
            double position = d.cursor;
            if (position >= static_cast<double>(d.source.frames)) {
                if (d.rate.value >= 0) {
                    if (!d.scratching) {
                        if (!d.atEnd) { ++d.eofCount; d.atEnd = true; }
                        d.playing = false;
                    }
                    continue;
                }
                position = static_cast<double>(d.source.frames - 1);
            }
            if (position == 0 && d.rate.value < 0) continue;
            const auto index = static_cast<uint64_t>(position);
            const auto next = std::min(index + 1, d.source.frames - 1);
            const auto fraction = position - static_cast<double>(index);
            const auto level = d.gain.value * std::min(1.0, std::abs(d.rate.value)) * p.boundaryGain(static_cast<uint32_t>(&d-p.decks.data()));
            const auto* firstTap = d.tap(index);
            const auto* nextTap = d.tap(next);
            if (!firstTap || !nextTap) { ++d.missingPcmFrames; continue; }
            left += level * (firstTap[0] * (1 - fraction) + nextTap[0] * fraction);
            right += level * (firstTap[1] * (1 - fraction) + nextTap[1] * fraction);
            d.cursor = position + d.rate.value * d.source.sourceRate / p.outputRate;
            if (d.cursor >= static_cast<double>(d.source.frames)) {
                d.cursor = static_cast<double>(d.source.frames);
                // Both resident taps were consumed from before true decoded EOF.
                // Do not reuse generic EOF: it also marks sought endpoints and
                // scratch crossings. Capture this source, never overlap dominance.
                if (!d.atEnd && !d.scratching && d.rate.value > 0) {
                    ++d.naturalEndCount;
                    d.naturalEndGeneration = d.generation;
                    d.naturalEndIdentity = d.source.identity;
                    d.naturalEndTraversalRevision = d.traversalRevision;
                }
                if (!d.atEnd) { ++d.eofCount; d.atEnd = true; }
                if (!d.scratching) d.playing = false;
            } else {
                d.cursor = std::max(0.0, d.cursor); d.atEnd = false;
            }
        }
        if(advanceBoundary)++p.boundary.elapsed;
        if(p.schedule && p.schedule->hasPreservedTempo) {
            left=std::isfinite(left)?std::clamp(left,-1.,1.):0;
            right=std::isfinite(right)?std::clamp(right,-1.,1.):0;
        }
        if (output) {
            const auto offset = static_cast<std::size_t>(frame) * 2;
            output[offset] = static_cast<float>(left); output[offset + 1] = static_cast<float>(right);
        }
    }
#ifdef SOUNDQ_TRANSPORT_TEST_BARRIERS
    test::barrier(2); // All PCM reads finished, receipt not yet published.
#endif
    p.renderedFrames += frames;
    p.publish();
    // FIFO capacity release is not PCM retirement. Complete only after every
    // sample read from this block, and never copy the mixed move-lane maximum.
    p.completedStructural.store(p.consumedStructuralSequence, std::memory_order_release);
}

bool Engine::snapshot(Snapshot& destination) const noexcept {
    std::array<uint64_t, snapshotWords> data{};
    if (!impl_->publication.load(data)) return false;
    Snapshot result;
    result.renderedFrames = data[0]; result.appliedSequence = data[1];
    result.lastGestureEventNanos = data[2]; result.lastGestureAppliedFrame = data[3];
    result.refusedCommands = data[4];
    constexpr auto at=5+4*deckWords;
    result.scheduleRevision=data[at]; result.globalFrame=data[at+1]; result.durationFrames=data[at+2];
    result.schedulePlaying=(data[at+3]&1U)!=0; result.scheduleBuffering=(data[at+3]&2U)!=0; result.scheduleEnded=data[at+4]!=0;
    result.latencyCount=data[at+5];result.movesCoalesced=data[at+6];result.syncReschedules=data[at+7];
    for(size_t i=0;i<64;++i)result.latency[i]={data[at+8+3*i],data[at+9+3*i],data[at+10+3*i]};
    for (std::size_t i = 0; i < 4; ++i) {
        auto& d = result.decks[i]; const auto at = 5 + i * deckWords;
        d.generation = data[at]; d.identity = data[at + 1]; d.boundaryGain=number(data[at+24]);
        d.sourceFrame = number(data[at + 2]); d.rate = number(data[at + 3]);
        d.playing = data[at + 4] != 0; d.scratching = data[at + 5] != 0;
        d.gesture = data[at + 6]; d.eofCount = data[at + 7];
        d.traversalRevision=data[at+25]; d.naturalEndCount=data[at+26];
        d.naturalEndGeneration=data[at+27]; d.naturalEndIdentity=data[at+28];
        d.naturalEndTraversalRevision=data[at+29];
        d.missingPcmFrames = data[at + 8]; d.residentPages = static_cast<uint32_t>(data[at + 9]);
        d.nominalSourceFrame=number(data[at+10]);d.lastMoveEventNanos=data[at+11];d.lastMoveAppliedNanos=data[at+12];d.lastMoveSequence=data[at+13];d.heldZero=data[at+14]!=0;
        d.syncReference=data[at+15];d.syncBeats=static_cast<uint32_t>(data[at+16]);d.syncState=static_cast<uint32_t>(data[at+17]);d.syncPhaseErrorFrames=number(data[at+18]);d.demandSourceFrame=number(data[at+19]);d.syncBoundaryFrame=data[at+20];d.processingEpoch=data[at+21];d.effectiveBpm=number(data[at+22]);d.tempoGeneration=data[at+23];
    }
    result.tempoApplied=data[snapshotWords-2];result.tempoTerminal=data[snapshotWords-1];
    destination = result;
    return true;
}
} // namespace soundq::transport

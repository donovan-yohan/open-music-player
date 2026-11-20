// Actual WorkerDeck + Engine; generated positioned stereo PCM, no codec/device timing.
#include "worker_deck.hpp"
#include "sq_file_decoder.h"
#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <iostream>
#include <mutex>
#include <stdexcept>
#include <thread>
#include <vector>
using namespace soundq::nativeengine;
using namespace soundq::transport;
namespace barriers {
std::atomic<bool> copyHold{false}, copyEntered{false}, joining{false};
}
namespace soundq::transport::test {
extern std::atomic<unsigned> holdStage, reachedStage;
}
namespace barriers {
auto& callbackHold=soundq::transport::test::holdStage;
auto& callbackEntered=soundq::transport::test::reachedStage;
}
namespace soundq::nativeengine::test {
void workerCopy() noexcept {
    if (!barriers::copyHold.load()) return;
    barriers::copyEntered.store(true);
    while (barriers::copyHold.load()) std::this_thread::yield();
}
void workerJoin() noexcept { barriers::joining.store(true); }
}
namespace {
constexpr uint64_t page = 48000, resumeMs = 4324079, resumeFrame = resumeMs * 44100 / 1000;
void require(bool ok, const char* message) { if (!ok) throw std::runtime_error(message); }
template<class P> void until(P predicate) {
    const auto end = std::chrono::steady_clock::now() + std::chrono::seconds(10);
    while (!predicate()) {
        require(std::chrono::steady_clock::now() < end, "positive observation deadline");
        std::this_thread::yield();
    }
}
float sample(uint64_t frame, unsigned channel, unsigned salt = 0) {
    return static_cast<float>(static_cast<int>((frame * (channel ? 7 : 1) + salt * 31) % 1009) - 504) / 2048;
}
struct Read { uint64_t first; uint32_t count; };
struct Shared {
    std::mutex mutex;
    std::condition_variable cv;
    std::vector<Read> reads;
    bool hold = false, entered = false;
    uint64_t blockedFrom = UINT64_MAX;
    std::atomic<int> error{0}, opens{0}, closes{0};
    std::atomic<bool> shortRead{false};
    std::atomic<bool> sourceRetired{false};
    std::atomic<uint64_t> end{0};
    uint64_t length = 44100ULL * 10000;
    bool known = false, lateEnd = false;
    unsigned salt = 0;
    void arm() { std::lock_guard<std::mutex> lock(mutex); hold = true; entered = false; }
    void release() { { std::lock_guard<std::mutex> lock(mutex); hold = false; blockedFrom = UINT64_MAX; } cv.notify_all(); }
    void blockFrom(uint64_t first) { { std::lock_guard<std::mutex> lock(mutex); blockedFrom = first; } cv.notify_all(); }
    bool requested(uint64_t first) {
        std::lock_guard<std::mutex> lock(mutex);
        return std::any_of(reads.begin(),reads.end(),[&](const Read& read){return read.first==first;});
    }
    size_t count() { std::lock_guard<std::mutex> lock(mutex); return reads.size(); }
    void waitRead() { std::unique_lock<std::mutex> lock(mutex); require(cv.wait_for(lock, std::chrono::seconds(5), [&]{return entered;}), "actual read entered"); }
};
struct Reader final : PcmReader {
    std::shared_ptr<Shared> s;
    explicit Reader(std::shared_ptr<Shared> state):s(std::move(state)) { ++s->opens; }
    ~Reader() override { ++s->closes; }
    uint32_t sampleRate() const override { return 44100; }
    uint64_t endFrames() const override { return s->known ? s->length : s->end.load(); }
    int read(uint64_t first, uint32_t count, float* out, size_t bytes, uint32_t& n) override {
        require(bytes >= size_t{count} * 8, "read byte budget");
        { std::unique_lock<std::mutex> lock(s->mutex);
          s->reads.push_back({first,count});
          // Exact full-page EOS may be learned only by the following read.
          // Hold that discovery, not an earlier overlap read on a full refill.
          if (!s->lateEnd || first >= s->length) {
              s->entered = true; s->cv.notify_all();
              s->cv.wait(lock,[&]{return !s->hold && first<s->blockedFrom;});
          } }
        if (s->sourceRetired.load()) throw std::runtime_error("source retired at reader return fence");
        if (s->error.load()) return s->error.load();
        if (endFrames() && first >= endFrames()) return SQ_FILE_INVALID_ARGUMENT;
        n = first >= s->length ? 0 : static_cast<uint32_t>(std::min<uint64_t>(count, s->length-first));
        if (s->shortRead.load() && n) --n;
        for (uint32_t i=0;i<n;++i) for (unsigned c=0;c<2;++c) out[2*i+c]=sample(first+i,c,s->salt);
        if (s->lateEnd ? first >= s->length : first+n >= s->length) s->end.store(s->length);
        return SQ_FILE_OK; // facade return fence; real original validation is not mocked as a claim
    }
};
struct Fixture {
    Engine engine{48000};
    uint64_t sequence=0;
    Snapshot snap{};
    std::shared_ptr<Shared> s = std::make_shared<Shared>();
    std::unique_ptr<WorkerDeck> worker = std::make_unique<WorkerDeck>(0,engine,sequence);
    ~Fixture() {
        s->release();barriers::copyHold.store(false);barriers::callbackHold.store(0);
        if(worker) { require(worker->retire(),"cleanup retire"); engine.render(nullptr,0); worker.reset(); }
    }
    std::shared_ptr<const PcmReaderFactory> factory(std::shared_ptr<Shared> state) {
        return std::make_shared<const PcmReaderFactory>([state]{return std::make_unique<Reader>(state);});
    }
    void snapshot() { require(engine.snapshot(snap),"snapshot"); }
    void step() { engine.render(nullptr,0); snapshot(); worker->pump(snap); }
    void prime(bool known=false, uint64_t ms=resumeMs) {
        s->known=known;
        require(worker->replaceReader(factory(s),7,1,ms),"replaceReader");
        until([&]{step();require(!worker->stats().error,"prime error");return worker->ready(snap);});
        require(worker->stats().poolBytes==8*page*8 && worker->stats().openDecoders==1,"fixed pool and one decoder");
    }
    void command(Operation op, double value=0) {
        Command c{};c.operation=op;c.deck=0;c.sequence=++sequence;c.generation=worker->generation();c.value=value;
        require(engine.submit(c),"command admitted");engine.render(nullptr,0);snapshot();
    }
    void renderExact(uint32_t n) {
        snapshot(); double position=snap.decks[0].sourceFrame;
        const auto traversal=snap.decks[0].traversalRevision, missing=snap.decks[0].missingPcmFrames;
        const auto generation=snap.decks[0].generation, identity=snap.decks[0].identity;
        const auto end=worker->sourceFrames();
        std::vector<float> out(size_t{n}*2);engine.render(out.data(),n);snapshot();
        for (uint32_t i=0;i<n;++i) {
            const bool playing=!end || position<end;
            const auto index=static_cast<uint64_t>(position), next=end?std::min(index+1,end-1):index+1;
            const double fraction=position-index;
            for (unsigned c=0;c<2;++c) {
                const float expected=playing?static_cast<float>(sample(index,c,s->salt)*(1-fraction)+sample(next,c,s->salt)*fraction):0;
                require(out[2*i+c]==expected,"exact source-position stereo samples");
            }
            if(playing) position=end?std::min<double>(end,position+44100.0/48000):position+44100.0/48000;
        }
        require(snap.decks[0].sourceFrame==position,"exact cursor advancement");
        require(snap.decks[0].traversalRevision==traversal && snap.decks[0].generation==generation && snap.decks[0].identity==identity,"same assignment and traversal");
        require(snap.decks[0].missingPcmFrames==missing,"zero new missing PCM");
    }
    void crossBoundary() {
        const auto next=(static_cast<uint64_t>(snap.decks[0].sourceFrame)/page+1)*page;
        while(snap.decks[0].sourceFrame<next)renderExact(256);
    }
    void publish(uint64_t previous) {
        until([&]{worker->pump(snap); require(!worker->stats().error,"refill error");return worker->stats().publishedWindows>previous;});
    }
    void ack() {engine.render(nullptr,0);snapshot();worker->pump(snap);}
    void holdCopy() {
        barriers::copyEntered.store(false);barriers::copyHold.store(true);
        crossBoundary();worker->pump(snap);
        until([]{return barriers::copyEntered.load();});
    }
};
void healthy(bool known) {
    Fixture f;f.prime(known);require(f.snap.decks[0].sourceFrame==resumeFrame,"exact deep resume");
    f.command(Operation::Play);
    bool bounded=true;
    for(unsigned slide=0;slide<5;++slide) {
        const auto published=f.worker->stats().publishedWindows, calls=f.worker->stats().decodeCalls;
        const auto before=f.s->count();
        f.s->arm();f.crossBoundary();f.worker->pump(f.snap);f.s->waitRead();
        require(f.worker->ready(f.snap),"old covered window ready during held read");f.renderExact(512);
        f.s->release();f.publish(published);
        require(f.worker->ready(f.snap),"old covered window ready before ACK");
        const auto receipt=f.sequence;
        for(unsigned i=0;i<32;++i)f.worker->pump(f.snap);
        require(f.sequence==receipt,"no second fill/publication before ACK");
        const auto delta=f.worker->stats().decodeCalls-calls;
        std::cout<<"REFILL known="<<known<<" slide="<<slide<<" new_page_reads="<<delta<<" expected=1\n";
        bounded=bounded && delta==1;
        {std::lock_guard<std::mutex> lock(f.s->mutex);
         if(delta==1)require(f.s->reads[before].first==f.s->reads[before-1].first+f.s->reads[before-1].count &&
             f.s->reads[before].count==page,"exact single new page extends prior decoder cursor sequentially");}
        f.ack();f.renderExact(1024);require(f.worker->ready(f.snap),"new acknowledged window ready");
    }
    require(bounded,"ordinary forward refill must decode ONE new page, not FOUR overlapping pages");
}
void cancellation(const std::string& mode) {
    Fixture f;f.prime();f.command(Operation::Play);
    const auto published=f.worker->stats().publishedWindows, recycled=f.worker->stats().recycledPages;
    const auto reads=f.s->count();
    const bool copy=mode.find("copy_")==0;
    if(copy)f.holdCopy();
    else {f.s->arm();f.crossBoundary();f.worker->pump(f.snap);f.s->waitRead();}
    // Actual worker read is held, not merely an unpolled status value.
    require(f.worker->stats().fillsInFlight==1,"one concrete in-flight job");
    if(mode.find("replace")!=std::string::npos) {
        auto next=std::make_shared<Shared>();next->salt=9;
        const uint64_t nextIdentity=mode=="copy_replace_same"?7:8;
        require(f.worker->replaceReader(f.factory(next),nextIdentity,2,resumeMs),"replacement while worker borrowed old bank");
        f.ack(); // unassign postblock ACK, but old worker still owns its copy sources
        for(unsigned i=0;i<64;++i)f.worker->pump(f.snap);
        require(next->opens.load()==0 && f.s->opens.load()==1,"no replacement writer before actual worker reply");
        require(f.worker->stats().recycledPages==recycled,"callback ACK alone must not recycle copy source bank");
        barriers::copyHold.store(false);f.s->release();
        auto old=f.s;f.s=next;
        until([&]{f.step();return f.worker->ready(f.snap);});
        require(old->closes.load()==1 && next->opens.load()==1,"old reader closes before fresh reader opens");
        require(f.snap.decks[0].identity==nextIdentity && f.snap.decks[0].generation==2,"fresh assignment only, even with same source identity");
        require(f.worker->stats().publishedWindows==published+1,"stale reply never publishes");
        f.command(Operation::Play);f.renderExact(2048);
    } else if(mode.find("retire")!=std::string::npos || mode=="copy_close") {
        require(f.worker->retire() && f.worker->retire(),"repeated retirement while worker borrowed old bank");
        f.ack();require(f.worker->retired(),"callback retirement ACK");
        require(f.worker->stats().recycledPages==recycled,"retirement ACK is not worker closure");
        if(mode=="copy_close") {
            barriers::joining.store(false);std::atomic<bool> closed{false};
            std::thread close([&]{f.worker.reset();closed.store(true);});
            // No control method runs concurrently with destruction.
            try {until([]{return barriers::joining.load();});}
            catch(...) {barriers::copyHold.store(false);f.s->release();close.join();throw;}
            const bool premature=closed.load();
            barriers::copyHold.store(false);f.s->release();close.join();
            require(!premature && closed.load() && f.s->closes.load()==1,"actual close joins borrowed copy before free");
        } else {
            barriers::copyHold.store(false);f.s->release();
            until([&]{f.worker->pump(f.snap);return f.worker->stats().recycledPages>recycled;});
            require(f.worker->stats().publishedWindows==published && f.s->count()==reads+(copy?0:1),"retired stale work never publishes or decodes another page");
        }
    } else if(mode=="copy_seek") {
        f.worker->fenceSeek();f.command(Operation::Seek,static_cast<double>(resumeFrame-page*6));
        require(!f.worker->ready(f.snap),"uncovered seek refuses readiness");
        barriers::copyHold.store(false);f.s->release();
        f.publish(published);f.ack();f.renderExact(1024);
        require(f.worker->stats().publishedWindows==published+1,"cancelled copy cannot publish old seek target");
    } else if(mode=="copy_speed") {
        require(f.worker->setSpeed(1.25),"speed cancels borrowed copy");
        barriers::copyHold.store(false);f.s->release();
        f.publish(published);f.ack();
        require(f.worker->appliedSpeed()==1.25,"only current speed publishes");
        const auto direct=f.worker->stats().decodeCalls, pubs=f.worker->stats().publishedWindows;
        require(f.worker->setSpeed(1),"restore original PCM speed");f.publish(pubs);f.ack();
        require(f.worker->stats().decodeCalls-direct==4,"processed speed bank is NOT ordinary PCM reuse");
        f.renderExact(2048);
    } else throw std::runtime_error("unknown cancellation control");
}
void callbackAck(unsigned stage) {
    Fixture f;f.prime();f.command(Operation::Play);
    const auto published=f.worker->stats().publishedWindows, recycled=f.worker->stats().recycledPages;
    f.s->arm();f.crossBoundary();f.worker->pump(f.snap);f.s->waitRead();f.s->release();f.publish(published);
    const auto receipt=f.sequence;
    barriers::callbackEntered.store(0);barriers::callbackHold.store(stage);
    float out[2]{};std::thread callback([&]{f.engine.render(out,1);});
    try {
        until([&]{return barriers::callbackEntered.load()==stage;});
        for(unsigned i=0;i<64;++i)f.worker->pump(f.snap);
        require(f.engine.completedStructuralSequence()<receipt,"actual postblock receipt still held");
        require(f.worker->stats().recycledPages==recycled && f.sequence==receipt,"no recycling or next writer before structural ACK");
        require(f.worker->ready(f.snap),"covered predecessor ready through actual callback hold");
    } catch(...) {barriers::callbackHold.store(0);callback.join();throw;}
    barriers::callbackHold.store(0);callback.join();f.snapshot();
    require(f.worker->ready(f.snap),"acknowledged replacement readiness without extra pump");
    f.worker->pump(f.snap);require(f.worker->stats().recycledPages==recycled+4,"old bank releases exactly after postblock ACK");
    f.renderExact(2048);
}
void twoNewPages(bool known) {
    Fixture f;f.prime(known);f.command(Operation::Play);
    const auto pubs=f.worker->stats().publishedWindows, calls=f.worker->stats().decodeCalls;
    const auto before=f.s->count();
    f.crossBoundary();f.crossBoundary(); // no maintenance: two source pages advanced
    f.worker->pump(f.snap);f.publish(pubs);f.ack();
    if(!known) {
        require(f.worker->stats().publishedWindows==pubs+1,"first catch-up page published separately");
        f.publish(pubs+1);f.ack();
    }
    require(f.worker->stats().decodeCalls-calls==2,"two-page forward slide decodes exactly two missing pages");
    {std::lock_guard<std::mutex> lock(f.s->mutex);
     require(f.s->reads[before].first==f.s->reads[before-1].first+page &&
         f.s->reads[before+1].first==f.s->reads[before].first+page,"multiple missing pages decode in ascending sequential source order");}
    f.renderExact(2048);
}
void tightCatchup() {
    Fixture f;f.prime();f.command(Operation::Play);
    const auto initialEnd=(resumeFrame/page+4)*page;
    const auto initialPublication=f.worker->stats().publishedWindows;
    const auto traversal=f.snap.decks[0].traversalRevision;
    const auto missing=f.snap.decks[0].missingPcmFrames;
    f.s->blockFrom(initialEnd);
    f.crossBoundary();f.worker->pump(f.snap);
    until([&]{return f.s->requested(initialEnd);});
    // One late refill, admitted normally on a page crossing. Let its predecessor
    // cover playback until the exact last available interpolation pair is spent.
    while(f.snap.decks[0].sourceFrame+256<initialEnd-1)f.renderExact(256);
    while(f.snap.decks[0].sourceFrame<initialEnd-1)f.renderExact(1);
    require(!f.worker->ready(f.snap) && f.snap.decks[0].missingPcmFrames==missing,
        "reached the two-tap edge without spending a missing sample");
    f.s->blockFrom(initialEnd+page);f.publish(initialPublication);
    const auto catchupCalls=f.worker->stats().decodeCalls;
    f.ack();
    require(f.worker->ready(f.snap),"first late refill is ACKed and restores one page of headroom");
    // Subsequent pages each take only 3/4 of a page of consumption. Two such
    // reads cannot share a single publication deadline with one page resident.
    constexpr uint32_t perRead=static_cast<uint32_t>(page*48000*3/(44100*4));
    auto renderForRead=[&] {
        for (uint32_t done=0;done<perRead;) {
            const auto n=std::min(256U,perRead-done);f.renderExact(n);done+=n;
        }
    };
    bool previousPublished=true;
    for(unsigned i=0;i<8;++i) {
        const auto first=initialEnd+(i+1)*page;
        until([&]{return f.s->requested(first);});
        try {renderForRead();}
        catch(...) {
            std::cerr<<"CATCHUP page="<<i<<" previous_page_published="<<previousPublished
                <<" missing_delta="<<(f.snap.decks[0].missingPcmFrames-missing)
                <<" frozen_source_floor="<<static_cast<uint64_t>(f.snap.decks[0].sourceFrame)<<'\n';
            throw;
        }
        require(previousPublished && f.worker->ready(f.snap),"timely previous page covers playback while next page is held");
        const auto published=f.worker->stats().publishedWindows;
        f.s->blockFrom(first+page);
        until([&]{
            f.worker->pump(f.snap);
            return f.worker->stats().publishedWindows>published || f.s->requested(first+page);
        });
        previousPublished=f.worker->stats().publishedWindows>published;
        if(previousPublished)f.ack();
    }
    require(previousPublished && f.worker->stats().decodeCalls-catchupCalls==8 &&
        f.snap.decks[0].traversalRevision==traversal && f.snap.decks[0].playing &&
        f.snap.decks[0].missingPcmFrames==missing,"catch-up preserves continuous samples and transport");
    f.renderExact(1024);
}
void uncovered() {
    Fixture f;f.prime();f.command(Operation::Play);
    const auto initialFirst=resumeFrame/page*page, published=f.worker->stats().publishedWindows;
    f.s->arm();f.crossBoundary();f.worker->pump(f.snap);f.s->waitRead();
    // First tap exists, second is exactly outside the acknowledged old bank.
    f.command(Operation::Seek,static_cast<double>(initialFirst+4*page-1));
    require(!f.worker->ready(f.snap),"missing second tap alone refuses readiness");
    const auto missing=f.snap.decks[0].missingPcmFrames;
    const auto cursor=f.snap.decks[0].sourceFrame;
    float out[2]={1,1};f.engine.render(out,1);f.snapshot();
    require(out[0]==0 && out[1]==0 && f.snap.decks[0].missingPcmFrames==missing+1 && f.snap.decks[0].sourceFrame==cursor,"genuine missing tap emits silence, counts starvation, freezes cursor");
    require(f.snap.decks[0].playing && !f.snap.decks[0].naturalEndCount,"starvation is neither pause nor EOS");
    f.s->release();f.publish(published);require(!f.worker->ready(f.snap),"new-only pending taps cannot grant readiness");
    f.ack();require(f.worker->ready(f.snap),"actual ACK admits new second tap");f.renderExact(512);
}
void seekAwayBack(bool known) {
    Fixture f;f.prime(known);f.command(Operation::Play);
    for(const auto target:{known?resumeFrame-page*6:resumeFrame+page*6,resumeFrame}) {
        const auto calls=f.worker->stats().decodeCalls, pubs=f.worker->stats().publishedWindows;
        f.worker->fenceSeek();f.command(Operation::Seek,static_cast<double>(target));
        require(!f.worker->ready(f.snap),"distant seek not covered");
        f.publish(pubs);f.ack();require(f.worker->stats().decodeCalls-calls==4,"nonoverlap/backward seek decodes actual four pages");f.renderExact(1024);
    }
}
void endControl(bool known, bool shortTail) {
    Fixture f;
    const auto first=resumeFrame/page*page;
    f.s->length=shortTail?12345:first+4*page+137;
    f.prime(known,shortTail?0:resumeMs);f.command(Operation::Play);
    const uint64_t end=f.s->length;
    const auto range=[&] {
        const auto extent=f.worker->sourceFrames();
        const auto cursor=static_cast<uint64_t>(f.snap.decks[0].sourceFrame);
        const auto center=(extent?std::min(cursor,extent-1):cursor)/page;
        return std::make_pair(extent && center?center-1:center,
            extent?std::min((extent-1)/page,center+2):center+3);
    };
    auto previous=range();
    while(f.snap.decks[0].sourceFrame<end) {
        // Positively drain each changed neighborhood without relying on a
        // worker's scheduling latency or inventing an end from catalog duration.
        const auto target=range();
        if(target!=previous) {
            const auto pubs=f.worker->stats().publishedWindows;
            f.worker->pump(f.snap);f.publish(pubs);f.ack();previous=target;
            continue; // newly learned end may itself change the neighborhood
        }
        f.renderExact(256);
    }
    require(f.worker->sourceFrames()==end && f.snap.decks[0].sourceFrame==end,"only qualified exact end sealed and consumed");
    require(f.snap.decks[0].naturalEndCount==1 && f.snap.decks[0].eofCount==1 && !f.snap.decks[0].playing,"one actual natural end, no fabricated completion");
    f.renderExact(256);
    {std::lock_guard<std::mutex> lock(f.s->mutex);for(const auto& r:f.s->reads)require(r.first<end,"no out-of-range speculative read after qualified end");}
}
void cancelledEos(bool retired) {
    Fixture f;
    f.s->lateEnd = true;
    f.s->length = (resumeFrame/page+4)*page;
    f.prime();f.command(Operation::Play);
    require(f.s->count()==4 && !f.s->end.load() && !f.worker->sourceFrames(),
        "four full pages leave reader and control end unknown");
    const auto pubs=f.worker->stats().publishedWindows;
    f.s->arm();f.crossBoundary();f.worker->pump(f.snap);f.s->waitRead();
    {std::lock_guard<std::mutex> lock(f.s->mutex);
     require(f.s->reads.back().first==f.s->length,"held actual first past-full-page EOS discovery");}
    f.worker->fenceSeek();
    const auto cursor=f.snap.decks[0].sourceFrame;
    f.command(Operation::Seek,cursor); // actual Engine Seek within the same forward neighborhood
    require(f.snap.decks[0].sourceFrame==cursor,"same-position seek applied");
    f.s->release();until([&]{return f.worker->stats().fillsInFlight==0;});
    require(f.s->end.load()==f.s->length && !f.worker->sourceFrames(),
        "cancelled reader knows qualified EOS but control extent remains unknown");
    require(f.worker->stats().publishedWindows==pubs,"cancelled EOS reply has not published");
    f.s->sourceRetired.store(retired);
    const auto reads=f.s->count();
    until([&]{f.worker->pump(f.snap);return f.worker->stats().publishedWindows>pubs || f.worker->stats().error;});
    const auto newReads=f.s->count()-reads;
    std::cout<<"CANCELLED_EOS retired="<<retired<<" new_reads="<<newReads
        <<" new_publications="<<f.worker->stats().publishedWindows-pubs
        <<" error="<<f.worker->stats().error<<'\n';
    require(newReads>0,"cancelled EOS recovery requires a genuine fresh source-validation read");
    {std::lock_guard<std::mutex> lock(f.s->mutex);
     for(size_t i=reads;i<f.s->reads.size();++i)
         require(f.s->reads[i].first<f.s->length && f.s->reads[i].count<=f.s->length-f.s->reads[i].first,
             "recovery validation must be genuinely in-range, not an out-of-range refusal");}
    if(retired) {
        require(f.worker->stats().publishedWindows==pubs && !f.worker->sourceFrames(),
            "retired source cannot publish copied PCM or seal cancelled EOS");
        require(f.worker->stats().error==SQ_FILE_DECODE && !f.worker->ready(f.snap) && f.s->closes.load()==1,
            "current-source reader return fence fails and closes the reader");
    } else {
        require(!f.worker->stats().error && f.worker->stats().publishedWindows==pubs+1 &&
            f.worker->sourceFrames()==f.s->length,"validated healthy recovery publishes exact EOS once");
        require(f.worker->ready(f.snap),"covered old window ready before recovery ACK");
        f.ack();f.renderExact(1024);
        f.worker->fenceSeek();f.command(Operation::Seek,static_cast<double>(f.s->length-1024));
        f.renderExact(2048);
        require(f.snap.decks[0].sourceFrame==f.s->length && f.snap.decks[0].naturalEndCount==1 &&
            f.snap.decks[0].eofCount==1 && !f.snap.decks[0].playing,
            "healthy recovered PCM reaches one exact natural completion");
    }
}
void failure(bool shortRead, bool stale, bool sourceRetired=false) {
    Fixture f;f.prime();f.command(Operation::Play);
    const auto pubs=f.worker->stats().publishedWindows;
    f.s->arm();f.crossBoundary();f.worker->pump(f.snap);f.s->waitRead();
    if(sourceRetired)f.s->sourceRetired.store(true);
    else if(shortRead)f.s->shortRead.store(true);else f.s->error.store(SQ_FILE_DECODE);
    std::shared_ptr<Shared> next;
    if(stale) {next=std::make_shared<Shared>();next->salt=5;require(f.worker->replaceReader(f.factory(next),9,2,resumeMs),"replace held failing read");f.ack();}
    f.s->release();
    if(stale) {auto old=f.s;f.s=next;until([&]{f.step();return f.worker->ready(f.snap);});require(old->closes.load()==1 && !f.worker->stats().error,"stale failure cannot poison replacement");f.command(Operation::Play);f.renderExact(1024);}
    else {until([&]{f.worker->pump(f.snap);return f.worker->stats().error!=0;});require(f.worker->stats().error==SQ_FILE_DECODE && !f.worker->ready(f.snap),"real failure/short read refuses publication and readiness");require(f.worker->stats().publishedWindows==pubs && f.s->closes.load()==1,"failed partial window never publishes; reader closed");}
}
} // namespace
int main(int argc,char** argv) {
    try {
        const std::string mode=argc>1?argv[1]:"unknown";
        if(mode=="unknown")healthy(false);
        else if(mode=="known")healthy(true);
        else if(mode.find("copy_")==0 || mode.find("decode_")==0)cancellation(mode);
        else if(mode=="ack_pre")callbackAck(1);
        else if(mode=="ack_post")callbackAck(2);
        else if(mode=="forward_two")twoNewPages(false);
        else if(mode=="forward_two_known")twoNewPages(true);
        else if(mode=="tight_catchup")tightCatchup();
        else if(mode=="uncovered")uncovered();
        else if(mode=="seek")seekAwayBack(true);
        else if(mode=="seek_unknown_forward")seekAwayBack(false);
        else if(mode=="eos_known")endControl(true,false);
        else if(mode=="eos_unknown")endControl(false,false);
        else if(mode=="short_tail")endControl(false,true);
        else if(mode=="cancelled_eos")cancelledEos(false);
        else if(mode=="cancelled_eos_retired")cancelledEos(true);
        else if(mode=="failure")failure(false,false);
        else if(mode=="source_failure")failure(false,false,true);
        else if(mode=="short_read")failure(true,false);
        else if(mode=="stale_failure")failure(false,true);
        else throw std::runtime_error("unknown test mode");
        std::cout<<"PASS "<<mode<<'\n';return 0;
    } catch(const std::exception& e) {std::cerr<<"FAIL "<<e.what()<<'\n';return 1;}
}

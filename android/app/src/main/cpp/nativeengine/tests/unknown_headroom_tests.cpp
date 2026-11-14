#include "worker_deck.hpp"
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <iostream>
#include <mutex>
#include <stdexcept>
#include <thread>
#include <vector>
using namespace soundq::nativeengine;
using namespace soundq::transport;
struct Gate {std::mutex mutex;std::condition_variable changed;bool armed=false,entered=false,released=false;};
struct Generated final:PcmReader {
    std::shared_ptr<Gate> gate;
    explicit Generated(std::shared_ptr<Gate> g):gate(std::move(g)){}
    uint32_t sampleRate()const override{return 32000;}
    uint64_t endFrames()const override{return 0;}
    int read(uint64_t,uint32_t count,float* out,size_t bytes,uint32_t& n)override {
        if(bytes<size_t{count}*8)return -1;
        {std::unique_lock<std::mutex> lock(gate->mutex);if(gate->armed){gate->entered=true;gate->changed.notify_all();gate->changed.wait(lock,[&]{return gate->released;});}}
        n=count;std::fill_n(out,size_t{count}*2,.25f);return 0;
    }
};
static void require(bool ok,const char* message){if(!ok)throw std::runtime_error(message);}
struct ShortTail final:PcmReader {
    uint64_t end=0;
    uint32_t sampleRate()const override{return 32000;}
    uint64_t endFrames()const override{return end;}
    int read(uint64_t first,uint32_t count,float* out,size_t,uint32_t& n)override {
        if(end && first>=end)return -1; // qualified range is a hard decoder limit
        n=static_cast<uint32_t>(std::min<uint64_t>(count,32000-first));
        std::fill_n(out,size_t{n}*2,.25f);end=32000;return 0;
    }
};
static int shortTail() {
    Engine engine(48000);uint64_t sequence=0;Snapshot snap{};WorkerDeck worker(0,engine,sequence);int result=0;
    try {
        require(worker.replaceReader(std::make_shared<const PcmReaderFactory>([]{return std::make_unique<ShortTail>();}),9,1,0),"short source admitted");
        const auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(5);
        while(!worker.ready(snap)) {
            engine.render(nullptr,0);require(engine.snapshot(snap),"short snapshot");worker.pump(snap);
            require(worker.stats().error==0,"qualified short EOS must trim speculative forward pages without out-of-range IO");
            require(std::chrono::steady_clock::now()<deadline,"short prime ACK");std::this_thread::yield();
        }
        require(worker.sourceFrames()==32000,"only decoded end establishes source extent");
        std::cout<<"PASS qualified short EOS trims speculative forward slots without out-of-range IO\n";
    }catch(const std::exception& e){std::cerr<<"FAIL "<<e.what()<<'\n';result=1;}
    require(worker.retire(),"short retirement");engine.render(nullptr,0);require(worker.retired(),"short retirement ACK");return result;
}
int main(int argc,char**){
    if(argc>1)return shortTail();
    Engine engine(48000);uint64_t sequence=0;Snapshot snap{};auto gate=std::make_shared<Gate>();int result=0;
    WorkerDeck worker(0,engine,sequence);
    try {
        auto factory=std::make_shared<const PcmReaderFactory>([gate]{return std::make_unique<Generated>(gate);});
        require(worker.replaceReader(factory,7,1,0),"admit generated original");
        const auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(5);
        auto step=[&]{engine.render(nullptr,0);require(engine.snapshot(snap),"snapshot");worker.pump(snap);std::this_thread::yield();};
        while(!worker.ready(snap)){require(!worker.stats().error && std::chrono::steady_clock::now()<deadline,"initial actual worker ACK");step();}
        require(worker.sourceFrames()==0,"unknown extent must remain unknown");
        require(worker.stats().poolBytes==uint64_t{8}*48000*8,"existing fixed pool, no new PCM allocation");
        require(engine.submit({Operation::Play,0,++sequence,1}),"Play admission");
        std::vector<float> output(144000*2);
        // Cross the quantization boundary, not its floating-point predecessor.
        engine.render(output.data(),72000+256);require(engine.snapshot(snap),"initial played snapshot");
        require(snap.decks[0].missingPcmFrames==0,"initial samples covered");
        {std::lock_guard<std::mutex> lock(gate->mutex);gate->armed=true;}
        worker.pump(snap);
        {std::unique_lock<std::mutex> lock(gate->mutex);require(gate->changed.wait_for(lock,std::chrono::seconds(5),[&]{return gate->entered;}),"real refill read reached hold");}
        // Hold the actual producer, not its ready flag. Three source seconds of
        // callback consumption must use already acknowledged immutable pages.
        engine.render(output.data(),144000);require(engine.snapshot(snap),"held-refill snapshot");
        std::cout<<"held refill source="<<snap.decks[0].sourceFrame<<" missing="<<snap.decks[0].missingPcmFrames<<" resident="<<snap.decks[0].residentPages<<" ready="<<worker.ready(snap)<<'\n';
        require(snap.decks[0].missingPcmFrames==0,"ordinary unknown-end source exhausted before bounded refill headroom");
        constexpr double expected=(72000.0+256+144000)*32000/48000;
        require(std::abs(snap.decks[0].sourceFrame-expected)<.01 && worker.ready(snap),"actual covered cursor advances while refill held");
        for(const auto v:output)require(v==.25f,"every consumed sample must be real PCM");
        require(snap.decks[0].eofCount==0 && snap.decks[0].naturalEndCount==0,"no invented EOS");
        // Truly uncovered second tap still stalls/refuses; no OR-ready bypass.
        engine.render(output.data(),72000);require(engine.snapshot(snap),"uncovered snapshot");
        require(snap.decks[0].missingPcmFrames>0 && !worker.ready(snap),"uncovered tap must remain unready");
        require(snap.decks[0].eofCount==0 && worker.stats().error==0,"missing residency is not EOS/failure");
        {std::lock_guard<std::mutex> lock(gate->mutex);gate->released=true;}gate->changed.notify_all();
        while(!worker.ready(snap)){require(std::chrono::steady_clock::now()<deadline,"refill becomes covered only after actual publication/ACK");step();}
        require(worker.stats().openDecoders==1,"one decoder permit/lifetime");
        std::cout<<"PASS unknown-end acknowledged forward headroom, exact callback samples, uncovered refusal and post-ACK recovery\n";
    }catch(const std::exception& e){std::cerr<<"FAIL "<<e.what()<<'\n';result=1;}
    {std::lock_guard<std::mutex> lock(gate->mutex);gate->released=true;}gate->changed.notify_all();
    require(worker.retire(),"retirement");engine.render(nullptr,0);require(worker.retired(),"actual retirement ACK");
    return result;
}

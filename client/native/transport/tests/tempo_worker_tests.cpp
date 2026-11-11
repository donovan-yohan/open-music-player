// Production ScheduleWorker/Engine, fake codec boundary only.
#include "schedule_worker.hpp"
#include <chrono>
#include <iostream>
#include <stdexcept>
using namespace soundq::nativeengine;
namespace t=soundq::transport;
extern std::atomic<int> testReadError;
extern std::atomic<bool> testHoldRead,testReadEntered;
void require(bool ok,const char* what){if(!ok)throw std::runtime_error(what);}
template<class P>void until(P p){const auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(5);while(!p()){if(std::chrono::steady_clock::now()>deadline)throw std::runtime_error("worker deadline");std::this_thread::yield();}}
int main(){try{
 t::ScheduleClip c{1,0,0,320000,0,320000,32000,320000,0,0,1};
 c.tempo={true,0,120,120,100,0,320000,0};
 auto s=t::Schedule::compile(1,32000,{c});require(bool(s),"compile");
 t::Engine e(32000);uint64_t seq=0;float out[512]{};t::Snapshot snap;
 e.installSchedule(++seq,s.get(),330000);e.render(out,1);e.snapshot(snap);
 std::vector<std::string> paths{"/fake/tempo"};
 {
 ScheduleWorker w(0,*s,paths,e,seq);
 struct ReleaseRead {~ReleaseRead(){testHoldRead.store(false);testReadError.store(0);}} releaseRead;
 const auto initial=seq;
 until([&]{w.pump(snap);return seq>initial;});
 require(!w.ready(snap),"queued processed output is not readiness");
 e.render(out,1);e.snapshot(snap);require(w.ready(snap),"ACK makes processed output ready");
 e.scheduleTransport(++seq,1,1,0);e.render(out,256);e.snapshot(snap);
 require(snap.globalFrame==330256 && std::abs(out[0]-.125f)<.01,"output beyond original source extent streams");
 std::cout<<"PASS processed output beyond original source extent, initial publication/ACK\n";
 // A held obsolete output task cannot grant readiness to a new seek. The
 // acknowledged old window remains borrowed until replacement post-block ACK.
 e.scheduleTransport(++seq,1,3,40000);e.render(out,1);e.snapshot(snap);
 testReadEntered.store(false);testHoldRead.store(true);
 until([&]{w.pump(snap);return testReadEntered.load();});
 e.scheduleTransport(++seq,1,3,200000);e.render(out,1);e.snapshot(snap);
 require(!w.ready(snap),"held old seek cannot cover replacement seek");
 testHoldRead.store(false);
 until([&]{w.pump(snap);e.render(out,1);e.snapshot(snap);return w.ready(snap);});
 require(snap.globalFrame==200000,"preparation must not advance paused seek");
 std::cout<<"PASS held processed reply across seek waits for exact new coverage\n";
 // Refill after a backward seek uses a fresh processor history; read failure
 // attributes the original occurrence and cannot turn into EOF/readiness.
 e.scheduleTransport(++seq,1,3,40000);e.render(out,1);e.snapshot(snap);
 testReadError.store(SQ_FILE_DECODE);
 until([&]{w.pump(snap);e.render(out,1);e.snapshot(snap);return w.error()!=0;});
 require(w.error()==SQ_FILE_DECODE && w.errorInstance()==1 && !w.ready(snap),"processed refill error attribution");
 testReadError.store(0);
 std::cout<<"PASS processed refill error retains occurrence attribution and refuses readiness\n";
 e.installSchedule(++seq,nullptr,0);e.render(out,1);
 }
 // Three successive occurrences share the same slot and reuse bank zero. Each
 // successor must be separately prepared; no prior PCM/processor epoch revival.
 auto a=c,b=c,d=c;a.trimOut=b.trimOut=d.trimOut=32000;
 b.instance=2;b.start=64000;d.instance=3;d.start=128000;
 s=t::Schedule::compile(2,32000,{a,b,d});require(bool(s),"turnover schedule");
 require(s->banks[0]==s->banks[2] && s->banks[0]!=s->banks[1],"two alternating banks");
 paths.assign(3,"/fake/tempo");e.installSchedule(++seq,s.get(),0);e.render(out,1);e.snapshot(snap);
 {
 ScheduleWorker w(0,*s,paths,e,seq);
 until([&]{w.pump(snap);e.render(out,1);e.snapshot(snap);return w.ready(snap);});
 e.scheduleTransport(++seq,2,3,128000);e.render(out,1);e.snapshot(snap);
 require(!w.ready(snap),"different occurrence cannot inherit bank readiness");
 until([&]{w.pump(snap);e.render(out,1);e.snapshot(snap);return w.ready(snap);});
 e.scheduleTransport(++seq,2,1,0);e.render(out,256);e.snapshot(snap);
 require(snap.decks[0].identity==3 && snap.decks[0].processingEpoch==2,"fresh processed occurrence identity");
 e.installSchedule(++seq,nullptr,0);e.render(out,1);
 }
 std::cout<<"PASS processed occurrence-bank turnover with exact revision epoch\n";
 return 0;
 }catch(const std::exception& err){testHoldRead.store(false);testReadError.store(0);std::cerr<<"FAIL "<<err.what()<<'\n';return 1;}}

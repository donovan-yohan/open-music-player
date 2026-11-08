#include "soundq_transport.hpp"
#include "soundq_tempo_map.hpp"
#include <cassert>
#include <cmath>
#include <iostream>
#include <vector>
using namespace soundq::transport;
#ifdef SOUNDQ_TRANSPORT_TEST_BARRIERS
#include <atomic>
#include <thread>
namespace soundq::transport::test {extern std::atomic<unsigned> holdStage,reachedStage;}
#endif

// API-discovery RED on predecessor, then the same sample-consuming fixture.
template<class E> auto handoff(E& e,uint64_t seq,const Schedule* s,uint64_t tag,uint64_t boundary,const std::array<PcmWindow,4>& w,int)
 -> decltype(e.handoffTempo(seq,s,tag,boundary,1,w)) {return e.handoffTempo(seq,s,tag,boundary,1,w);}
template<class E> bool handoff(E&,uint64_t,const Schedule*,uint64_t,uint64_t,const std::array<PcmWindow,4>&,long){return false;}

static void twoOfFour(){
 ScheduleClip c{1,0,0,32000,0,32000,32000,32000,0,0,1};c.tempo={true,0,120,120,120,0,1,0,TempoOverlapPolicy::IndependentConstant};
 auto b=c;b.instance=2;auto p=c;p.instance=3;p.tempo={};auto q=p;q.instance=4;
 auto graph=Schedule::compile(1,32000,{c,b,p,q});assert(graph);Engine e(32000);uint64_t seq=0;float pcm[2];Snapshot snap;
 std::vector<float> a(32000*2),next(32000*2),peer(32000*2);for(size_t i=0;i<32000;++i){a[i*2]=.0625f;next[i*2]=.125f;peer[i*2+1]=.015625f;}
 PcmWindow wa,wn,wp;wa.count=wn.count=wp.count=1;wa.pages[0]={a.data(),0,32000};wn.pages[0]={next.data(),0,27000};wp.pages[0]={peer.data(),0,32000};assert(e.installSchedule(++seq,graph.get(),0));
 for(unsigned i=0;i<4;++i)assert(e.bindSchedule(++seq,1,i+1,i<2?wa:wp));assert(e.scheduleTransport(++seq,1,1,0));e.render(nullptr,1000);
 auto clips=graph->clips;for(unsigned i=0;i<2;++i){clips[i].mapFrame=2000;clips[i].mapSource=2000;clips[i].tempo.startBpm=clips[i].tempo.endBpm=144;}
 auto edited=Schedule::compile(1,32000,clips);assert(edited);std::array<PcmWindow,4> windows{};windows[0]=windows[1]=wn;
 assert(e.handoffTempo(++seq,edited.get(),1,2000,3,windows));
 for(unsigned i=1000;i<4000;++i){e.render(pcm,1);assert(e.snapshot(snap));assert(snap.globalFrame==i+1 && snap.schedulePlaying && !snap.scheduleBuffering);assert(pcm[1]==.03125f && pcm[0]==(i<2000?.125f:.25f));for(unsigned j=2;j<4;++j)assert(snap.decks[j].sourceFrame==i+1);}
 assert(snap.decks[0].tempoGeneration==1 && snap.decks[1].tempoGeneration==1 && snap.decks[2].tempoGeneration==0);assert(e.installSchedule(++seq,nullptr,0));e.render(pcm,0);
 std::cout<<"PASS atomic two-of-four changed generation, exact two-peer PCM and cursors\n";
}
static void repeatedSlots(){
 ScheduleClip c{1,0,0,32000,0,32000,32000,96000,100,200,1};
 auto future=c;future.instance=2;future.start=40000;future.end=72000;
 auto peer=c;peer.instance=3;peer.end=96000;peer.trimOut=96000;peer.fadeIn=peer.fadeOut=0;
 auto old=Schedule::compile(1,32000,{c,future,peer});assert(old && old->clips[0].slot==old->clips[1].slot && old->banks[0]!=old->banks[1]);
 auto clips=old->clips;clips[0].mapFrame=2000;clips[0].mapSource=2000;clips[0].tempo={true,0,120,144,144,2000,2001,0,TempoOverlapPolicy::IndependentConstant};
 auto next=Schedule::compile(1,32000,clips);assert(next);Engine e(32000);uint64_t seq=0;float pcm[2];Snapshot snap;
 std::vector<float> a(96000*2),b(96000*2),f(96000*2),p(96000*2);for(unsigned i=0;i<96000;++i){a[i*2]=.125f;b[i*2]=.25f;f[i*2]=.375f;p[i*2+1]=.03125f;}
 PcmWindow wa,wb,wf,wp;wa.count=wb.count=wf.count=wp.count=1;wa.pages[0]={a.data(),0,32000};wb.pages[0]={b.data(),0,static_cast<uint32_t>(preparedExtent(next->clips[0],32000))};wf.pages[0]={f.data(),0,32001};wp.pages[0]={p.data(),0,48000};wp.pages[1]={p.data()+96000,48000,48000};wp.count=2;
 assert(e.installSchedule(++seq,old.get(),0));assert(e.bindSchedule(++seq,1,1,wa));assert(e.bindSchedule(++seq,1,2,wf));assert(e.bindSchedule(++seq,1,3,wp));assert(e.scheduleTransport(++seq,1,1,0));e.render(nullptr,1000);
 std::array<PcmWindow,4> windows{};windows[0]=wb;
 // A changed-slot mask must not authorize changing a future occurrence's law.
 auto invalid=next->clips;invalid[1].tempo={true,0,120,144,144,40000,40001,0,TempoOverlapPolicy::IndependentConstant};auto forged=Schedule::compile(1,32000,invalid);assert(forged);assert(!e.handoffTempo(++seq,forged.get(),9,2000,1,windows));
 assert(e.handoffTempo(++seq,next.get(),10,2000,1,windows) && "safe repeated-slot Engine handoff");
 for(unsigned i=1000;i<73000;++i){e.render(pcm,1);assert(e.snapshot(snap));assert(snap.globalFrame==i+1 && !snap.scheduleBuffering);assert(pcm[1]==.03125f);double expected=0;
  const auto& active=i<next->clips[0].end?next->clips[0]:next->clips[1];if(i<next->clips[0].end || (i>=40000 && i<72000)){double x=1;const auto local=i-active.start;if(local<active.fadeIn)x=double(local)/active.fadeIn;if(active.end-i<active.fadeOut)x=std::min(x,double(active.end-i)/active.fadeOut);expected=(i<2000?.125:i<40000?.25:.375)*std::sin(x*1.57079632679489661923);}assert(pcm[0]==static_cast<float>(expected));
  if(i>=40000 && i<72000){assert(snap.decks[0].identity==2 && snap.decks[0].sourceFrame==i+1-40000);assert(snap.decks[0].tempoGeneration==0);}
 }
 assert(e.installSchedule(++seq,nullptr,0));e.render(pcm,0);std::cout<<"PASS repeated-slot exact boundary, retained future binding/fades/source, zero inherited generation, forged future-law refusal\n";
}
static void historyMap(){
 ScheduleClip c{1,0,0,100000,3200,103200,32000,128000,0,0,1};
 c.tempo={true,0,120,108,108,20000,20001,0,TempoOverlapPolicy::IndependentConstant};c.mapFrame=20000;c.mapSource=25200;
 c.tempoHistory={{{},0,3200},{{true,0,120,144,144,10000,10001,0,TempoOverlapPolicy::IndependentConstant},10000,13200}};
 auto graph=Schedule::compile(1,32000,{c});assert(graph);
 assert(sourceAt(graph->clips[0],0,32000)==3200);assert(sourceAt(graph->clips[0],10000,32000)==13200);assert(sourceAt(graph->clips[0],15000,32000)==19200);assert(sourceAt(graph->clips[0],20000,32000)==25200);assert(sourceAt(graph->clips[0],30000,32000)==34200);
 auto invalid=c;invalid.tempoHistory[1].source+=1;assert(!Schedule::compile(1,32000,{invalid}) && "discontinuous historical source rejected");
 invalid=c;invalid.tempoHistory.resize(maxTempoSegments+1);assert(!Schedule::compile(1,32000,{invalid}));
 std::cout<<"PASS bounded continuous historical source map, independent exact source oracle, invalid-prefix refusal\n";
}
int main(){historyMap();repeatedSlots();twoOfFour();
 ScheduleClip c{1,0,0,32000,0,32000,32000,32000,0,0,1};
 c.tempo={true,0,120,120,120,0,1,0,TempoOverlapPolicy::IndependentConstant};
 auto peer=c;peer.instance=2;peer.tempo={};
 auto old=Schedule::compile(1,32000,{c,peer});assert(old);
 Engine e(32000);float pcm[2]{};uint64_t seq=0;Snapshot snap;
 assert(e.installSchedule(++seq,old.get(),0));e.render(pcm,0);
 std::vector<float> a(32000*2),b(32000*2),p(32000*2);
 for(size_t i=0;i<32000;++i){a[2*i]=.125f;b[2*i]=.25f;p[2*i+1]=.03125f;}
 PcmWindow wa,wb,wp;wa.pages[0]={a.data(),0,32000};wa.count=1;wb.pages[0]={b.data(),0,26667};wb.count=1;wp.pages[0]={p.data(),0,32000};wp.count=1;
 assert(e.bindSchedule(++seq,1,1,wa));assert(e.bindSchedule(++seq,1,2,wp));assert(e.scheduleTransport(++seq,1,1,0));
 for(unsigned i=0;i<1000;++i)e.render(pcm,1);
 auto clips=old->clips;clips[0].tempo.startBpm=clips[0].tempo.endBpm=144;
 // Anchor the new law without altering authored starts/trims.
 clips[0].mapFrame=2000;clips[0].mapSource=2000;
 auto next=Schedule::compile(1,32000,clips);assert(next);
 std::array<PcmWindow,4> windows{};windows[0]=wb;
 assert(handoff(e,++seq,next.get(),10,2000,windows,0) && "missing atomic prepared-tempo handoff");
 for(unsigned i=1000;i<4000;++i){e.render(pcm,1);assert(e.snapshot(snap));assert(snap.globalFrame==i+1 && snap.schedulePlaying && !snap.scheduleBuffering);assert(pcm[1]==.03125f);assert(pcm[0]==(i<2000?.125f:.25f));assert(std::abs(snap.decks[0].sourceFrame-(i<2000?double(i+1):2000+(i+1-2000)*1.2))<1e-8);}
 #ifdef SOUNDQ_LIVE_TEMPO_API
 assert(snap.tempoApplied==10 && snap.tempoTerminal==10 && snap.decks[0].tempoGeneration==10);
 #endif
 // A callback-resident future descriptor is not an applied generation.
 assert(e.settleTempo(10));
 auto reverse=next->clips;reverse[0].mapFrame=5000;reverse[0].mapSource=sourceAt(next->clips[0],5000,32000);reverse[0].tempo.startBpm=reverse[0].tempo.endBpm=120;
 auto canceled=Schedule::compile(1,32000,reverse);assert(canceled);
 assert(e.handoffTempo(++seq,canceled.get(),11,5000,1,windows));
 e.render(pcm,0);assert(e.snapshot(snap));assert(snap.tempoTerminal==10);
 assert(e.tempoIntent(1,12));e.render(pcm,1);assert(e.snapshot(snap));assert(snap.tempoTerminal==11 && snap.tempoApplied==10);
 assert(e.settleTempo(11));canceled.reset();
 auto seeked=Schedule::compile(1,32000,reverse);assert(seeked);
 assert(e.handoffTempo(++seq,seeked.get(),12,5000,1,windows));e.render(pcm,0);
 assert(e.scheduleTransport(++seq,1,3,1000));e.render(pcm,0);assert(e.snapshot(snap));
 assert(snap.tempoTerminal==12 && snap.tempoApplied==10 && "seek must retire pending live descriptor");
#ifdef SOUNDQ_TRANSPORT_TEST_BARRIERS
 // Pending descriptor cancellation only retires after the last callback read.
 assert(e.settleTempo(12));
 auto ackGraph=Schedule::compile(1,32000,reverse);assert(ackGraph);
 assert(e.handoffTempo(++seq,ackGraph.get(),13,5000,1,windows));e.render(pcm,0);
 assert(e.tempoIntent(1,14));test::reachedStage=0;test::holdStage=2;
 std::thread callback([&]{e.render(pcm,1);});while(test::reachedStage.load()!=2)std::this_thread::yield();
 assert(e.snapshot(snap));assert(snap.tempoTerminal==12);assert(!e.settleTempo(13));
 test::holdStage=0;callback.join();assert(e.snapshot(snap));assert(snap.tempoTerminal==13);assert(e.settleTempo(13));ackGraph.reset();
#endif
 assert(e.installSchedule(++seq,nullptr,0));e.render(pcm,0);
 std::cout<<"PASS atomic future prepared handoff, exact peer PCM, continuous anchored source and global clock\n";
}

#include "soundq_transport.hpp"
#include <cassert>
#include <cmath>
#include <iostream>
#include <vector>
using namespace soundq::transport;
int main() {
    const unsigned hz=48000;
    std::vector<float> a(3000*2),b(3000*2);
    for(unsigned i=0;i<3000;++i) { a[2*i]=float(i)*.00001f; b[2*i+1]=.1f+float(i)*.00002f; }
    std::vector<ScheduleClip> clips{{1,0,101,501,100,501,48000,3000,100,100,1},
                                    {2,1,201,701,50,550,44100,3000,80,120,1}};
    auto schedule=Schedule::compile(9,hz,clips);
    assert(schedule);
    Engine e(hz); uint64_t seq=1;
    assert(e.installSchedule(seq++,schedule.get(),0));
    PcmWindow wa{}; wa.count=1; wa.pages[0]={a.data(),0,3000};
    PcmWindow wb{}; wb.count=1; wb.pages[0]={b.data(),0,3000};
    assert(e.bindSchedule(seq++,9,1,wa)); assert(e.bindSchedule(seq++,9,2,wb));
    std::vector<float> out(1600);
    e.render(out.data(),16); Snapshot s; assert(e.snapshot(s)); assert(s.globalFrame==0 && !s.schedulePlaying);
    assert(e.scheduleTransport(seq++,9,1,0)); e.render(out.data(),800);
    for(unsigned g=0;g<800;++g) {
        double l=0,r=0;
        if(g>=101 && g<501) { const auto t=g-101; double env=std::min(1.,std::min(t/100.,(400-t)/100.)); l=(100+t)*.00001*std::sin(env*1.5707963267948966); }
        if(g>=201 && g<701) { const auto t=g-201; double env=std::min(1.,std::min(t/80.,(500-t)/120.)); r=(.1+(50+t*44100./hz)*.00002)*std::sin(env*1.5707963267948966); }
        assert(std::abs(out[2*g]-l)<1e-7 && std::abs(out[2*g+1]-r)<1e-7);
    }
    assert(e.snapshot(s) && s.globalFrame==701 && s.scheduleEnded && !s.schedulePlaying);
    assert(e.scheduleTransport(seq++,9,3,250)); e.render(out.data(),20);
    assert(e.snapshot(s) && s.globalFrame==250 && !s.schedulePlaying);
    assert(e.scheduleTransport(seq++,9,1,0)); e.render(out.data(),20);
    assert(e.snapshot(s) && s.globalFrame==270);
    for(unsigned i=0;i<20;++i) {
        const unsigned g=250+i;
        const double level=std::sin(std::min(1.,(g-201)/80.)*1.5707963267948966);
        assert(std::abs(out[2*i+1]-(.1+(50+(g-201)*44100./hz)*.00002)*level)<1e-7);
    }
    assert(e.bindSchedule(seq++,9,1,{})); e.render(out.data(),20);
    assert(e.snapshot(s) && s.globalFrame==290 && s.decks[0].missingPcmFrames==20);
    for(unsigned i=0;i<20;++i) {
        const double t=270+i-201;
        const double expected=(.1+(50+t*44100./hz)*.00002)*std::sin(std::min(1.,t/80.)*1.5707963267948966);
        assert(out[i*2]==0 && std::abs(out[i*2+1]-expected)<1e-7);
    }
    auto bad=clips; for(int i=0;i<3;++i){auto c=clips[0];c.instance=3+i;bad.push_back(c);} assert(!Schedule::compile(10,hz,bad));
    std::vector<ScheduleClip> many;
    for(unsigned i=0;i<500;++i)many.push_back({i+1,0,i*1000ULL,i*1000ULL+400,0,400,hz,3000,0,0,1});
    assert(Schedule::compile(11,hz,many));
    // A late page joins the current phase, not its authored trim-in.
    assert(e.bindSchedule(seq++,9,1,wa)); e.render(out.data(),10);
    for(unsigned i=0;i<10;++i) assert(std::abs(out[i*2]-(100+290+i-101)*.00001)<1e-7);
    assert(e.scheduleTransport(seq++,9,7,0));e.render(out.data(),128);
    assert(std::abs(out[254])<1e-9 && std::abs(out[255])<1e-9);
    assert(e.installSchedule(seq++,nullptr,0)); e.render(nullptr,1);
    assert(e.completedStructuralSequence()==seq-1);
    std::cout<<"PASS schedule every-frame stereo oracle, trims/fades, mixed rates, pause/seek/end, late binding, 500 metadata, fifth overlap refusal\n";
}

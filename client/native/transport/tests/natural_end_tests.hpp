// Included inside transport_tests.cpp's test namespace. Same fixture runs on
// predecessor: its only completion observation is the existing generic EOF.
struct CompletionObservation {
    uint64_t count, generation, identity, revision, currentRevision;
};
CompletionObservation completion(const DeckSnapshot& d) {
#ifdef SOUNDQ_NATURAL_END_API
    return {d.naturalEndCount, d.naturalEndGeneration, d.naturalEndIdentity,
            d.naturalEndTraversalRevision, d.traversalRevision};
#else
    return {d.eofCount, d.generation, d.identity, 0, 0};
#endif
}
bool sameTraversal(const CompletionObservation& old, const DeckSnapshot& current) {
    return old.count && old.generation == current.generation && old.identity == current.identity &&
           old.revision == completion(current).currentRevision;
}
void natural_completion_receipts() {
    unsigned failures = 0;
    auto run = [&](const char* name, auto test) {
        try { test(); std::printf("PASS natural/%s\n", name); }
        catch (const std::exception& e) { ++failures; std::fprintf(stderr,"FAIL natural/%s: %s\n", name,e.what()); }
    };
    const std::vector<float> pcm(16, .25F); // 8 real decoded source frames
    run("forward-and-repeat", [&] {
        Engine e(48000); assign(e,pcm,1,0,11,48000,101);
        check(e.submit(command(Operation::Play,2,0,11)),"play"); e.render(nullptr,7);
        check(completion(snapshot(e).decks[0]).count==0,"not before true EOF");
        const auto heapBefore=heap_probe::operations.load(); heap_probe::callback=true;
        e.render(nullptr,1); heap_probe::callback=false;
        check(heap_probe::operations.load()==heapBefore,"natural receipt callback stays heap-free");
        auto d=snapshot(e).decks[0]; auto first=completion(d);
        check(first.count==1 && first.generation==11 && first.identity==101 && sameTraversal(first,d),"captured real source completion");
        e.render(nullptr,30); check(completion(snapshot(e).decks[0]).count==1,"one receipt per crossing");
        check(e.submit(command(Operation::Seek,3,0,11,0)),"repeat seek");
        check(e.submit(command(Operation::Play,4,0,11)),"repeat play");e.render(nullptr,8);
        d=snapshot(e).decks[0];auto second=completion(d);
        check(second.count==2 && sameTraversal(second,d),"repeat creates fresh receipt");
        check(!sameTraversal(first,d),"old repeat traversal cannot clear successor");
    });
    for(bool paused:{false,true}) run(paused?"paused-endpoint-seek":"playing-endpoint-seek",[&] {
        Engine e(48000);assign(e,pcm);uint64_t s=1;
        if(!paused)check(e.submit(command(Operation::Play,++s)),"play");
        check(e.submit(command(Operation::Seek,++s,0,1,8)),"seek endpoint");e.render(nullptr,1);
        if(paused){check(snapshot(e).decks[0].eofCount==0,"paused EOF compatibility");check(e.submit(command(Operation::Play,++s)),"play endpoint");e.render(nullptr,1);}
        const auto d=snapshot(e).decks[0];
        check(d.eofCount==1 && !d.playing,"generic endpoint EOF unchanged");
        check(completion(d).count==0,"seeking endpoint never proves consumed natural end");
        check(e.submit(command(Operation::Seek,++s,0,1,7)),"seek before endpoint");
        check(e.submit(command(Operation::Play,++s)),"play last real frame");e.render(nullptr,1);
        check(completion(snapshot(e).decks[0]).count==1,"real end after seek-before-end qualifies");
    });
    run("pause-before-end",[&]{
        Engine e(48000);assign(e,pcm);check(e.submit(command(Operation::Play,2)),"play");e.render(nullptr,7);
        check(e.submit(command(Operation::Pause,3)),"pause");e.render(nullptr,32);
        check(completion(snapshot(e).decks[0]).count==0,"pause retains unfinished traversal");
        check(e.submit(command(Operation::Play,4)),"resume");e.render(nullptr,1);
        check(completion(snapshot(e).decks[0]).count==1,"resumed consumption qualifies");
    });
    run("reverse",[&]{
        Engine e(48000);assign(e,pcm);check(e.submit(command(Operation::Seek,2,0,1,7)),"seek");
        check(e.submit(command(Operation::SetRate,3,0,1,-1)),"reverse rate");e.render(nullptr,128); // settle the real 128-frame ramp while paused
        check(e.submit(command(Operation::Play,4)),"reverse play");e.render(nullptr,16);
        const auto d=snapshot(e).decks[0];check(d.sourceFrame==0 && completion(d).count==0,"reverse boundary is not natural end");
    });
    for(bool cancel:{false,true})run(cancel?"scratch-cancel":"scratch-end",[&]{
        Engine e(48000);assign(e,pcm);check(e.submit(command(Operation::Play,2)),"play");
        auto c=command(Operation::BeginScratch,3);c.gesture=9;check(e.submit(c),"begin scratch");e.render(nullptr,8);
        auto d=snapshot(e).decks[0];check(d.eofCount==1,"scratch generic EOF unchanged");
        check(completion(d).count==0,"scratch crossing not ordinary consumption");
        c=command(cancel?Operation::CancelScratch:Operation::EndScratch,4);c.gesture=9;check(e.submit(c),"terminal scratch");e.render(nullptr,8);
        check(completion(snapshot(e).decks[0]).count==0,"terminal scratch cannot synthesize receipt");
    });
    run("stale-seek-and-source",[&]{
        Engine e(48000);assign(e,pcm,1,0,11,48000,101);check(e.submit(command(Operation::Play,2,0,11)),"play");e.render(nullptr,8);
        const auto old=completion(snapshot(e).decks[0]);
        check(e.submit(command(Operation::Seek,3,0,11,7)),"new seek");e.render(nullptr,0);
        check(!sameTraversal(old,snapshot(e).decks[0]),"delayed completion cannot clear seek successor");
        // Same identity, different generation is still a different source lease.
        assign(e,pcm,4,0,12,48000,101);e.render(nullptr,0);auto d=snapshot(e).decks[0];
        check(completion(d).count==0 && !sameTraversal(old,d),"replacement resets evidence and fences old source");
        check(!e.submit(command(Operation::Seek,5,0,11,8)),"stale source seek refused");
        check(e.submit(command(Operation::Play,6,0,12)),"new source play");e.render(nullptr,8);
        const auto fresh=completion(snapshot(e).decks[0]);check(fresh.count==1 && fresh.generation==12,"fresh source proves own end");
        check(e.unassign(0,7,12),"retire");e.render(nullptr,0);d=snapshot(e).decks[0];
        check(d.identity==0 && completion(d).count==0 && !sameTraversal(fresh,d),"retirement erases receipt");
    });
    run("stale-scratch-and-rate",[&]{
        Engine e(48000);assign(e,pcm);check(e.submit(command(Operation::Play,2)),"play");e.render(nullptr,8);
        const auto old=completion(snapshot(e).decks[0]);
        check(e.submit(command(Operation::SetRate,3,0,1,-1)),"reverse intent");e.render(nullptr,0);
        check(!sameTraversal(old,snapshot(e).decks[0]),"rate/reverse intent fences held completion");
        const auto rateRevision=completion(snapshot(e).decks[0]).currentRevision;
        auto c=command(Operation::BeginScratch,4);c.gesture=9;check(e.submit(c),"scratch intent");e.render(nullptr,0);
        check(completion(snapshot(e).decks[0]).currentRevision!=rateRevision,"scratch intent advances revision");
    });
    run("outgoing-overlap-and-missing-pcm",[&]{
        Engine e(48000);PcmWindow w{};w.count=1;w.pages[0]={pcm.data(),0,8};
        check(e.assignPaged(0,1,11,{8,48000,101},w),"outgoing");
        check(e.assignPaged(1,2,12,{8,48000,102},w),"incoming");
        check(e.crossfade(3,0,11,1,12,4),"crossfade");check(e.submit(command(Operation::Play,4,0,11)),"play");
        e.render(nullptr,7);auto s=snapshot(e);
        check(s.decks[1].boundaryGain>s.decks[0].boundaryGain,"incoming selected/dominant before outgoing end");
        check(completion(s.decks[0]).count==0,"not midpoint completion");
        check(e.publishWindow(1,5,12,{}),"remove incoming PCM");e.render(nullptr,8);s=snapshot(e);
        check(s.decks[0].sourceFrame==7 && completion(s.decks[0]).count==0,"overlap missing page holds without completion");
        check(e.publishWindow(1,6,12,w),"restore");e.render(nullptr,1);s=snapshot(e);
        const auto outgoing=completion(s.decks[0]);
        check(outgoing.count==1 && outgoing.identity==101 && outgoing.generation==11,"actual outgoing source receipt, not selected incoming");
        check(completion(s.decks[1]).count==0 && s.decks[1].sourceFrame==4,"incoming not yet complete");
        e.render(nullptr,4);s=snapshot(e);check(completion(s.decks[1]).count==1 && completion(s.decks[1]).identity==102,"incoming independent completion");
    });
    check(failures==0,"qualified natural completion regression(s)");
}

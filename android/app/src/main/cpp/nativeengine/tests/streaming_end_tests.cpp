#include "soundq_transport.hpp"
#include <array>
#include <cassert>
#include <cmath>
#include <iostream>
using namespace soundq::transport;
int main() {
    Engine engine(48000);
    std::array<float, 16> pcm{}; pcm.fill(.25f);
    PcmWindow window{}; window.count=1; window.pages[0]={pcm.data(),0,8};
    // Explicit unknown PCM extent. Resident coverage is not logical EOF.
    assert(engine.assignPaged(0,1,1,{0,48000,7},window));
    Command play{}; play.operation=Operation::Play;play.deck=0;play.sequence=2;play.generation=1;
    assert(engine.submit(play));
    std::array<float,32> output{};engine.render(output.data(),16);
    Snapshot snap{};assert(engine.snapshot(snap));
    assert(output[0]==.25f && output[12]==.25f);
    assert(snap.decks[0].sourceFrame==7 && snap.decks[0].playing);
    assert(snap.decks[0].eofCount==0 && snap.decks[0].naturalEndCount==0);
    assert(snap.decks[0].missingPcmFrames>0);
    assert(!engine.publishWindowEnd(0,3,2,window,8,1)); // wrong source generation
    assert(engine.publishWindowEnd(0,4,1,window,8,1));
    engine.render(output.data(),0); assert(engine.snapshot(snap));
    assert(snap.decks[0].naturalEndCount==0 && snap.decks[0].sourceFrame==7);
    engine.render(output.data(),1); assert(engine.snapshot(snap));
    assert(output[0]==.25f && snap.decks[0].sourceFrame==8);
    assert(snap.decks[0].naturalEndCount==1 && !snap.decks[0].playing);
    assert(!engine.publishWindowEnd(0,5,1,window,9,1)); // sealed end immutable
    Command seek{};seek.operation=Operation::Seek;seek.deck=0;seek.sequence=6;seek.generation=1;seek.value=8;
    assert(engine.submit(seek));play.sequence=7;assert(engine.submit(play));
    engine.render(output.data(),1);assert(engine.snapshot(snap));
    assert(snap.decks[0].naturalEndCount==1); // seek-to-end is not consumption
    assert(engine.unassign(0,8,1));engine.render(nullptr,0);
    assert(!engine.publishWindowEnd(0,9,1,window,8,1)); // late EOS after release
    std::cout<<"PASS same-generation EOS seal requires real consumption; no sought/late completion\n";
    std::cout<<"PASS unknown end stalls on missing interpolation tap without false EOF\n";
}

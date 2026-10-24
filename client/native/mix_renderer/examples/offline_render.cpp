#include "soundq_mix.h"
#include <algorithm>
#include <array>
#include <cmath>
#include <fstream>
#include <iostream>
#include <memory>
#include <vector>

static void u16(std::ostream& out, uint16_t v) {
  out.put(static_cast<char>(v&255)); out.put(static_cast<char>((v>>8)&255));
}
static void u32(std::ostream& out, uint32_t v) { u16(out,v&65535); u16(out,v>>16); }
int main(int argc, char **argv) {
  if(argc!=2) { std::cerr << "usage: offline_render output.wav\n"; return 2; }
  constexpr uint32_t source_frames=60000, total_frames=60000;
  std::array<std::array<std::vector<float>,5>,4> inputs;
  sq_plan p{}; p.revision=1; p.deck_count=4; p.master_gain=.1f;
  const uint64_t starts[]={0,2400,4800,7200}, ends[]={48000,36000,52800,55200};
  for(uint32_t d=0;d<4;++d) {
    auto& deck=p.decks[d]; deck.slot=d; deck.instance_id=d+1;
    deck.start_frame=starts[d]; deck.end_frame=ends[d];
    deck.pcm={48000,5,source_frames,{nullptr,nullptr,nullptr,nullptr,nullptr}};
    for(uint32_t b=0;b<5;++b) {
      auto& pcm=inputs[d][b]; pcm.resize(source_frames*2);
      const uint32_t period=160+d*31+b*13;
      for(uint32_t f=0;f<source_frames;++f) {
        const double triangle=1.0-4.0*std::abs(static_cast<double>(f%period)/period-.5);
        pcm[2*f]=static_cast<float>(triangle*(.02*(b+1)));
        pcm[2*f+1]=static_cast<float>(triangle*(.02*(b+1))*(-.75));
      }
      deck.pcm.buses[b]=pcm.data(); deck.buses[b].gain=1;
    }
  }
  p.decks[2].has_seek=1; p.decks[2].seek_frame=18000; p.decks[2].seek_source_frame=3000;
  sq_config config{SQ_ABI_VERSION,48000,256,source_frames};
  std::unique_ptr<sq_engine,decltype(&sq_destroy)> e(sq_create(&config),sq_destroy);
  if(!e || sq_submit(e.get(),&p)!=SQ_OK) return 3;
  std::vector<float> rendered(total_frames*2);
  uint32_t position=0;
  while(position<total_frames) {
    if(position==4800) {
      ++p.revision; p.decks[3].start_frame=9600;
      if(sq_submit(e.get(),&p)!=SQ_OK) return 4;
    }
    if(position==12000) {
      ++p.revision; p.decks[0].buses[0].muted=1; p.decks[0].buses[0].ramp_frames=240;
      if(sq_submit(e.get(),&p)!=SQ_OK) return 4;
    }
    if(position==24000) {
      ++p.revision; p.decks[3].buses[4].gain=.5f; p.decks[3].buses[4].ramp_frames=480;
      if(sq_submit(e.get(),&p)!=SQ_OK) return 4;
    }
    uint32_t count=std::min(256u,total_frames-position);
    for(uint32_t boundary:{4800u,12000u,24000u}) if(position<boundary) count=std::min(count,boundary-position);
    if(sq_render(e.get(),rendered.data()+2*position,count)!=SQ_OK) return 5;
    position+=count;
  }
  // All file I/O and PCM16 conversion occur outside render, intentionally.
  std::ofstream wav(argv[1],std::ios::binary|std::ios::trunc);
  wav.write("RIFF",4); u32(wav,36+total_frames*4); wav.write("WAVEfmt ",8);
  u32(wav,16); u16(wav,1); u16(wav,2); u32(wav,48000); u32(wav,192000); u16(wav,4); u16(wav,16);
  wav.write("data",4); u32(wav,total_frames*4);
  double peak=0;
  for(float sample:rendered) {
    peak=std::max(peak,std::abs(static_cast<double>(sample)));
    u16(wav,static_cast<uint16_t>(static_cast<int16_t>(std::lround(static_cast<double>(sample)*32767))));
  }
  wav.close(); if(!wav) { std::cerr << "WAV write failed\n"; return 6; }
  std::cout << "rendered_frames=" << sq_rendered_frames(e.get()) << " applied_revision=" << sq_applied_revision(e.get())
            << " decks=4 buses=20 rate=1 peak_float=" << peak << " output=" << argv[1] << '\n';
}

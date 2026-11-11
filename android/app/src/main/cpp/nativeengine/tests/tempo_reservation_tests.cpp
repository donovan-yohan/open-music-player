// Real Host/worker/DSP/Engine; deterministic codec/output only.
#define main inherited_long_queue_main
#include "long_queue_tempo_tests.cpp"
#undef main
template<class H> auto reserve(H& h,uint64_t handle,int)->decltype(h.reserveTempo(handle,1,1,120,120)){return h.reserveTempo(handle,1,1,120,120);}
template<class H> uint64_t reserve(H&,uint64_t,long){return 1;}
template<class H> auto preview(H& h,uint64_t handle,uint64_t token,uint64_t tag,double bpm,uint64_t glide,int)->decltype(h.liveTempo(handle,1,1,tag,120,bpm,glide,token)){return h.liveTempo(handle,1,1,tag,120,bpm,glide,token);}
template<class H> bool preview(H& h,uint64_t handle,uint64_t,uint64_t tag,double bpm,uint64_t glide,long){return h.liveTempo(handle,1,1,tag,120,bpm,glide);}
template<class H> auto restore(H& h,uint64_t handle,uint64_t token,uint64_t tag,int)->decltype(h.restoreTempo(handle,token,tag)){return h.restoreTempo(handle,token,tag);}
template<class H> bool restore(H& h,uint64_t handle,uint64_t,uint64_t tag,long){return h.liveTempo(handle,1,1,tag,120,120,0);}
int main(int argc,char** argv){
 const bool noop=argc>1&&std::string(argv[1])=="--noop";
 const bool control=argc>1&&std::string(argv[1])=="--control";
 const bool glide=argc>1&&std::string(argv[1])=="--glide";
 const bool pending=argc>1&&std::string(argv[1])=="--pending";
 const bool revoked=argc>1&&std::string(argv[1])=="--revoked";
 const bool origin=argc>1&&std::string(argv[1])=="--origin";
 Registry h;auto output=std::make_unique<Probe>();auto* out=output.get();auto handle=h.open(std::move(output));assert(handle);
 out->offline(h,handle);
 assert(h.prepareSchedule(handle,1,{"/fake/tone","/fake/peer"},{0,0,20000,0,0,0,0,0,20000,0,0,0}));assert(h.arrangement(handle,4,0));float pcm[512];
 const auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(28);
 auto ready=[&]{while(observe(h,handle).find("\"scheduleReady\":true")==std::string::npos){out->render(pcm,1);assert(std::chrono::steady_clock::now()<deadline);std::this_thread::sleep_for(std::chrono::milliseconds(1));}};
 ready();assert(h.arrangement(handle,1,0));out->render(pcm);observe(h,handle);
 auto token=reserve(h,handle,0);assert(token);
 assert(reserve(h,handle,0)==0);assert(!h.restoreTempo(handle,token+1,199));
 assert(!h.liveTempo(handle,1,1,199,120,144,0));
 assert(!h.liveTempo(handle,1,1,199,120,144,0,token+1));
 uint64_t frame=field(observe(h,handle),"globalFrame");
 std::vector<double> positions(1,0); // capture every block endpoint for historical seek proof
 std::vector<uint64_t> frames;
 auto applied=[&](uint64_t tag){for(;;){out->render(pcm);frame+=256;auto s=observe(h,handle);assert(field(s,"globalFrame")==frame);assert(s.find("\"scheduleBuffering\":false")!=std::string::npos);for(unsigned i=0;i<256;++i){assert(pcm[i*2+1]==.03125f);assert(std::isfinite(pcm[i*2]));}frames.push_back(frame);positions.push_back(field(deck(s,0),"sourceFrame"));if(field(s,"tempoApplied")==tag){assert(field(deck(s,0),"tempoGeneration")==tag);return true;}if(field(s,"tempoRefused")==tag)return false;assert(std::chrono::steady_clock::now()<deadline);}};
 if(origin) {
  for(uint64_t tag=1;tag<=128;++tag){assert(preview(h,handle,token,tag,120,0,0));assert(applied(tag));assert(field(deck(observe(h,handle),0),"effectiveBpm")==120);assert(field(observe(h,handle),"tempoHistorySegments")==0);}
  assert(restore(h,handle,token,200,0));assert(applied(200));assert(field(observe(h,handle),"tempoHistorySegments")==0);
  token=reserve(h,handle,0);assert(token);assert(h.releaseTempo(handle,token));token=reserve(h,handle,0);assert(token);
 }else if(pending || revoked) {
  // Fill ordinary budget to one before its limit, then supersede a staged last
  // preview without waiting for its application. Old PCM stays current.
  for(uint64_t tag=1;tag<=62;++tag){assert(preview(h,handle,token,tag,132+tag*.01,0,0));assert(applied(tag));}
  assert(preview(h,handle,token,63,145,0,0));assert(preview(h,handle,token,64,144,0,0));
  if(revoked) {
   assert(h.arrangement(handle,2,0));out->render(pcm,1);observe(h,handle);
   assert(!restore(h,handle,token,200,0));assert(!preview(h,handle,token,201,140,0,0));
  }else {
   assert(restore(h,handle,token,200,0));assert(applied(200));assert(field(deck(observe(h,handle),0),"effectiveBpm")==120);
   assert(field(observe(h,handle),"tempoHistorySegments")<=64);assert(!restore(h,handle,token,201,0));
  }
 }else if(glide){
  assert(preview(h,handle,token,1,144,32000,0));assert(applied(1));
  auto s=observe(h,handle);const double before=field(deck(s,0),"effectiveBpm");assert(before<143);
  assert(preview(h,handle,token,2,144,0,0));assert(applied(2));
  assert(field(deck(observe(h,handle),0),"effectiveBpm")==144);
  assert(field(observe(h,handle),"tempoHistorySegments")==2 && "same endpoint interrupted an unfinished glide: not a no-op");
  assert(restore(h,handle,token,3,0));assert(applied(3));
 }else{
  unsigned accepted=0;for(uint64_t tag=1;tag<=(noop?128:control?63:64);++tag){
   const bool admitted=preview(h,handle,token,tag,noop?132:132+tag*.01,0,0);
   if(!admitted || !applied(tag)){assert(!noop&&tag==64);break;}++accepted;
  }
  if(!noop&&accepted!=63){std::cerr<<"FAIL reserved terminal slot was spent by preview accepted="<<accepted<<std::endl;return 42;}
  if(noop)assert(field(observe(h,handle),"tempoHistorySegments")==1);
  // One latest target may be refused/pending. Terminal must supersede it, not wait on its application.
  assert(restore(h,handle,token,200,0));if(!applied(200)){std::cerr<<"FAIL real native terminal restoration refused"<<std::endl;return 42;}
  auto s=observe(h,handle);assert(field(deck(s,0),"effectiveBpm")==120);assert(!restore(h,handle,token,201,0));
  if(!noop){assert(field(s,"tempoHistorySegments")==64);assert(reserve(h,handle,0)==0 && "a new lease cannot promise unavailable rollback capacity");}
  // Retained seek mapping, real worker READY and Play, unchanged peer.
  for(size_t n:{size_t(0),frames.size()/2,frames.size()-1}){
   const uint64_t target=frames[n];assert(target%32==0);assert(h.arrangement(handle,3,target/32));ready();s=observe(h,handle);assert(field(s,"globalFrame")==target);assert(std::abs(field(deck(s,0),"sourceFrame")-positions[n+1])<1e-6);assert(h.arrangement(handle,1,0));out->render(pcm);assert(pcm[1]==.03125f);
  }
 }
 assert(h.close(handle));assert(decoders==0&&callbackNews==0);
 std::cout<<"PASS "<<(origin?"128 unchanged origin receipts, zero history, fresh lease":pending?"terminal supersedes staged/latest preview near capacity":revoked?"transport revokes captured native reservation without rollback":control?"63 meaningful-preview positive control, native terminal restore at 64":noop?"128 constant targets stable history + applied receipts":glide?"same-endpoint glide interruption spends history":"63 meaningful previews, refused 64th, terminal restore at 64, new lease refused, history seek")<<", unchanged peer, no callback allocations"<<std::endl;
}

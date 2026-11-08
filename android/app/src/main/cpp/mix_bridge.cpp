#include "soundq_mix.h"
#include "sq_opus_decoder.h"
#include <jni.h>
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <memory>
#include <limits>
#include <string>
#include <vector>

namespace {
constexpr uint32_t block=2048;
struct Decoder { sq_opus_decoder* p=nullptr; ~Decoder(){sq_opus_decoder_destroy(p);} };
struct Clip { sq_schedule_clip c{}; sq_clip_automation a{}; int paths[5]{}; std::vector<sq_stem_event> events; };
struct Mix { std::vector<std::unique_ptr<Decoder>> decoders; std::vector<Clip> clips; };
struct Engine { sq_engine* p; explicit Engine():p(nullptr){sq_config c{SQ_ABI_VERSION,48000,block,48000};p=sq_create(&c);} ~Engine(){sq_destroy(p);} };
bool compile(Mix& m,sq_engine* e,uint64_t origin,uint32_t count,float* output) {
  std::unique_ptr<sq_engine,decltype(&sq_destroy)> owned(output?e:nullptr,sq_destroy);
  std::vector<sq_schedule_clip> clips; std::vector<sq_clip_automation> autos;
  std::vector<sq_pcm_window> windows; std::vector<std::vector<float>> pcm;
  const uint64_t end=origin+count;
  if(end<origin)return false;
  for(auto& x:m.clips) {
    if(output && (x.c.end_frame<=origin || x.c.start_frame>=end))continue;
    auto c=x.c; auto a=x.a;
    a.events=x.events.data();a.event_count=static_cast<uint32_t>(x.events.size());
    if(output) {
      const uint64_t start=std::max(origin,c.start_frame), stop=std::min(end,c.end_frame);
      const uint64_t source=c.source_start_frame+start-c.start_frame;
      const auto n=static_cast<uint32_t>(stop-start);
      sq_pcm_window w{};w.asset_id=c.asset_id;w.source_start_frame=source;
      w.pcm.sample_rate=48000;w.pcm.bus_count=c.bus_count;w.pcm.frame_count=n;
      for(uint32_t b=0;b<c.bus_count;b++) {
        pcm.emplace_back(n*2);uint32_t got=0;
        if(sq_opus_decoder_read_window(m.decoders[x.paths[b]]->p,static_cast<int64_t>(source),n,pcm.back().data(),n*2*sizeof(float),&got)!=SQ_OPUS_OK || got!=n)return false;
        w.pcm.buses[b]=pcm.back().data();
      }
      windows.push_back(w);c.source_start_frame=source;c.start_frame=start-origin;c.end_frame=stop-origin;
    }
    clips.push_back(c);autos.push_back(a);
  }
  sq_schedule_desc desc{1,1,static_cast<uint32_t>(clips.size()),clips.data(),static_cast<uint32_t>(windows.size()),windows.data()};
  sq_schedule* schedule=nullptr;
  if(sq_schedule_create_automated(e,&desc,static_cast<uint32_t>(autos.size()),autos.data(),&schedule)!=SQ_OK)return false;
  bool ok=true;
  if(output)ok=sq_schedule_submit(e,schedule)==SQ_OK && sq_render(e,output,count)==SQ_OK && sq_missing_pcm_frames(e)==0;
  // Engine destruction marks the borrowed schedule COMPLETE before buffers die.
  if(output){owned.reset();}
  if(sq_schedule_retire(schedule)!=SQ_OK)return false;
  return ok;
}
void fail(JNIEnv* env){env->ThrowNew(env->FindClass("java/lang/IllegalArgumentException"),"Native mix refused source, extent or schedule");}
}
extern "C" __attribute__((visibility("default"))) void* sq_android_open(const char* const* paths,uint32_t path_count,const int64_t* data,uint32_t clip_count,const float* gains,const int64_t* events,const float* event_gains,uint32_t event_count) {
 try {
  if(!paths||!data||!gains||path_count==0||path_count>32||clip_count==0||clip_count>1000||event_count>4096||(event_count&&(!events||!event_gains)))return nullptr;
  auto m=std::make_unique<Mix>();
  for(uint32_t i=0;i<path_count;i++) {
    auto d=std::make_unique<Decoder>();
    if(sq_opus_decoder_open(paths[i],SQ_OPUS_MAX_FILE_BYTES,&d->p)!=SQ_OPUS_OK||sq_opus_decoder_sample_rate(d->p)!=48000||sq_opus_decoder_channels(d->p)!=2)return nullptr;
    m->decoders.push_back(std::move(d));
  }
  for(uint32_t i=0;i<clip_count;i++) {
    const auto* v=data+i*12;
    for(int j=0;j<7;j++)if(v[j]<0)return nullptr;
    if(v[6]<1||v[6]>5)return nullptr;
    Clip x;x.c.instance_id=static_cast<uint64_t>(v[0]);x.c.asset_id=i+1;
    x.c.start_frame=v[1];x.c.end_frame=v[2];x.c.source_start_frame=v[3];x.c.bus_count=static_cast<uint32_t>(v[6]);
    int64_t extent=-1;
    for(uint32_t b=0;b<x.c.bus_count;b++) {
      if(v[7+b]<0||v[7+b]>=path_count)return nullptr;
      x.paths[b]=static_cast<int>(v[7+b]);
      const auto frames=sq_opus_decoder_frame_count(m->decoders[x.paths[b]]->p);
      if(frames<=0||(extent>=0 && extent!=frames))return nullptr;
      extent=frames;x.c.buses[b]={1,0,0};
    }
    x.c.source_frame_count=static_cast<uint64_t>(extent);
    x.a.instance_id=x.c.instance_id;x.a.base_gain=gains[i];
    x.a.envelope_source_start_frame=x.c.source_start_frame;
    x.a.envelope_frame_count=x.c.end_frame-x.c.start_frame;x.a.fade_in_frames=v[4];x.a.fade_out_frames=v[5];x.a.fade_curve=SQ_FADE_EQUAL_POWER;
    m->clips.push_back(std::move(x));
  }
  for(uint32_t i=0;i<event_count;i++) {
    const auto* v=events+i*4;
    if(v[0]<0||v[0]>=clip_count||v[1]<0||v[2]<0||v[2]>=5||v[3]<1||v[3]>12000)return nullptr;
    m->clips[static_cast<size_t>(v[0])].events.push_back({static_cast<uint64_t>(v[1]),static_cast<uint32_t>(v[2]),static_cast<uint32_t>(v[3]),event_gains[i]});
  }
  for(auto& x:m->clips)std::sort(x.events.begin(),x.events.end(),[](const auto& a,const auto& b){return a.source_frame<b.source_frame||(a.source_frame==b.source_frame&&a.bus<b.bus);});
  Engine e;if(!e.p||!compile(*m,e.p,0,0,nullptr))return nullptr;
  return m.release();
 }catch(...){return nullptr;}
}
extern "C" __attribute__((visibility("default"))) int sq_android_render(void* ptr,uint64_t start,uint32_t count,float* out) {
 if(!ptr||!out||count==0||count>block)return 1;
 try {Engine e;if(!e.p)return 1;auto p=e.p;e.p=nullptr;return compile(*static_cast<Mix*>(ptr),p,start,count,out)?0:1;}catch(...){return 1;}
}
extern "C" __attribute__((visibility("default"))) void sq_android_close(void* ptr){delete static_cast<Mix*>(ptr);}
// Caller retains each immutable stereo window until this synchronous call returns.
// Eight frame fields: instance,start,end,sourceStart,sourceExtent,fadeIn,fadeOut,windowOrigin.
extern "C" __attribute__((visibility("default"))) int sq_android_render_pcm(uint64_t origin,uint32_t count,const int64_t* data,uint32_t clip_count,const float* const* pcm,const uint32_t* frames,const float* gains,float* out) {
 try {
  if(!out||count==0||count>block||clip_count>SQ_MAX_DECKS||origin>std::numeric_limits<uint64_t>::max()-count||
     (clip_count&&(!data||!pcm||!frames||!gains)))return 1;
  std::vector<sq_schedule_clip> clips;std::vector<sq_clip_automation> autos;std::vector<sq_pcm_window> windows;
  const auto end=origin+count;
  for(uint32_t i=0;i<clip_count;i++) {
    const auto* v=data+i*8;
    for(int j=0;j<8;j++)if(v[j]<0)return 1;
    const auto start=static_cast<uint64_t>(v[1]),stop=static_cast<uint64_t>(v[2]);
    const auto source=static_cast<uint64_t>(v[3]),extent=static_cast<uint64_t>(v[4]),window=static_cast<uint64_t>(v[7]);
    if(v[0]==0||stop<=start||stop<=origin||start>=end||source>extent||stop-start>extent-source||
       static_cast<uint64_t>(v[5])>stop-start||static_cast<uint64_t>(v[6])>stop-start-static_cast<uint64_t>(v[5])||
       !pcm[i]||frames[i]==0||frames[i]>48000||window>extent||frames[i]>extent-window||
       !std::isfinite(gains[i])||gains[i]<0||gains[i]>1)return 1;
    for(const auto& c:clips)if(c.instance_id==static_cast<uint64_t>(v[0]))return 1;
    const auto active_start=std::max(origin,start),active_end=std::min(end,stop);
    const auto needed=source+active_start-start;
    if(needed<window||needed-window>frames[i]||active_end-active_start>frames[i]-(needed-window))return 1;
    sq_schedule_clip c{};c.instance_id=v[0];c.asset_id=i+1;c.start_frame=active_start-origin;c.end_frame=active_end-origin;
    c.source_start_frame=needed;c.source_frame_count=extent;c.bus_count=1;c.buses[0]={1,0,0};clips.push_back(c);
    sq_clip_automation a{};a.instance_id=c.instance_id;a.base_gain=gains[i];a.envelope_source_start_frame=source;
    a.envelope_frame_count=stop-start;a.fade_in_frames=v[5];a.fade_out_frames=v[6];a.fade_curve=SQ_FADE_EQUAL_POWER;autos.push_back(a);
    sq_pcm_window w{};w.asset_id=c.asset_id;w.source_start_frame=window;w.pcm.sample_rate=48000;w.pcm.bus_count=1;w.pcm.frame_count=frames[i];w.pcm.buses[0]=pcm[i];windows.push_back(w);
  }
  Engine engine;if(!engine.p)return 1;
  sq_schedule_desc desc{1,1,static_cast<uint32_t>(clips.size()),clips.data(),static_cast<uint32_t>(windows.size()),windows.data()};
  sq_schedule* raw=nullptr;
  if(sq_schedule_create_automated(engine.p,&desc,static_cast<uint32_t>(autos.size()),autos.data(),&raw)!=SQ_OK)return 1;
  // Declare the schedule before its owner so every exit destroys the engine first.
  std::unique_ptr<sq_schedule,decltype(&sq_schedule_retire)> schedule(raw,sq_schedule_retire);
  std::unique_ptr<sq_engine,decltype(&sq_destroy)> owner(engine.p,sq_destroy);engine.p=nullptr;
  float result[block*2];
  if(sq_schedule_submit(owner.get(),raw)!=SQ_OK||sq_render(owner.get(),result,count)!=SQ_OK||sq_missing_pcm_frames(owner.get())!=0)return 1;
  owner.reset();schedule.reset();std::copy(result,result+count*2,out);return 0;
 }catch(...){return 1;}
}
extern "C" JNIEXPORT void JNICALL Java_com_soundq_android_playback_mix_NativeMix_renderPcmBlock(JNIEnv* env,jobject,jlong origin,jint count,jlongArray clip_array,jobjectArray window_array,jfloatArray gain_array,jbyteArray bytes) {
 try {
  if(!clip_array||!window_array||!gain_array||!bytes||origin<0||count<1||count>static_cast<jint>(block)){fail(env);return;}
  const auto n=env->GetArrayLength(window_array);
  if(n>static_cast<jsize>(SQ_MAX_DECKS)||env->GetArrayLength(clip_array)!=n*8||env->GetArrayLength(gain_array)!=n||env->GetArrayLength(bytes)<count*8){fail(env);return;}
  std::vector<jlong> clips(n*8);std::vector<jfloat> gains(n);std::vector<std::vector<float>> windows(n);std::vector<const float*> pointers;std::vector<uint32_t> frames;
  env->GetLongArrayRegion(clip_array,0,n*8,clips.data());env->GetFloatArrayRegion(gain_array,0,n,gains.data());
  for(jsize i=0;i<n;i++) {
    auto array=static_cast<jfloatArray>(env->GetObjectArrayElement(window_array,i));
    if(!array){fail(env);return;}const auto size=env->GetArrayLength(array);
    if(size==0||size%2||size>96000){env->DeleteLocalRef(array);fail(env);return;}
    windows[i].resize(size);env->GetFloatArrayRegion(array,0,size,windows[i].data());env->DeleteLocalRef(array);
    frames.push_back(size/2);pointers.push_back(windows[i].data());
  }
  if(env->ExceptionCheck())return;
  float result[block*2];
  if(sq_android_render_pcm(origin,count,reinterpret_cast<const int64_t*>(clips.data()),n,pointers.data(),frames.data(),gains.data(),result)!=0){fail(env);return;}
  env->SetByteArrayRegion(bytes,0,count*8,reinterpret_cast<const jbyte*>(result));
 }catch(...){fail(env);}
}
extern "C" JNIEXPORT jlong JNICALL Java_com_soundq_android_playback_mix_NativeMix_open(JNIEnv* env,jobject,jobjectArray path_array,jlongArray clip_array,jfloatArray gain_array,jlongArray event_array,jfloatArray event_gain_array) {
 try {
  const auto n=env->GetArrayLength(path_array),cn=env->GetArrayLength(clip_array),gn=env->GetArrayLength(gain_array),en=env->GetArrayLength(event_array),egn=env->GetArrayLength(event_gain_array);
  if(n<1||n>32||cn<12||cn%12||gn!=cn/12||en%4||egn!=en/4||egn>4096){fail(env);return 0;}
  std::vector<std::string> strings;std::vector<const char*> paths;
  for(jsize i=0;i<n;i++){auto s=static_cast<jstring>(env->GetObjectArrayElement(path_array,i));const char* p=env->GetStringUTFChars(s,nullptr);if(!p)return 0;strings.emplace_back(p);env->ReleaseStringUTFChars(s,p);env->DeleteLocalRef(s);}
  for(auto& s:strings)paths.push_back(s.c_str());
  std::vector<jlong> clips(cn),events(en);std::vector<jfloat> gains(gn),eg(egn);
  env->GetLongArrayRegion(clip_array,0,cn,clips.data());env->GetFloatArrayRegion(gain_array,0,gn,gains.data());env->GetLongArrayRegion(event_array,0,en,events.data());env->GetFloatArrayRegion(event_gain_array,0,egn,eg.data());
  auto h=sq_android_open(paths.data(),n,reinterpret_cast<const int64_t*>(clips.data()),gn,gains.data(),reinterpret_cast<const int64_t*>(events.data()),eg.data(),egn);
  if(!h)fail(env);return reinterpret_cast<jlong>(h);
 }catch(...){fail(env);return 0;}
}
extern "C" JNIEXPORT void JNICALL Java_com_soundq_android_playback_mix_NativeMix_render(JNIEnv* env,jobject,jlong h,jlong start,jint count,jbyteArray bytes) {
 if(h==0||start<0||count<1||count>static_cast<jint>(block)||env->GetArrayLength(bytes)<count*8){fail(env);return;}
 float out[block*2];if(sq_android_render(reinterpret_cast<void*>(h),static_cast<uint64_t>(start),count,out)!=0){fail(env);return;}
 env->SetByteArrayRegion(bytes,0,count*8,reinterpret_cast<const jbyte*>(out));
}
extern "C" JNIEXPORT void JNICALL Java_com_soundq_android_playback_mix_NativeMix_probe(JNIEnv* env,jobject,jstring path,jlong frames,jlong preskip) {
 const char* p=env->GetStringUTFChars(path,nullptr);if(!p)return;
 Decoder d;const auto result=sq_opus_decoder_open(p,SQ_OPUS_MAX_FILE_BYTES,&d.p);env->ReleaseStringUTFChars(path,p);
 if(result!=SQ_OPUS_OK||sq_opus_decoder_sample_rate(d.p)!=48000||sq_opus_decoder_channels(d.p)!=2||sq_opus_decoder_frame_count(d.p)!=frames||sq_opus_decoder_pre_skip(d.p)!=preskip)fail(env);
}
extern "C" JNIEXPORT void JNICALL Java_com_soundq_android_playback_mix_NativeMix_close(JNIEnv*,jobject,jlong h){sq_android_close(reinterpret_cast<void*>(h));}

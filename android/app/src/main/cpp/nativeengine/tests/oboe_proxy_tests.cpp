// Execute production Oboe callback proxy with only the device API replaced.
#include "../oboe_output.cpp"
#include <array>
#include <cassert>
#include <chrono>
#include <iostream>
struct Owner final : soundq::nativeengine::Callbacks {
    int errors=0;
    std::atomic<bool> entered{false},hold{false};
    void render(float* out,uint32_t frames)noexcept override {
        entered.store(true);while(hold.load())std::this_thread::yield();
        for(unsigned i=0;i<frames*2;++i)out[i]=.25f;
    }
    void outputError(int32_t)noexcept override{++errors;}
};
int main(){
    Owner owner;auto output=soundq::nativeengine::makeOboeOutput();uint32_t rate=44100;
    assert(output->open(owner,rate));assert(output->start());
    auto old=oboe::testStreams.back();
    owner.hold.store(true);
    std::array<float,2> pcm{};
    std::thread callback([&]{old->data->onAudioReady(old.get(),pcm.data(),1);});
    const auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(5);
    while(!owner.entered.load())assert(std::chrono::steady_clock::now()<deadline);
    std::atomic<bool> closing{false},closed{false};
    std::thread close([&]{closing.store(true);assert(output->stopClose());closed.store(true);});
    while(!closing.load())std::this_thread::yield();
    // Reach the actual revoke boundary, not a scheduler delay approximation.
    auto* proxy=dynamic_cast<soundq::nativeengine::CallbackProxy*>(old->data.get());assert(proxy);
    while(proxy->owner.load()!=nullptr)assert(std::chrono::steady_clock::now()<deadline);
    assert(!closed.load());owner.hold.store(false);callback.join();close.join();assert(closed.load());
    assert(old->closes==1);
    assert(output->open(owner,rate));assert(output->start());
    auto fresh=oboe::testStreams.back();assert(fresh->data!=old->data);
    old->error->onError(old.get(),oboe::Result::ErrorDisconnected);assert(owner.errors==0);
    pcm.fill(1);old->data->onAudioReady(old.get(),pcm.data(),1);assert(pcm[0]==0 && pcm[1]==0);
    fresh->data->onAudioReady(fresh.get(),pcm.data(),1);assert(pcm[0]==.25f);
    fresh->error->onError(fresh.get(),oboe::Result::ErrorDisconnected);assert(owner.errors==1);
    assert(output->stopClose());output.reset();
    fresh->error->onError(fresh.get(),oboe::Result::ErrorDisconnected);assert(owner.errors==1);
    // The exclusive-open attempt can leave a retained dispatcher too. Shared
    // fallback must receive a different proxy, not re-authorize that old one.
    oboe::testFailOpenOnce=true;
    output=soundq::nativeengine::makeOboeOutput();
    const auto first=oboe::testStreams.size();assert(output->open(owner,rate));
    auto rejected=oboe::testStreams[first],fallback=oboe::testStreams[first+1];
    assert(rejected->data!=fallback->data);
    rejected->error->onError(rejected.get(),oboe::Result::ErrorDisconnected);assert(owner.errors==1);
    fallback->error->onError(fallback.get(),oboe::Result::ErrorDisconnected);assert(owner.errors==2);
    assert(output->stopClose());output.reset();
    oboe::testStreams.clear();
    std::cout<<"PASS production callback drain, fresh proxy, obsolete error/data refusal and post-close detached dispatcher\n";
}

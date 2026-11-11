#include "callback_host.hpp"
#include <oboe/Oboe.h>
#include <atomic>
#include <memory>
#include <thread>
namespace soundq::nativeengine {
namespace {
// Oboe owns shared callback objects independently of the registry. In particular
// its detached error dispatcher can finish after close without touching Host.
struct CallbackProxy final : oboe::AudioStreamDataCallback, oboe::AudioStreamErrorCallback {
    std::atomic<Callbacks*> owner{nullptr};
    std::atomic<uint32_t> active{0};
    oboe::DataCallbackResult onAudioReady(oboe::AudioStream*, void* data, int32_t frames) override {
        active.fetch_add(1);
        auto* target = owner.load();
        if (target && frames > 0) target->render(static_cast<float*>(data), static_cast<uint32_t>(frames));
        else if (frames > 0) {
            auto* out = static_cast<float*>(data);
            for (int64_t i = 0; i < int64_t{frames} * 2; ++i) out[i] = 0;
        }
        active.fetch_sub(1);
        return oboe::DataCallbackResult::Continue;
    }
    bool onError(oboe::AudioStream*, oboe::Result error) override {
        active.fetch_add(1);
        auto* target = owner.load();
        if (target) target->outputError(static_cast<int32_t>(error));
        active.fetch_sub(1);
        // The serialized owner performs stop/close. Suppress Oboe auto-close so
        // there is exactly one closer, never an automatic restart/replay.
        return true;
    }
    void revoke() noexcept {
        owner.store(nullptr);
        // Only control thread waits. Future dispatcher entries see null and the
        // shared proxy, not a deleted Host. Seq-cst pairs entry with revocation.
        while (active.load() != 0) std::this_thread::yield();
    }
};
class OboeOutput final : public Output {
    std::shared_ptr<oboe::AudioStream> stream_;
    std::shared_ptr<CallbackProxy> callbacks_ = std::make_shared<CallbackProxy>();
public:
    bool open(Callbacks& owner, uint32_t& actualRate) override {
        // Never re-arm an old proxy. Oboe may still hold a detached dispatcher.
        if (stream_) return false;
        callbacks_ = std::make_shared<CallbackProxy>();
        callbacks_->owner.store(&owner);
        oboe::AudioStreamBuilder builder;
        builder.setDirection(oboe::Direction::Output)
            ->setPerformanceMode(oboe::PerformanceMode::LowLatency)
            ->setSharingMode(oboe::SharingMode::Exclusive)
            ->setFormat(oboe::AudioFormat::Float)->setChannelCount(2)
            ->setUsage(oboe::Usage::Media)->setContentType(oboe::ContentType::Music)
            ->setDataCallback(std::static_pointer_cast<oboe::AudioStreamDataCallback>(callbacks_))
            ->setErrorCallback(std::static_pointer_cast<oboe::AudioStreamErrorCallback>(callbacks_));
        // Keep the extant frame engine honest across route changes. Oboe may
        // negotiate conversion, but a different actual rate is refused by Host.
        if (actualRate != 0) builder.setSampleRate(static_cast<int32_t>(actualRate));
        auto result = builder.openStream(stream_);
        if (result != oboe::Result::OK) {
            // A partially opened attempt must be closed before Shared fallback.
            if (stream_) {
                if (stream_->close() != oboe::Result::OK) return false;
                stream_.reset();
            }
            callbacks_->revoke();
            callbacks_ = std::make_shared<CallbackProxy>();
            callbacks_->owner.store(&owner);
            builder.setDataCallback(std::static_pointer_cast<oboe::AudioStreamDataCallback>(callbacks_))
                ->setErrorCallback(std::static_pointer_cast<oboe::AudioStreamErrorCallback>(callbacks_));
            builder.setSharingMode(oboe::SharingMode::Shared);
            result = builder.openStream(stream_);
        }
        if (result != oboe::Result::OK || !stream_ || stream_->getSampleRate() <= 0 ||
            stream_->getFormat() != oboe::AudioFormat::Float || stream_->getChannelCount() != 2) return false;
        actualRate = static_cast<uint32_t>(stream_->getSampleRate());
        return true;
    }
    bool start() override { return stream_ && stream_->start() == oboe::Result::OK; }
    bool stopClose() override {
        callbacks_->revoke();
        if (!stream_) return true;
        if (stream_->getState() != oboe::StreamState::Closed) {
            // close is still attempted after a disconnected stop: successful
            // close + revoked proxy is the concrete callback lifetime receipt.
            (void)stream_->stop();
            const auto result = stream_->close();
            if (result != oboe::Result::OK && stream_->getState() != oboe::StreamState::Closed) return false;
        }
        stream_.reset();
        return true;
    }
    int32_t xRuns() const noexcept override {
        if (!stream_) return 0;
        const auto result = stream_->getXRunCount();
        return result ? result.value() : 0;
    }
};
}
std::unique_ptr<Output> makeOboeOutput() { return std::make_unique<OboeOutput>(); }
}

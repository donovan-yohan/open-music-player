#pragma once
// TEST ONLY Oboe device boundary. Production oboe_output.cpp is included unchanged.
#include <cstdint>
#include <memory>
#include <vector>
namespace oboe {
enum class Result { OK=0, ErrorDisconnected=-899, ErrorInternal=-1 };
enum class DataCallbackResult { Continue };
enum class Direction { Output };
enum class PerformanceMode { LowLatency };
enum class SharingMode { Exclusive, Shared };
enum class AudioFormat { Float };
enum class Usage { Media };
enum class ContentType { Music };
enum class StreamState { Open, Closed };
struct AudioStream;
struct AudioStreamDataCallback { virtual ~AudioStreamDataCallback()=default; virtual DataCallbackResult onAudioReady(AudioStream*,void*,int32_t)=0; };
struct AudioStreamErrorCallback { virtual ~AudioStreamErrorCallback()=default; virtual bool onError(AudioStream*,Result)=0; };
struct Count { explicit operator bool() const {return true;} int32_t value()const{return 0;} };
struct AudioStream {
    std::shared_ptr<AudioStreamDataCallback> data;
    std::shared_ptr<AudioStreamErrorCallback> error;
    StreamState state=StreamState::Open;
    int32_t rate=44100;
    int stops=0,closes=0;
    Result start(){return Result::OK;}
    Result stop(){++stops;return Result::ErrorDisconnected;}
    Result close(){++closes;state=StreamState::Closed;return Result::OK;}
    StreamState getState()const{return state;}
    int32_t getSampleRate()const{return rate;}
    AudioFormat getFormat()const{return AudioFormat::Float;}
    int getChannelCount()const{return 2;}
    Count getXRunCount()const{return {};}
};
inline std::vector<std::shared_ptr<AudioStream>> testStreams;
inline bool testFailOpenOnce=false;
struct AudioStreamBuilder {
    std::shared_ptr<AudioStreamDataCallback> data;
    std::shared_ptr<AudioStreamErrorCallback> error;
    int32_t rate=44100;
    AudioStreamBuilder* setDirection(Direction){return this;}
    AudioStreamBuilder* setPerformanceMode(PerformanceMode){return this;}
    AudioStreamBuilder* setSharingMode(SharingMode){return this;}
    AudioStreamBuilder* setFormat(AudioFormat){return this;}
    AudioStreamBuilder* setChannelCount(int){return this;}
    AudioStreamBuilder* setUsage(Usage){return this;}
    AudioStreamBuilder* setContentType(ContentType){return this;}
    AudioStreamBuilder* setDataCallback(std::shared_ptr<AudioStreamDataCallback> c){data=std::move(c);return this;}
    AudioStreamBuilder* setErrorCallback(std::shared_ptr<AudioStreamErrorCallback> c){error=std::move(c);return this;}
    AudioStreamBuilder* setSampleRate(int32_t r){rate=r;return this;}
    Result openStream(std::shared_ptr<AudioStream>& s){s=std::make_shared<AudioStream>();s->data=data;s->error=error;s->rate=rate;testStreams.push_back(s);if(testFailOpenOnce){testFailOpenOnce=false;return Result::ErrorInternal;}return Result::OK;}
};
}

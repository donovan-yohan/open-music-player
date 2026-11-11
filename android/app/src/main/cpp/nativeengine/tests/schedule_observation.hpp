#pragma once
#include "callback_host.hpp"
#include <cassert>
#include <cstdlib>
#include <ostream>
#include <string>
#include <string_view>

// Real Engine publication plus actual Host counters, not generated JSON or a
// model. Single-sample numerical oracles need not format four diagnostic decks
// 99,000 times. Periodic full production JSON checks fence this observation.
struct ScheduleObservation : soundq::nativeengine::TestScheduleSnapshot {
    soundq::nativeengine::Registry* owner=nullptr;
    uint64_t handle=0;
    size_t find(std::string_view token) const {
        bool match=false;
        if(token=="\"scheduleReady\":true")match=ready;
        else if(token=="\"scheduleReady\":false")match=!ready;
        else if(token=="\"scheduleBuffering\":false")match=!value.scheduleBuffering;
        else if(token=="\"schedulePlaying\":true")match=value.schedulePlaying;
        else if(token=="\"scheduleEnded\":true")match=value.scheduleEnded;
        else {assert(false && "unknown observation predicate");}
        return match?0:std::string::npos;
    }
};
inline const soundq::transport::DeckSnapshot& deck(const ScheduleObservation& state,unsigned slot){assert(slot<4);return state.value.decks[slot];}
inline double field(const soundq::transport::DeckSnapshot& d,std::string_view key){
    if(key=="sourceFrame")return d.sourceFrame;
    if(key=="effectiveBpm")return d.effectiveBpm;
    if(key=="tempoGeneration")return d.tempoGeneration;
    if(key=="identity")return d.identity;
    if(key=="nominalSourceFrame")return d.nominalSourceFrame;
    assert(false && "unknown deck observation");return 0;
}
inline double field(const ScheduleObservation& s,std::string_view key){
    if(key=="globalFrame")return s.value.globalFrame;
    if(key=="renderedFrames")return s.value.renderedFrames;
    if(key=="tempoApplied")return s.value.tempoApplied;
    if(key=="tempoTerminal")return s.value.tempoTerminal;
    if(key=="tempoRefused")return s.refused;
    if(key=="tempoHistorySegments")return s.history;
    if(key=="durationFrames")return s.value.durationFrames;
    if(key=="scheduleRevision")return s.revision;
    if(key=="scheduleError")return s.error;
    return field(s.value.decks[0],key);
}
inline double jsonField(const std::string& json,std::string_view key){
    const auto token="\""+std::string(key)+"\":";const auto at=json.find(token);assert(at!=std::string::npos);
    const auto* first=json.c_str()+at+token.size();char* end=nullptr;const auto result=std::strtod(first,&end);assert(end!=first);return result;
}
inline ScheduleObservation observe(soundq::nativeengine::Registry& owner,uint64_t handle){
    ScheduleObservation state;state.owner=&owner;state.handle=handle;
    assert(owner.testScheduleSnapshot(handle,state));
    static uint64_t observations=0;
    if(++observations%256==1){
        const auto json=owner.state(handle);
        for(const auto* key:{"globalFrame","renderedFrames","tempoApplied","tempoTerminal","durationFrames","scheduleRevision"})assert(jsonField(json,key)==field(state,key));
        auto at=json.find("\"decks\":[");assert(at!=std::string::npos);at+=9;
        for(unsigned slot=0;slot<4;++slot){
            const auto end=json.find('}',at);assert(end!=std::string::npos);const auto d=json.substr(at,end-at+1);
            for(const auto* key:{"identity","sourceFrame","tempoGeneration","effectiveBpm","nominalSourceFrame"})assert(jsonField(d,key)==field(deck(state,slot),key));
            at=end+2;
        }
        for(const auto* token:{"\"scheduleBuffering\":false","\"schedulePlaying\":true","\"scheduleEnded\":true"})assert((json.find(token)!=std::string::npos)==(state.find(token)!=std::string::npos));
    }
    return state;
}
inline std::ostream& operator<<(std::ostream& out,const ScheduleObservation& state){return out<<state.owner->state(state.handle);}

#!/usr/bin/env python3
"""Real-core terminal-report regression with complete extracted service methods.

Synthetic loopback metadata/bytes and OS/decoder facades only; not Android runtime
or audible playback evidence. Build the unchanged core cdylib explicitly before
running, then set SOUNDQ_CORE_LIBRARY and SOUNDQ_REPAIR_EVIDENCE. Dependencies use
test_toolchain discovery/overrides. --source-root replays identical test bytes.
"""
from pathlib import Path
import argparse
import ast
import ctypes
import hashlib
import json
import os
import subprocess
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import repair_support as p
import native_review_regressions as probes
from test_toolchain import java_home, kotlin_compiler, gson_jar

CASES = r'''
fun visible(snapshot:JSONObject,error:String?):String {
// MainActivity.kt:113-114 status selection, unchanged semantics; no Android rendering claim.
return (error ?: snapshot.optString("error").takeUnless {it=="null" || it.isBlank()})?.replace('_',' ')
 ?: "${snapshot.optJSONArray("library")?.length() ?: 0} of ${snapshot.optLong("total")} tracks · ${snapshot.optString("transport")}"
}
class Observed(val service:PlaybackService,val errors:MutableList<String>,val publications:MutableList<String>)
fun ready():Observed {
 wire("/reset");events.clear();val a=PlaybackService();val errors=mutableListOf<String>();val publications=mutableListOf<String>()
 a.listener={s,code->if(code!=null)errors.add(code);publications.add(visible(s,code))}
 a.command(JSONObject().put("command","restore").put("access_token","synthetic-access").put("refresh_token","synthetic-refresh").put("account_id","synthetic-account"));a.drain()
 a.command(JSONObject().put("command","library").put("offset",0).put("query","").put("sort","title").put("order","asc"));a.drain()
 a.select(1);a.drain();val p=a.player!!;p.prepared!!(p);a.drain()
 check(a.snapshot.optString("transport")=="playing" && a.foreground && a.focusHeld && a.wantsPlayback && p.isPlaying && errors.isEmpty())
 check(a.snapshot.optJSONArray("queue")!!.length()==1 && a.snapshot.optLong("selected_occurrence")>0)
 return Observed(a,errors,publications)
}
fun eof(a:PlaybackService) {val p=a.player!!;check(p.isPlaying);p.currentPosition=p.duration;p.isPlaying=false;p.completion!!(p);a.drain()}
fun released(a:PlaybackService){check(a.snapshot.optString("transport")=="ended" && !a.foreground && !a.focusHeld && !a.wantsPlayback && a.player?.isPlaying!=true)}
fun report(a:PlaybackService,state:String,session:Long=a.snapshot.optLong("session"))=JSONObject().put("command","audio_report").put("epoch",a.epoch).put("session",session).put("state",state).put("position_ms",30000L).put("duration_ms",30000L)
fun main(){
 var failures=0;val names=mutableListOf<String>()
 fun test(name:String,body:()->Unit){try{body();println("PASS $name");names.add(name)}catch(t:Throwable){failures++;println("FAIL $name ${t.message}");t.printStackTrace()}}
 for(rep in 1..3) test("ordinary-current-EOF-no-retired-callback-then-repeat-tick-$rep"){
  val o=ready();val a=o.service;val session=a.snapshot.optLong("session");val selected=a.snapshot.optLong("selected_occurrence");val p=a.player!!
  eof(a);released(a)
  val first=a.bridge.replies.last();check(first.optBoolean("ok") && first.optString("code")=="ok" && first.optJSONObject("audio")==null)
  check(a.nativeTerminalState=="ended" && a.player===p && !p.released && a.playerReady && !a.pendingReports && a.busy==0)
  check(o.errors.isEmpty() && first.optJSONObject("snapshot")!!.optString("error")=="" && !o.publications.last().contains("stale"))
  val calls=a.bridge.calls.size;p.completion!!(p);a.drain();check(a.bridge.calls.size==calls){"duplicate physical callback was not fenced"}
  repeat(4){a.tick();a.drain();released(a)}
  check(a.bridge.calls.size==calls){"acknowledged final EOF was resubmitted"}
  check(a.snapshot.optLong("selected_occurrence")==selected && a.snapshot.optLong("session")==session && a.snapshot.optString("error")=="")
  check(o.errors.isEmpty() && !a.pendingReports && a.busy==0)

 }
 test("ordinary-final-EOF-stays-clean-without-a-subsequent-report"){
  val o=ready();eof(o.service);released(o.service);check(o.errors.isEmpty() && o.service.snapshot.optString("error")=="")
 }
 test("nonfinal-EOF-continues-once-retired-completion-ignored-new-player-report-valid"){
  val o=ready();val a=o.service;val old=a.player!!;val retained=old.completion!!
  a.queueAction("queue_append",1L);a.drain();val next=a.snapshot.optJSONArray("queue")!!.getJSONObject(1).getLong("id");val admissions=events.count{it=="foreground-admission"}
  eof(a);val p=a.player!!;check(p!==old && old.released && a.nativeTerminalState==null);p.prepared!!(p);a.drain()
  check(a.snapshot.optLong("selected_occurrence")==next && p.isPlaying && a.foreground && a.focusHeld && a.wantsPlayback && events.count{it=="foreground-admission"}==admissions)
  val calls=a.bridge.calls.size;retained(old);a.drain();check(a.bridge.calls.size==calls && o.errors.isEmpty());a.tick();a.drain();check(a.bridge.replies.last().optBoolean("ok") && o.errors.isEmpty())
 }
 test("selected-removal-retained-actual-closure-identity-guard-then-current-EOF"){
  val o=ready();val a=o.service;a.queueAction("queue_append",1L);a.drain();val removed=a.snapshot.optLong("selected_occurrence");val old=a.player!!;val complete=old.completion!!
  a.queueAction("queue_remove",removed);a.drain();val p=a.player!!;p.prepared!!(p);a.drain();check(p!==old && old.released)
  val calls=a.bridge.calls.size;val session=a.snapshot.optLong("session");complete(old);a.drain()
  check(a.bridge.calls.size==calls && o.errors.isEmpty() && p.isPlaying && a.snapshot.optLong("session")==session && a.nativeTerminalState==null)
  eof(a);released(a);check(o.errors.isEmpty());val endedCalls=a.bridge.calls.size;repeat(3){a.tick();a.drain()};check(a.bridge.calls.size==endedCalls && o.errors.isEmpty() && a.snapshot.optString("error")=="")
 }
 test("ordinary-Pause-repeated-paused-tick-and-explicit-Resume-positive-control"){
  val o=ready();val a=o.service;val p=a.player!!
  a.command(JSONObject().put("command","pause"));check(!a.foreground && !a.focusHeld && !a.wantsPlayback && !p.isPlaying);a.drain()
  repeat(2){a.tick();a.drain();check(a.snapshot.optString("transport")=="paused" && a.bridge.replies.last().optBoolean("ok"))}
  a.command(JSONObject().put("command","resume"));a.drain();check(a.player===p && p.isPlaying && a.foreground && a.focusHeld && a.nativeTerminalState==null && a.snapshot.optString("transport")=="playing" && o.errors.isEmpty())
 }
 test("genuine-native-failure-publishes-and-repeat-failed-is-not-stale-then-Retry"){
  val o=ready();val a=o.service;val p=a.player!!;check(p.error!!(p,1,1));a.drain()
  check(a.nativeTerminalState=="failed" && a.snapshot.optString("transport")=="failed" && a.snapshot.optString("error")=="native_playback_failed" && !a.foreground && !a.focusHeld && !a.wantsPlayback && !p.isPlaying)
  check(o.publications.last()=="native playback failed")
  repeat(2){a.tick();a.drain();check(a.bridge.replies.last().optBoolean("ok") && a.bridge.calls.last().optString("state")=="failed")}
  check("stale_audio_report" !in o.errors)
  a.command(JSONObject().put("command","retry"));a.drain();val next=a.player!!;check(next!==p && p.released);next.prepared!!(next);a.drain()
  check(next.isPlaying && a.foreground && a.focusHeld && a.nativeTerminalState==null && a.snapshot.optString("transport")=="playing")
 }
 test("Pause-cancels-completion-closure-but-forged-delayed-ended-is-correctly-rejected"){
  val o=ready();val a=o.service;val p=a.player!!;val complete=p.completion!!
  a.command(JSONObject().put("command","pause"));a.drain();val calls=a.bridge.calls.size;complete(p);a.drain();check(a.bridge.calls.size==calls && o.errors.isEmpty())
  a.command(report(a,"ended"));a.drain();check(a.bridge.replies.last().optString("code")=="stale_audio_report" && a.snapshot.optString("transport")=="paused" && !a.foreground && !a.focusHeld)
  a.command(JSONObject().put("command","resume"));a.drain();eof(a);released(a);val n=a.bridge.calls.size;repeat(3){a.tick();a.drain()};check(a.bridge.calls.size==n && o.errors==listOf("stale_audio_report"))
 }
 test("old-session-wire-report-is-correctly-rejected-with-current-owner-preserved"){
  val o=ready();val a=o.service;val old=a.snapshot.optLong("session");a.command(JSONObject().put("command","retry"));a.drain();val p=a.player!!;p.prepared!!(p);a.drain()
  check(a.snapshot.optLong("session")!=old);a.command(report(a,"playing",old));a.drain()
  check(a.bridge.replies.last().optString("code")=="stale_audio_report" && a.snapshot.optString("transport")=="playing" && p.isPlaying && a.foreground && a.focusHeld)
 }
 test("held-current-EOF-report-cancelled-by-new-selection-does-not-publish-stale"){
  val o=ready();val a=o.service;val p=a.player!!;p.isPlaying=false;p.currentPosition=p.duration;p.completion!!(p);check(a.pendingReports)
  a.select(1);a.drain();val next=a.player!!;next.prepared!!(next);a.drain()
  check(p.released && next!==p && next.isPlaying && a.foreground && a.focusHeld && !a.pendingReports && a.busy==0 && o.errors.isEmpty())
  check(a.bridge.replies.any{it.optString("code")=="cancelled"})
  eof(a);released(a);val calls=a.bridge.calls.size;repeat(3){a.tick();a.drain()};check(a.bridge.calls.size==calls && o.errors.isEmpty())
 }
 test("ended-Seek-resets-native-terminal-without-replay-paused-observation-valid"){
  val o=ready();val a=o.service;eof(a);released(a);a.command(JSONObject().put("command","seek").put("position_ms",700L));a.drain()
  check(a.nativeTerminalState==null && a.player!!.currentPosition==700 && !a.player!!.isPlaying && !a.foreground && !a.wantsPlayback)
  a.player!!.seek!!(a.player!!);a.drain();check(a.snapshot.optString("transport")=="paused" && a.snapshot.optLong("position_ms")==700L && o.errors.isEmpty())
 }
 test("explicit-Resume-after-clean-ended-positive-control"){
  val o=ready();val a=o.service;eof(a);released(a);a.command(JSONObject().put("command","resume"));a.drain()
  check(a.player!!.isPlaying && a.foreground && a.focusHeld && a.nativeTerminalState==null && a.snapshot.optString("transport")=="playing" && o.errors.isEmpty())
 }

 test("busy-deferred-EOF-not-consumed-until-delivery"){
  val o=ready();val a=o.service;val calls=a.bridge.calls.size
  a.command(JSONObject().put("command","snapshot"));val p=a.player!!;p.currentPosition=p.duration;p.isPlaying=false;p.completion!!(p)
  check(a.nativeTerminalState=="ended" && !a.pendingReports && a.bridge.calls.size==calls)
  a.drain();check(a.snapshot.optString("transport")=="playing");a.tick();a.drain();released(a)
  val n=a.bridge.calls.count{it.optString("state")=="ended"};check(n==1);repeat(3){a.tick();a.drain()};check(a.bridge.calls.count{it.optString("state")=="ended"}==n && o.errors.isEmpty())
 }
 test("pending-playing-report-defers-EOF-until-next-tick"){
  val o=ready();val a=o.service;a.tick();check(a.pendingReports);val p=a.player!!;p.currentPosition=p.duration;p.isPlaying=false;p.completion!!(p)
  a.drain();check(!a.pendingReports && a.nativeTerminalState=="ended");a.tick();a.drain();released(a)
  val n=a.bridge.calls.size;repeat(3){a.tick();a.drain()};check(a.bridge.calls.size==n && o.errors.isEmpty())
 }
 test("binding-refusal-does-not-consume-terminal-delivery"){
  val o=ready();val a=o.service;a.bridge.refuseOnce=true;eof(a)
  check(o.errors==listOf("binding_failure") && !a.pendingReports && a.nativeTerminalState=="ended" && a.snapshot.optString("transport")=="playing")
  a.tick();a.drain();released(a);check(a.bridge.replies.last().optBoolean("ok"))
  val n=a.bridge.calls.size;repeat(3){a.tick();a.drain()};check(a.bridge.calls.size==n && "stale_audio_report" !in o.errors)
 }
 test("held-main-EOF-new-selection-rejects-old-publication-cleans-pending"){
  val o=ready();val a=o.service;val p=a.player!!;p.currentPosition=p.duration;p.isPlaying=false;p.completion!!(p);a.worker.one()
  check(a.pendingReports && a.bridge.replies.last().optBoolean("ok"));a.select(1);a.drain();val next=a.player!!;next.prepared!!(next);a.drain()
  check(next!==p && next.isPlaying && !a.pendingReports && o.errors.isEmpty());eof(a);released(a);val n=a.bridge.calls.size;a.tick();a.drain();check(a.bridge.calls.size==n && o.errors.isEmpty())
 }
 for(kind in listOf("resume","seek","retry","select","restore")) test("EOF-listener-new-$kind-lifetime-not-consumed-or-retired"){
  val o=ready();val a=o.service;val oldSession=a.snapshot.optLong("session");var once=true
  a.listener={s,code->if(code!=null)o.errors.add(code);o.publications.add(visible(s,code));if(once && s.optString("transport")=="ended"){once=false;when(kind){"select"->a.select(1);"seek"->a.command(JSONObject().put("command","seek").put("position_ms",700L));"restore"->a.command(JSONObject().put("command","restore").put("access_token","synthetic-access").put("refresh_token","synthetic-refresh").put("account_id","synthetic-account"));else->a.command(JSONObject().put("command",kind))}}}
  eof(a);check(!once && !a.pendingReports && a.busy==0 && o.errors.isEmpty())
  if(kind=="restore"){check(!a.foreground && !a.wantsPlayback && a.nativeTerminalState==null);a.command(JSONObject().put("command","library").put("offset",0).put("query","").put("sort","title").put("order","asc"));a.drain();a.select(1);a.drain()}
  if(kind=="seek"){check(a.player!!.currentPosition==700 && a.nativeTerminalState==null && !a.foreground && !a.wantsPlayback);a.player!!.seek!!(a.player!!);a.drain();check(o.errors.isEmpty());a.command(JSONObject().put("command","resume"));a.drain()}
  if(!a.player!!.isPlaying){a.player!!.prepared!!(a.player!!);a.drain()}
  check(a.player!!.isPlaying && a.foreground && a.wantsPlayback)
  if(kind in listOf("resume","seek"))check(a.snapshot.optLong("session")==oldSession)
  val ended=a.bridge.calls.count{it.optString("state")=="ended"};eof(a);released(a);check(a.bridge.calls.count{it.optString("state")=="ended"}==ended+1)
  val n=a.bridge.calls.size;repeat(3){a.tick();a.drain()};check(a.bridge.calls.size==n && o.errors.isEmpty())
 }
 test("ended-Seek-Resume-same-session-delivers-fresh-EOF-once"){
  val o=ready();val a=o.service;eof(a);val session=a.snapshot.optLong("session")
  a.command(JSONObject().put("command","seek").put("position_ms",700L));a.drain();a.player!!.seek!!(a.player!!);a.drain();a.command(JSONObject().put("command","resume"));a.drain()
  check(a.snapshot.optLong("session")==session);eof(a);released(a);val n=a.bridge.calls.size;repeat(3){a.tick();a.drain()};check(a.bridge.calls.size==n && o.errors.isEmpty())
 }
 test("terminal-storage-failure-remains-visible-without-false-stale-diagnostic"){
  val o=ready();val a=o.service;wire("/corrupt");eof(a);released(a)
  check(a.bridge.replies.last().optString("code")=="invalid_saved_queue" && a.snapshot.optString("error")=="invalid_saved_queue" && o.errors==listOf("invalid_saved_queue"))
  val n=a.bridge.calls.size;repeat(3){a.tick();a.drain()};check(a.bridge.calls.size==n && a.snapshot.optString("error")=="invalid_saved_queue" && o.errors==listOf("invalid_saved_queue"));wire("/assert-corrupt")
 }
 test("held-main-EOF-replaced-by-same-session-resume-delivers-new-EOF"){
  val o=ready();val a=o.service;val p=a.player!!;val session=a.snapshot.optLong("session");p.currentPosition=p.duration;p.isPlaying=false;p.completion!!(p);a.worker.one()
  a.command(JSONObject().put("command","resume"));a.drain();check(a.snapshot.optLong("session")==session && p.isPlaying && a.foreground && a.wantsPlayback && !a.pendingReports && a.nativeTerminalState==null)
  eof(a);released(a);val n=a.bridge.calls.size;repeat(3){a.tick();a.drain()};check(a.bridge.calls.size==n && o.errors.isEmpty())
 }
 test("rejected-seek-preserves-acknowledged-EOF-and-real-error"){
  val o=ready();val a=o.service;eof(a);a.command(JSONObject().put("command","seek").put("position_ms",40000L));a.drain()
  check(a.bridge.replies.last().optString("code")=="invalid_seek" && a.nativeTerminalState=="ended" && a.snapshot.optString("transport")=="ended")
  val n=a.bridge.calls.size;repeat(3){a.tick();a.drain()};check(a.bridge.calls.size==n && o.errors==listOf("invalid_seek") && a.snapshot.optString("error")=="invalid_seek")
 }
 for(schedule in listOf("busy","worker","main","listener")) test("explicit-Pause-cancels-EOF-observation-$schedule"){
  val o=ready();val a=o.service;val p=a.player!!;var once=true
  if(schedule=="listener")a.listener={s,code->if(code!=null)o.errors.add(code);if(once && s.optString("transport")=="ended"){once=false;a.command(JSONObject().put("command","pause"))}}
  if(schedule=="busy")a.command(JSONObject().put("command","snapshot"))
  p.currentPosition=p.duration;p.isPlaying=false;p.completion!!(p)
  if(schedule=="main")a.worker.one()
  if(schedule!="listener")a.command(JSONObject().put("command","pause"))
  a.drain();repeat(3){a.tick();a.drain()}
  check(a.snapshot.optString("transport")=="paused" && o.errors.isEmpty() && !a.pendingReports && !a.foreground && !a.wantsPlayback)
  a.command(JSONObject().put("command","resume"));a.drain();eof(a);released(a);val n=a.bridge.calls.size;repeat(3){a.tick();a.drain()};check(a.bridge.calls.size==n && o.errors.isEmpty())
 }
 for(valid in listOf(true,false)) test("held-main-EOF-seek-preserves-observation-until-effect-$valid"){
  val o=ready();val a=o.service;val p=a.player!!;p.currentPosition=p.duration;p.isPlaying=false;p.completion!!(p);a.worker.one()
  a.command(JSONObject().put("command","seek").put("position_ms",if(valid)700L else 40000L));a.drain()
  check(!a.foreground && !a.wantsPlayback && !a.pendingReports)
  if(valid){check(a.nativeTerminalState==null && p.currentPosition==700);p.seek!!(p);a.drain();check(a.snapshot.optString("transport")=="paused" && o.errors.isEmpty())}
  else {check(a.nativeTerminalState=="ended" && o.errors==listOf("invalid_seek"));val n=a.bridge.calls.size;repeat(3){a.tick();a.drain()};check(a.bridge.calls.size==n && a.snapshot.optString("error")=="invalid_seek")}
  a.command(JSONObject().put("command","resume"));a.drain();eof(a);released(a);val n=a.bridge.calls.size;repeat(3){a.tick();a.drain()};check(a.bridge.calls.size==n && "stale_audio_report" !in o.errors)
 }
 // A successful nonfinal EOF replaces the decoder lifetime, even if transport
 // intent changes before its main delivery. Never infer identity from transport.
 for(schedule in listOf("worker","main","listener")) for(kind in listOf("pause","resume")) test("nonfinal-EOF-$schedule-new-$kind-keeps-successor-decoder"){
  val o=ready();val a=o.service;val old=a.player!!;val oldSession=a.snapshot.optLong("session")
  val prepared=old.prepared!!;val complete=old.completion!!;val seek=old.seek!!;val error=old.error!!
  a.queueAction("queue_append",1L);a.drain();val target=a.snapshot.optJSONArray("queue")!!.getJSONObject(1).getLong("id")
  var invoked=false
  if(schedule=="listener")a.listener={s,code->if(code!=null)o.errors.add(code);if(!invoked && s.optLong("selected_occurrence")==target){invoked=true;a.command(JSONObject().put("command",kind))}}
  old.currentPosition=old.duration;old.isPlaying=false;complete(old);check(a.pendingReports && a.nativeTerminalState=="ended")
  if(schedule=="main"){
   a.worker.one();val accepted=a.bridge.replies.last();val next=accepted.optJSONObject("snapshot")!!;val load=accepted.optJSONObject("audio")!!
   check(accepted.optBoolean("ok") && next.optLong("selected_occurrence")==target && next.optLong("session")!=oldSession && next.optString("transport")=="preparing")
   check(load.optString("action")=="load" && load.optLong("session")==next.optLong("session") && load.optLong("epoch")==a.epoch && load.optString("path").isNotEmpty())
   check(a.player===old && !old.released && !old.isPlaying)
  }
  if(schedule!="listener"){a.command(JSONObject().put("command",kind));invoked=true}
  if(schedule!="main")a.worker.one()
  a.main.one();val next=a.player!!;val successor=a.snapshot.optLong("session")
  check(next!==old && old.released){"accepted continuation load discarded; completed decoder retained under successor session"}
  check(invoked && a.snapshot.optLong("selected_occurrence")==target && successor!=oldSession)
  check(old.prepared==null && old.completion==null && old.seek==null && old.error==null && !old.isPlaying)
  check(!a.playerReady && !next.isPlaying && a.snapshot.optString("transport")=="preparing" && !a.focusHeld && a.foreground==(kind=="resume") && a.wantsPlayback==(kind=="resume"))
  a.drain();check(!next.isPlaying && !a.playerReady && a.snapshot.optString("transport")==if(kind=="pause")"paused" else "preparing")
  next.prepared!!(next);a.drain()
  check(a.player===next && a.playerReady && next.isPlaying==(kind=="resume") && a.wantsPlayback==(kind=="resume") && a.foreground==(kind=="resume") && a.focusHeld==(kind=="resume"))
  check(a.snapshot.optString("transport")==if(kind=="pause")"paused" else "playing")
  val calls=a.bridge.calls.size;val terminal=a.nativeTerminalState;val position=a.snapshot.optLong("position_ms")
  prepared(old);seek(old);error(old,1,1);complete(old);a.drain()
  check(a.bridge.calls.size==calls && a.player===next && a.snapshot.optLong("session")==successor && a.snapshot.optLong("position_ms")==position && a.nativeTerminalState==terminal)
  next.currentPosition=700;next.seek!!(next);a.drain();check(a.bridge.calls.last().optLong("session")==successor && a.snapshot.optLong("position_ms")==700L && a.bridge.replies.last().optBoolean("ok"))
  if(kind=="pause"){a.command(JSONObject().put("command","resume"));a.drain()}
  check(next.isPlaying && a.player===next);eof(a);released(a)
  check(a.bridge.calls.last().optLong("session")==successor && o.errors.isEmpty() && !a.pendingReports && a.busy==0)
 }
 for(schedule in listOf("main","listener")) for(kind in listOf("select","restore")) test("nonfinal-EOF-$schedule-replacement-$kind-retires-accepted-load"){
  val o=ready();val a=o.service;val old=a.player!!;a.queueAction("queue_append",1L);a.drain();val target=a.snapshot.optJSONArray("queue")!!.getJSONObject(1).getLong("id");var invoked=false
  fun replace(){invoked=true;if(kind=="select")a.select(1) else a.command(JSONObject().put("command","restore").put("access_token","synthetic-access").put("refresh_token","synthetic-refresh").put("account_id","synthetic-account"))}
  if(schedule=="listener")a.listener={s,code->if(code!=null)o.errors.add(code);if(!invoked && s.optLong("selected_occurrence")==target)replace()}
  old.currentPosition=old.duration;old.isPlaying=false;old.completion!!(old)
  if(schedule=="main"){a.worker.one();check(a.bridge.replies.last().optJSONObject("audio")!!.optString("action")=="load");replace()}
  if(schedule=="listener")a.worker.one()
  val releases=events.count{it=="release"};a.main.one();check(invoked && a.player===(if(kind=="select")null else old) && events.count{it=="release"}==releases+(if(schedule=="listener" && kind=="select")1 else 0))
  a.drain()
  if(kind=="select"){val p=a.player!!;check(p!==old && old.released && a.snapshot.optLong("selected_occurrence")!=target);p.prepared!!(p);a.drain();check(p.isPlaying && a.foreground && a.focusHeld)}
  else check(a.player===old && !old.isPlaying && !a.wantsPlayback && !a.foreground && !a.focusHeld)
  check(o.errors.isEmpty() && !a.pendingReports && a.busy==0)
 }
 for(schedule in listOf("main","listener")) for(kind in listOf("native-error","notification-refusal")) if(schedule=="main" || kind!="native-error") test("nonfinal-EOF-$schedule-current-$kind-survives-load"){
  val o=ready();val a=o.service;val old=a.player!!;a.queueAction("queue_append",1L);a.drain();val target=a.snapshot.optJSONArray("queue")!!.getJSONObject(1).getLong("id");var invoked=false
  fun fail(){invoked=true;if(kind=="native-error")old.error!!(old,1,1) else {a.denyNotification=true;a.command(JSONObject().put("command","resume"));a.denyNotification=false}}
  if(schedule=="listener")a.listener={s,code->if(code!=null)o.errors.add(code);if(!invoked && s.optLong("selected_occurrence")==target)fail()}
  old.currentPosition=old.duration;old.isPlaying=false;old.completion!!(old)
  if(schedule=="main"){a.worker.one();check(a.bridge.replies.last().optJSONObject("audio")!!.optString("action")=="load");fail()}
  a.drain();a.player!!.prepared!!(a.player!!);a.drain();a.tick();a.drain()
  check(invoked && a.nativeTerminalState=="failed" && a.snapshot.optString("transport")=="failed" && a.snapshot.optString("error")=="native_playback_failed" && a.bridge.calls.last().optString("state")=="failed")
  check(!a.wantsPlayback && !a.foreground && !a.focusHeld && !a.player!!.isPlaying && o.publications.isNotEmpty() && !a.pendingReports && a.busy==0)
 }
 test("nonfinal-current-binding-refusal-visible-without-invented-successor-load"){
  val o=ready();val a=o.service;val old=a.player!!;a.queueAction("queue_append",1L);a.drain();val session=a.snapshot.optLong("session")
  a.bridge.refuseOnce=true;eof(a);check(o.errors==listOf("binding_failure") && a.player===old && !old.released && a.snapshot.optLong("session")==session && !a.pendingReports)
  a.command(JSONObject().put("command","retry"));a.drain();val next=a.player!!;check(next!==old && old.released);next.prepared!!(next);a.drain();check(next.isPlaying && a.wantsPlayback && a.foreground && a.focusHeld && a.snapshot.optString("transport")=="playing" && o.errors==listOf("binding_failure"))
 }
 println("SUMMARY passed=${names.size} failed=$failures")
 check(failures==0){"$failures bounded causal controls failed"}
}
'''



def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-root', type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    root, out = args.source_root.resolve(), args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()
    def save(name, value): (out/name).write_text(json.dumps(value, indent=2)+'\n')
    p.C.sq_core_abi_version.restype = ctypes.c_uint32
    assert p.C.sq_core_abi_version() == 1
    harness = probes.android_probe(root, probes.swift_block)
    facade = next(node.value for node in ast.walk(ast.parse((root/'native/tests/queue_storage_composition.py').read_text()))
                  if isinstance(node, ast.Constant) and isinstance(node.value, str) and node.value.startswith('class JSONObject {\nval data:com.google.gson.JsonObject'))
    a, b = harness.index('class JSONObject {'), harness.index('class Queue ')
    harness = harness[:a]+facade+harness[b:]
    a, b = harness.index('class Bridge {'), harness.index('class PlaybackService {')
    harness = harness[:a]+'''fun wire(route:String,body:String="{}"):String {
val c=java.net.URI(System.getenv("SOUNDQ_TERMINAL_RELAY")+route).toURL().openConnection() as java.net.HttpURLConnection
c.requestMethod="POST";c.doOutput=true;c.connectTimeout=3000;c.readTimeout=10000
try {c.outputStream.use{it.write(body.toByteArray())};return c.inputStream.bufferedReader().use{it.readText()}} finally {c.disconnect()}
}
class Bridge {val calls=mutableListOf<JSONObject>();val replies=mutableListOf<JSONObject>();var refuseOnce=false
fun revoke(c:Long):Long=wire("/revoke").toLong()
fun execute(c:Long,e:Long,raw:String):String{calls.add(JSONObject(raw));if(refuseOnce){refuseOnce=false;throw IllegalStateException("synthetic binding refusal before ABI")};val r=wire("/execute",JSONObject().put("epoch",e).put("command",JSONObject(raw)).toString());replies.add(JSONObject(r));return r}
}
'''+harness[b:]
    harness = harness.replace('class Session {val sessionToken=1}', '''class PlaybackState {class Builder {fun setActions(a:Long)=this;fun setState(a:Int,b:Long,c:Float)=this;fun build()=PlaybackState()};companion object {const val STATE_PLAYING=3;const val STATE_BUFFERING=6;const val STATE_ERROR=7;const val STATE_PAUSED=2;const val ACTION_PLAY=1L;const val ACTION_PAUSE=2L;const val ACTION_PLAY_PAUSE=4L;const val ACTION_SEEK_TO=8L;const val ACTION_SKIP_TO_NEXT=16L;const val ACTION_SKIP_TO_PREVIOUS=32L}}
class MediaMetadata {class Builder {fun putString(a:String,b:String)=this;fun putLong(a:String,b:Long)=this;fun build()=MediaMetadata()};companion object{const val METADATA_KEY_TITLE="title";const val METADATA_KEY_ARTIST="artist";const val METADATA_KEY_DURATION="duration"}}
class Session {val sessionToken=1;fun setPlaybackState(p:PlaybackState){};fun setMetadata(m:MediaMetadata){}}''')
    service = root/'native/android/app/src/main/java/com/soundq/nativepreview/PlaybackService.kt'
    harness = harness.replace('fun updateSession(){}', probes.swift_block(service.read_text(), 'private fun updateSession('))
    harness = harness[:harness.index('fun main(){')]+CASES
    kt, jar = out/'TerminalProbe.kt', out/'probe.jar'
    kt.write_text(harness)
    commands = []
    def run(name, argv, extra=None):
        env = dict(os.environ, JAVA_HOME=str(java_home()), JAVA_TOOL_OPTIONS='-XX:ActiveProcessorCount=2', **(extra or {}))
        result = subprocess.run([str(x) for x in argv], cwd=out, env=env, capture_output=True, timeout=180)
        (out/(name+'.stdout')).write_bytes(result.stdout); (out/(name+'.stderr')).write_bytes(result.stderr)
        commands.append(dict(name=name, argv=[str(x) for x in argv], cwd=str(out), exitCode=result.returncode,
                             stdoutSha256=sha(out/(name+'.stdout')), stderrSha256=sha(out/(name+'.stderr'))))
        save('commands.json', commands)
        print(name, 'exit', result.returncode, flush=True)
        if name == 'behavior': print(result.stdout.decode(), end='')
        return result.returncode
    compiled = run('compile', [kotlin_compiler(), kt, '-classpath', gson_jar(), '-nowarn', '-include-runtime', '-d', jar])
    if compiled: raise RuntimeError('terminal probe compilation failed; not semantic RED')
    trace, core, case_no = [], None, 0
    with p.Server() as server:
        class Relay(BaseHTTPRequestHandler):
            def log_message(self, format, *args): pass
            def do_POST(self):
                nonlocal core, case_no
                raw = self.rfile.read(int(self.headers.get('Content-Length', 0)))
                try:
                    if self.path == '/reset':
                        if core is not None: p.C.sq_core_close(core)
                        case_no += 1; core = p.new_core(server, out/'cache'/str(case_no)); body = b'{}'
                    elif self.path == '/revoke': body = str(p.C.sq_core_revoke(core)).encode()
                    elif self.path == '/execute':
                        v = json.loads(raw); reply = p.take(p.C.sq_core_execute(core, v['epoch'], json.dumps(v['command']).encode()))
                        trace.append(dict(case=case_no, request=v, reply=reply)); body = json.dumps(reply).encode()
                    elif self.path in ('/corrupt', '/assert-corrupt'):
                        path = next((out/'cache'/str(case_no)).rglob('listening-queue-v1.json'))
                        if self.path == '/corrupt': path.write_bytes(b'{broken')
                        else: assert path.read_bytes() == b'{broken'
                        body = b'{}'
                    else: raise AssertionError(self.path)
                    self.send_response(200); self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)
                except BaseException as exc:
                    trace.append(dict(error=repr(exc))); self.send_error(500)
        relay = ThreadingHTTPServer(('127.0.0.1', 0), Relay)
        thread = threading.Thread(target=relay.serve_forever); thread.start()
        try:
            behavior = run('behavior', [java_home()/'bin/java', '-cp', str(jar)+os.pathsep+str(gson_jar()), 'TerminalProbeKt'],
                           dict(SOUNDQ_TERMINAL_RELAY=f'http://127.0.0.1:{relay.server_port}'))
        finally:
            relay.shutdown(); relay.server_close(); thread.join(3)
            if core is not None: p.C.sq_core_close(core)
            save('abi-trace.json', trace)
        counts = dict(cases=case_no, descriptors=server.descriptors, downloads=server.downloads, libraries=server.libraries)
    cleanup = dict(allCoreHandlesClosed=True, relayThreadAlive=thread.is_alive(), backendThreadAlive=server.thread.is_alive(),
                   relaySocketFileno=relay.socket.fileno(), backendSocketFileno=server.http.socket.fileno())
    assert not thread.is_alive() and not server.thread.is_alive() and relay.socket.fileno()==server.http.socket.fileno()==-1
    assert server.descriptors == server.downloads == case_no and server.libraries == case_no+1
    lines = (out/'behavior.stdout').read_text().splitlines()
    names = [line[5:] for line in lines if line.startswith('PASS ')]
    failures = [line[5:] for line in lines if line.startswith('FAIL ')]
    assert len(names)==len(set(names)) and len(names)+len(failures)==46
    save('receipt.json', dict(compileExit=compiled, runExit=behavior, passNames=names, failures=failures,
                             testSha256=sha(Path(__file__)), productionSha256=sha(service), librarySha256=sha(p.LIB),
                             syntheticNetwork=counts, cleanup=cleanup, abi=1))
    raise SystemExit(behavior)


if __name__ == '__main__':
    main()

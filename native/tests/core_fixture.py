#!/usr/bin/env python3
"""Actual production Go handler -> Rust C ABI integration, fixture only.

Never prints credentials, signed URLs, paths from private effects or raw replies.
The fixture home must have been created by cmd/native-fixture in an owned DB.
"""
import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import statistics
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]

def main():
    p = argparse.ArgumentParser()
    p.add_argument("--fixture-home", required=True, type=Path)
    p.add_argument("--evidence", required=True, type=Path)
    args = p.parse_args()
    private = json.loads((args.fixture_home/"credentials.json").read_text())
    library = ROOT/"native/core/target/release/libsoundq_core.dylib"
    core = ctypes.CDLL(str(library))
    core.sq_core_open.argtypes = [ctypes.c_char_p, ctypes.c_char_p]
    core.sq_core_open.restype = ctypes.c_uint64
    core.sq_core_execute.argtypes = [ctypes.c_uint64, ctypes.c_uint64, ctypes.c_char_p]
    core.sq_core_execute.restype = ctypes.c_void_p
    core.sq_core_string_free.argtypes = [ctypes.c_void_p]
    core.sq_core_revoke.argtypes = [ctypes.c_uint64]
    core.sq_core_revoke.restype = ctypes.c_uint64
    core.sq_core_close.argtypes = [ctypes.c_uint64]
    samples = []
    checks = []
    with tempfile.TemporaryDirectory(prefix="soundq-native-abi-",dir=os.environ.get("TMPDIR")) as cache:
        handle = core.sq_core_open(b"http://127.0.0.1:54761/api/v1",os.fsencode(cache))
        assert handle
        epoch = 1
        def execute(command, expected=None):
            started = time.perf_counter_ns()
            pointer = core.sq_core_execute(handle,epoch if expected is None else expected,json.dumps(command).encode())
            assert pointer
            try: result = json.loads(ctypes.string_at(pointer))
            finally: core.sq_core_string_free(pointer)
            samples.append({"command":command["command"],"durationMs":(time.perf_counter_ns()-started)/1e6,"code":result["code"]})
            return result
        def check(name, condition):
            assert condition, name
            checks.append(name)
        try:
            login = execute({"command":"login","email":private["email"],"password":private["password"]})
            check("actual_go_login",login["ok"] and login["snapshot"]["authenticated"])
            page = login
            for offset in range(0,500,50):
                page = execute({"command":"library","offset":offset,"query":"","sort":"title","order":"asc"})
                check(f"page_{offset}",page["ok"] and len(page["snapshot"]["library"])==offset+50 and page["snapshot"]["total"]==500)
            rows = page["snapshot"]["library"]
            check("no_credentials_in_snapshot",not any(k in json.dumps(page["snapshot"]) for k in [private["password"],private["access_token"],private["refresh_token"]]))
            target = rows[0]["id"]
            epoch = core.sq_core_revoke(handle)
            cold = execute({"command":"select","track_id":target})
            check("cold_real_descriptor_download",cold["ok"] and not cold["audio"]["cached"])
            path = Path(cold["audio"]["path"])
            check("container_correct_bytes",path.suffix==".wav" and path.read_bytes()==(args.fixture_home/"fixture.wav").read_bytes())
            first_id = cold["snapshot"]["selected_occurrence"]
            first_session = cold["snapshot"]["session"]
            warm = execute({"command":"select","track_id":target})
            check("warm_shared_policy",warm["ok"] and warm["audio"]["cached"])
            check("repeat_occurrence_identity",warm["snapshot"]["selected_occurrence"]!=first_id)
            old_report = execute({"command":"audio_report","epoch":epoch,"session":first_session,"state":"playing","position_ms":6000,"duration_ms":30000})
            check("stale_native_completion_refused",old_report["code"]=="stale_audio_report")
            paused = execute({"command":"pause"});check("pause_effect",paused["audio"]["action"]=="pause")
            seek = execute({"command":"seek","position_ms":6000});check("seek_effect",seek["audio"]["position_ms"]==6000)
            zero_duration = execute({"command":"audio_report","epoch":epoch,"session":warm["snapshot"]["session"],"state":"paused","position_ms":0,"duration_ms":0})
            after_transient = execute({"command":"seek","position_ms":12000})
            check("transient_native_zero_duration_preserves_seek_bounds",after_transient["ok"] and after_transient["audio"]["position_ms"]==12000)
            old_epoch = epoch;epoch = core.sq_core_revoke(handle)
            queued = execute({"command":"seek","position_ms":6000},old_epoch)
            check("enqueue_owned_intent_refused",queued["code"]=="cancelled" and "audio" not in queued)
            newest = execute({"command":"select","track_id":rows[1]["id"]})
            check("replacement_not_started_at_retired_seek",newest["ok"] and newest["audio"]["position_ms"]==0)
            search = execute({"command":"library","offset":0,"query":"Native Fixture 001","sort":"title","order":"asc"})
            check("actual_go_search",search["ok"] and len(search["snapshot"]["library"])==1)
            empty = execute({"command":"library","offset":0,"query":"nativenevermatches","sort":"title","order":"asc"})
            check("actual_go_empty_list",empty["ok"] and empty["snapshot"]["library"]==[] and empty["snapshot"]["total"]==0)
            epoch=core.sq_core_revoke(handle)
            logout=execute({"command":"logout"})
            check("retirement_clears_truth",logout["ok"] and not logout["snapshot"]["authenticated"] and logout["snapshot"]["queue"]==[] and logout["snapshot"]["library"]==[])
            check("unauthenticated_library_refused",execute({"command":"library","offset":0,"query":"","sort":"title","order":"asc"})["code"]=="unauthenticated")
        finally:
            core.sq_core_close(handle)
    receipt={"status":"passed","kind":"real-Go-handler/Rust-C-ABI integration, not physical output", "librarySha256":hashlib.sha256(library.read_bytes()).hexdigest(),"checks":checks,"samples":samples,"sampleLimits":"Single local synthetic fixture execution; timings include C ABI, Go HTTP/DB and cache hashing, not user-to-sound latency."}
    args.evidence.parent.mkdir(parents=True,exist_ok=True)
    args.evidence.write_text(json.dumps(receipt,indent=2)+"\n")
    print(json.dumps({"status":"passed","checks":len(checks),"evidence":str(args.evidence)}))

if __name__ == "__main__": main()

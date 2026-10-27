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


def liked_filter_journey(execute, check, private, all_rows, cache):
    """Later opt-in owned Go fixture run only; never invoked by preparation.

    Reuse the existing ABI executor and production Go handlers. Independent HTTP
    readback pages at the server's actual bound; no DB writes or server changes.
    """
    import urllib.parse
    import urllib.request

    def page(liked, offset=0, query=""):
        return execute(dict(command="library_liked" if liked else "library",
                            offset=offset, query=query, sort="title", order="asc"))

    def row_ids(reply):
        return [row["id"] for row in reply["snapshot"]["library"]]

    def playback(reply):
        return {key: reply["snapshot"][key] for key in
                ("queue", "selected_occurrence", "session", "epoch", "transport", "position_ms", "duration_ms")}

    def files():
        return {str(path.relative_to(cache)): hashlib.sha256(path.read_bytes()).hexdigest()
                for path in Path(cache).rglob("*") if path.is_file()}

    def go_liked_ids():
        result = []
        expected_total = None
        while expected_total is None or len(result) < expected_total:
            offset = len(result)
            query = urllib.parse.urlencode(dict(limit=50, offset=offset, q="", sort="title", order="asc", liked="true"))
            request = urllib.request.Request("http://127.0.0.1:54761/api/v1/library?" + query,
                                             headers={"Authorization": "Bearer " + private["access_token"]})
            # Keep raw response/headers out of evidence, including on refusal.
            try:
                with urllib.request.urlopen(request, timeout=10) as response:
                    decoded = json.load(response)
            except Exception:
                raise AssertionError("owned loopback Go liked readback failed") from None
            current = decoded["tracks"] or []
            check(f"liked_go_readback_page_{offset}", decoded["offset"] == offset and
                  len(current) <= 50 and all(row["is_liked"] for row in current))
            if expected_total is None:
                expected_total = decoded["total"]
            check(f"liked_go_readback_total_{offset}", decoded["total"] == expected_total)
            check(f"liked_go_readback_progress_{offset}", bool(current) or offset == expected_total)
            result.extend(row["id"] for row in current)
            check(f"liked_go_readback_unique_{offset}", len(result) == len(set(result)) <= expected_total)
        return result

    # Preserve the existing all-500/queue/restart controls above this extension.
    before = execute({"command": "snapshot"})
    baseline_files = files()
    check("liked_fixture_requires_original_all_500_rows", len(all_rows) == 500)
    loaded = before
    for offset in range(0, len(all_rows), 50):
        loaded = page(False, offset)
        check(f"liked_seed_load_all_{offset}", loaded["ok"] and len(row_ids(loaded)) == offset + 50)
    check("liked_seed_load_all_preserves_player", playback(loaded) == playback(before) and files() == baseline_files)
    desired = [row["id"] for row in all_rows[::5]]
    check("liked_seed_more_than_native_page", len(desired) > 50 and any(track not in [r["id"] for r in all_rows[:50]] for track in desired))
    for track in desired:
        ack = execute(dict(command="set_favorite", track_id=track, liked=True))
        check(f"liked_seed_ack_{track}", ack["ok"] and track in ack["snapshot"]["favorite_track_ids"])
    independent = go_liked_ids()
    check("liked_go_exact_seed_membership", independent == desired)
    filtered = page(True)
    check("liked_core_first_page", filtered["ok"] and row_ids(filtered) == independent[:50] and filtered["snapshot"]["total"] == len(independent))
    check("liked_core_first_page_preserves_player", "audio" not in filtered and playback(filtered) == playback(before) and files() == baseline_files)
    for offset in range(50, len(independent), 50):
        filtered = page(True, offset)
        check(f"liked_core_append_{offset}", filtered["ok"] and row_ids(filtered) == independent[:offset + 50])
    check("liked_core_complete_membership", row_ids(filtered) == independent and filtered["snapshot"]["favorite_track_ids"] == independent)
    check("liked_core_pages_preserve_player", "audio" not in filtered and playback(filtered) == playback(before) and files() == baseline_files)
    chosen = execute(dict(command="select", track_id=independent[50]))
    check("liked_select_loaded_second_page", chosen["ok"] and [o["track"]["id"] for o in chosen["snapshot"]["queue"]] == independent)
    selected = chosen["snapshot"]["selected_occurrence"]
    following = execute({"command": "next"})
    check("liked_next_filtered_occurrence", following["ok"] and next(o["track"]["id"] for o in following["snapshot"]["queue"] if o["id"] == following["snapshot"]["selected_occurrence"]) == independent[51])
    previous = execute({"command": "previous"})
    check("liked_previous_original_occurrence", previous["ok"] and previous["snapshot"]["selected_occurrence"] == selected)
    execute(dict(command="audio_report", epoch=previous["snapshot"]["epoch"], session=previous["snapshot"]["session"], state="playing", position_ms=4321, duration_ms=30000))
    playing = execute({"command": "snapshot"})
    playing_files = files()
    needle = next(row["title"] for row in all_rows if row["id"] == independent[50])
    searched = page(True, query=needle)
    check("liked_search_intersection", searched["ok"] and row_ids(searched) == [independent[50]] and searched["snapshot"]["total"] == 1)
    empty = page(True, query="nativenevermatches")
    check("liked_filtered_empty", empty["ok"] and row_ids(empty) == [] and empty["snapshot"]["total"] == 0)
    filtered = page(True)
    ack = execute(dict(command="set_favorite", track_id=independent[0], liked=False))
    check("liked_unlike_retains_fetched_membership_until_refresh", ack["ok"] and row_ids(ack) == row_ids(filtered) and independent[0] not in ack["snapshot"]["favorite_track_ids"])
    check("liked_unlike_go_readback", go_liked_ids() == independent[1:])
    refreshed = page(True)
    check("liked_refresh_removes_unliked", refreshed["ok"] and row_ids(refreshed) == independent[1:51] and refreshed["snapshot"]["total"] == len(independent) - 1)
    all_page = page(False)
    check("liked_return_to_all", all_page["ok"] and row_ids(all_page) == [row["id"] for row in all_rows[:50]] and all_page["snapshot"]["total"] == 500)
    for name, reply in [("search", searched), ("empty", empty), ("refresh", refreshed), ("all", all_page)]:
        check(f"liked_{name}_keeps_playing_owner", "audio" not in reply and playback(reply) == playback(playing))
    check("liked_browse_preserves_saved_queue_and_cache", files() == playing_files)


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
            queue=execute({"command":"snapshot"})["snapshot"]["queue"]
            check("visible_list_selection_retains_whole_list",len(queue)==500)
            occurrence=newest["snapshot"]["selected_occurrence"]
            original_session=newest["snapshot"]["session"]
            duplicate=execute({"command":"queue_append","track_id":target})
            check("queue_append_uses_loaded_track_validation",duplicate["code"]=="track_not_loaded")
            moved=execute({"command":"queue_move","occurrence_id":occurrence,"to_index":0})
            check("occurrence_move_preserves_decoder_session",moved["ok"] and moved["snapshot"]["session"]==original_session and moved["snapshot"]["queue"][0]["id"]==occurrence)
            execute({"command":"seek","position_ms":6000})
            core.sq_core_close(handle)
            handle=core.sq_core_open(b"http://127.0.0.1:54761/api/v1",os.fsencode(cache));epoch=1
            check("core_restart_requires_explicit_account",execute({"command":"queue_restore"})["code"]=="unauthenticated")
            check("restart_real_go_login",execute({"command":"login","email":private["email"],"password":private["password"]})["ok"])
            restored=execute({"command":"queue_restore"})
            check("restart_restores_paused_occurrence_and_cursor",restored["ok"] and restored["snapshot"]["selected_occurrence"]==occurrence and restored["snapshot"]["position_ms"]==6000 and restored["snapshot"]["transport"]=="paused" and len(restored["snapshot"]["queue"])==500)
            resumed=execute({"command":"resume"})
            check("restart_explicit_resume_reuses_verified_bytes",resumed["ok"] and resumed["audio"]["cached"] and resumed["audio"]["position_ms"]==6000)
            liked_filter_journey(execute, check, private, rows, cache)
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

#!/usr/bin/env python3
"""One-CPU host/NDK compile checks. Never opens a device or links a real codec.

Host uses the TEST ONLY deterministic decoder and actual Engine/WorkerDeck/Host.
--ndk additionally builds actual pinned Oboe and JNI with that compile tracer.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import textwrap


def run(args):
    subprocess.run([str(arg) for arg in args], check=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--build", type=Path, required=True)
    parser.add_argument("--ndk", type=Path)
    parser.add_argument("--oboe", type=Path)
    args = parser.parse_args()
    host = Path(__file__).resolve().parents[1]
    repo = host.parents[5]
    build = args.build.resolve()
    run(["cmake", "-S", host, "-B", build / "host", "-DSOUNDQ_CALLBACK_TESTS=ON",
         "-DSOUNDQ_CALLBACK_SANITIZE=ON", "-DCMAKE_BUILD_TYPE=Debug"])
    run(["cmake", "--build", build / "host", "-j1"])
    run(["ctest", "--test-dir", build / "host", "--output-on-failure"])
    state = json.loads(subprocess.check_output([str(build / "host/soundq_callback_host_tests"), "--json"], text=True))
    root_fields = ("error", "sampleRate", "renderedFrames", "xRuns", "callbackOverruns", "pcmPoolBytes")
    assert all(type(state[field]) is int for field in root_fields)
    assert len(state["decks"]) == 4 and state["openDecoders"] == 0
    numeric = ("generation", "identity", "sourceFrame", "sourceRate", "sourceFrames", "positionMs",
               "durationMs", "eofCount", "missingPcmFrames", "error", "openDecoders")
    for deck in state["decks"]:
        assert all(type(deck[field]) in (int, float) for field in numeric)
        assert all(type(deck[field]) is bool for field in ("playing", "ready", "preparing"))
        assert deck["identity"] == 0 and not deck["ready"] and not deck["preparing"]
    print("PASS: parsed exact four-deck JSON field types and empty startup")
    if args.ndk:
        if not args.oboe or not (args.oboe / "include/oboe/Oboe.h").is_file():
            parser.error("--ndk requires --oboe pointing at verified Oboe 1.11.0 source")
        # Scratch-only link tracer. This target is NOT soundq_callback_android and
        # must never be packaged. The shipping target refuses a missing codec.
        tracer = build / "compile-tracer"
        tracer.mkdir(parents=True, exist_ok=True)
        (tracer / "CMakeLists.txt").write_text(textwrap.dedent(f'''\
            cmake_minimum_required(VERSION 3.22.1)
            project(soundq_callback_compile_tracer LANGUAGES C CXX)
            set(CMAKE_CXX_STANDARD 17)
            set(CMAKE_POSITION_INDEPENDENT_CODE ON)
            add_subdirectory("{args.oboe.resolve()}" oboe)
            add_library(soundq_callback_compile_tracer SHARED
              "{host}/jni_bridge.cpp" "{host}/oboe_output.cpp"
              "{host}/callback_host.cpp" "{host}/worker_deck.cpp"
              "{host}/tests/fake_decoder.cpp"
              "{repo}/client/native/transport/src/soundq_transport.cpp")
            target_include_directories(soundq_callback_compile_tracer PRIVATE "{host}"
              "{repo}/client/native/transport/include" "{repo}/client/native/file_decoder/include")
            target_compile_options(soundq_callback_compile_tracer PRIVATE -Wall -Wextra -Wpedantic -Werror)
            target_link_libraries(soundq_callback_compile_tracer PRIVATE oboe android log)
            target_link_options(soundq_callback_compile_tracer PRIVATE "-Wl,--no-undefined" "-Wl,-z,max-page-size=16384")
        '''))
        ndkbuild = build / "ndk-tracer"
        run(["cmake", "-S", tracer, "-B", ndkbuild,
             f"-DCMAKE_TOOLCHAIN_FILE={args.ndk.resolve()}/build/cmake/android.toolchain.cmake",
             "-DANDROID_ABI=arm64-v8a", "-DANDROID_PLATFORM=android-26", "-DCMAKE_BUILD_TYPE=Release"])
        run(["cmake", "--build", ndkbuild, "-j1"])
        prebuilt = args.ndk.resolve() / "toolchains/llvm/prebuilt"
        nm = next(prebuilt.glob("*/bin/llvm-nm"))
        library = ndkbuild / "libsoundq_callback_compile_tracer.so"
        symbols = subprocess.check_output([str(nm), "-D", "--defined-only", str(library)], text=True)
        exports = sorted(line.split()[-1] for line in symbols.splitlines()
                         if "Java_com_soundq_android_playback_nativeengine_NativeCallbackBridge_" in line)
        expected = sorted("Java_com_soundq_android_playback_nativeengine_NativeCallbackBridge_" + op
                          for op in ("open", "load", "control", "state", "close", "prepareSchedule", "arrangement", "scratch", "sync"))
        assert exports == expected, exports
        print("JNI exact exports:", *exports, sep="\n")
        print("TRACER ONLY SHA256", hashlib.sha256(library.read_bytes()).hexdigest())
    print("PASS: focused host checks; no actual codec or device execution claimed")


if __name__ == "__main__":
    main()

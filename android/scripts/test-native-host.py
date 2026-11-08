#!/usr/bin/env python3
"""Exercise the product's real offline JNI graph, without an SDK or OS output.

Requires CMake >=3.22, a full JDK, C/C++ compilers, Python and ffmpeg.
Usage: python3 android/scripts/test-native-host.py NEW_OUTPUT [--archive-dir DIR]
The optional archive directory uses the decoder's existing SHA-256 pins.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]


def run(*argv):
    subprocess.run(list(map(str, argv)), check=True, stdin=subprocess.DEVNULL,
                   timeout=600)


JAVA = r"""
package com.soundq.android.playback.mix;
import java.nio.*;
import java.nio.file.*;
public class NativeMix {
  native long open(String[] paths, long[] clips, float[] gains, long[] events, float[] eventGains);
  native void render(long h, long start, int count, byte[] bytes);
  native void renderPcmBlock(long origin, int count, long[] clips, float[][] windows, float[] gains, byte[] bytes);
  native void probe(String path, long frames, long preskip);
  native void close(long h);
  static void require(boolean ok) { if (!ok) throw new AssertionError(); }
  static void refused(Runnable body) {
    try { body.run(); } catch (IllegalArgumentException expected) { return; }
    throw new AssertionError("invalid JNI input accepted");
  }
  public static void main(String[] args) throws Exception {
    System.load(args[0]);
    NativeMix mix = new NativeMix();
    String path = args[1];
    byte[] opus = Files.readAllBytes(Path.of(path));
    int header = -1;
    for (int i=0; i+19<opus.length; i++) {
      if (new String(opus, i, 8, java.nio.charset.StandardCharsets.US_ASCII).equals("OpusHead")) { header=i; break; }
    }
    require(header >= 0);
    int preskip = (opus[header+10]&255) | ((opus[header+11]&255)<<8);
    mix.probe(path, 24000, preskip);
    refused(() -> mix.probe(path, 23999, preskip));
    long[] clip = {1,0,12000,2400,0,0,1,0,-1,-1,-1,-1};
    long h = mix.open(new String[]{path}, clip, new float[]{.5f}, new long[0], new float[0]);
    require(h != 0);
    try {
      byte[] bytes = new byte[512*8];
      mix.render(h,3000,512,bytes);
      FloatBuffer actual = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN).asFloatBuffer();
      FloatBuffer decoded = ByteBuffer.wrap(Files.readAllBytes(Path.of(args[2]))).order(ByteOrder.LITTLE_ENDIAN).asFloatBuffer();
      for (int i=0;i<1024;i++) require(Math.abs(actual.get(i)-decoded.get(5400*2+i)*.5f)<.00008f);
      refused(() -> mix.render(h,0,2049,new byte[2049*8]));
    } finally { mix.close(h); }
    float[] pcm = new float[1024];
    for (int i=0;i<512;i++) { pcm[i*2]=.25f; pcm[i*2+1]=-.125f; }
    byte[] bytes = new byte[512*8];
    long[] pcmClip = {1,0,512,0,512,0,0,0};
    mix.renderPcmBlock(0,512,pcmClip,new float[][]{pcm},new float[]{.5f},bytes);
    FloatBuffer actual = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN).asFloatBuffer();
    for (int i=0;i<512;i++) { require(actual.get(i*2)==.125f); require(actual.get(i*2+1)==-.0625f); }
    refused(() -> mix.renderPcmBlock(0,512,pcmClip,new float[][]{new float[3]},new float[]{.5f},bytes));
    System.out.println("JNI PASS: open/probe/decode/trim/render/close, PCM, invalid-input refusal");
  }
}
"""


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("--archive-dir", type=Path)
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    build = output / "build"
    command = ["cmake", "-S", ROOT / "android/app/src/main/cpp", "-B", build,
               "-DCMAKE_BUILD_TYPE=Debug", "-DCMAKE_EXPORT_COMPILE_COMMANDS=ON"]
    if args.archive_dir:
        command.append("-DSQ_OPUS_ARCHIVE_DIR=" + str(args.archive_dir.resolve()))
    run(*command)
    run("cmake", "--build", build, "--parallel", "1")
    # A host must not accidentally regain the device/fake-platform dependency.
    commands = json.loads((build / "compile_commands.json").read_text())
    sources = [Path(entry["file"]).name for entry in commands]
    assert sources.count("soundq_mix.cpp") == 1, sources
    assert "mix_bridge.cpp" in sources and "sq_opus_decoder.c" in sources
    assert not any(name.startswith("device_") or name == "ffi_fake_platform.cpp"
                   for name in sources), sources
    fixture = output / "fixtures"
    run(sys.executable, ROOT / "android/scripts/test-native-mix.py", build, fixture)
    java = output / "NativeMix.java"
    java.write_text(JAVA)
    run("javac", "-d", output, java)
    suffix = "dylib" if sys.platform == "darwin" else "so"
    run("java", "-cp", output, "com.soundq.android.playback.mix.NativeMix",
        build / ("libsoundq_mix_android." + suffix), fixture / "0.opus", fixture / "0.decoded")
    print("Offline host CMake/build/independent decoded-sample oracle/JVM JNI PASS", flush=True)


if __name__ == "__main__":
    main()

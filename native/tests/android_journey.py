#!/usr/bin/env python3
"""Coordinator-only qualification of the explicitly named disposable AVD.

Never selects the first device or clears application/account data. Existing
Pixel_10_Pro and unrelated AVDs are not write targets for this runner.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import threading
import time

ROOT = Path(__file__).resolve().parents[2]

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument("--serial",required=True)
    parser.add_argument("--avd",required=True)
    parser.add_argument("--fixture-home",required=True,type=Path)
    parser.add_argument("--evidence",required=True,type=Path)
    args=parser.parse_args()
    if not args.avd.startswith("soundq_native_port_") or args.serial in ("emulator-5554","emulator-5580"):
        raise SystemExit("runner requires the dedicated disposable native-port AVD")
    adb=Path(os.environ.get("ANDROID_HOME",str(Path.home()/"Library/Android/sdk")))/"platform-tools/adb"
    base=[str(adb),"-s",args.serial]
    evidence=args.evidence
    evidence.mkdir(parents=True,exist_ok=False)
    commands=[]
    def call(arguments,timeout=30,input=None,check=True):
        started=time.time()
        p=subprocess.run(base+arguments,input=input,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=timeout)
        commands.append({"argv":base+arguments,"exitCode":p.returncode,"durationSeconds":time.time()-started})
        if check and p.returncode:raise RuntimeError(f"adb operation failed {arguments[:3]}: {p.stderr.decode(errors='replace')}")
        return p
    def verify():
        actual=call(["emu","avd","name"]).stdout.decode().splitlines()[0].strip()
        if actual!=args.avd:raise RuntimeError("AVD identity changed")
    verify()
    apk=ROOT/"native/android/app/build/outputs/apk/debug/app-debug.apk"
    testapk=ROOT/"native/android/app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk"
    for package in (apk,testapk):
        verify();call(["install","-r",str(package)],timeout=60)
    verify();call(["reverse","tcp:54761","tcp:54761"])
    call(["shell","pm","grant","com.soundq.nativepreview","android.permission.POST_NOTIFICATIONS"],check=False)
    call(["shell","run-as","com.soundq.nativepreview","mkdir","-p","files"])
    call(["shell","run-as","com.soundq.nativepreview","rm","-f","files/native-journey-report.json","files/native-framestats.txt"],check=False)
    # Raw private input never enters command line or receipt.
    credentials=(args.fixture_home/"credentials.json").read_bytes()
    call(["shell","run-as com.soundq.nativepreview sh -c 'cat > files/native-fixture-credentials.json'"],input=credentials)
    call(["shell","dumpsys","gfxinfo","com.soundq.nativepreview","reset"],check=False)
    stop=threading.Event();memory=[]
    def monitor():
        while not stop.wait(0.6):
            sample=call(["shell","dumpsys","meminfo","com.soundq.nativepreview"],check=False)
            memory.append({"at":time.time(),"raw":sample.stdout.decode(errors="replace")})
    thread=threading.Thread(target=monitor);thread.start()
    status="failed"
    try:
        call(["shell","perfetto","--background","-o","/data/misc/perfetto-traces/soundq-native.pftrace","-t","18s","sched","freq","idle","am","wm","gfx","view","audio"],check=False)
        verify()
        result=call(["shell","am","instrument","-w","com.soundq.nativepreview.test/com.soundq.nativepreview.NativeJourney"],timeout=120)
        (evidence/"instrumentation.log").write_bytes(result.stdout+result.stderr)
        if b"status=passed" not in result.stdout and b"status=failed" not in result.stdout:
            raise RuntimeError("instrumentation crashed without terminal journey result")
        report=call(["shell","run-as","com.soundq.nativepreview","cat","files/native-journey-report.json"])
        data=json.loads(report.stdout)
        (evidence/"journey.json").write_bytes(report.stdout)
        status=data["status"]
    finally:
        stop.set();thread.join(timeout=10)
        (evidence/"memory.json").write_text(json.dumps(memory,indent=2)+"\n")
        frames=call(["shell","run-as","com.soundq.nativepreview","cat","files/native-framestats.txt"],check=False)
        (evidence/"framestats.txt").write_bytes(frames.stdout)
        cpu=call(["shell","dumpsys","cpuinfo"],check=False)
        (evidence/"cpuinfo.txt").write_bytes(cpu.stdout)
        # Perfetto finalizes only after its bounded recording, not when the app
        # journey exits. Preserve workload outcome independently of collector.
        time.sleep(18)
        call(["pull","/data/misc/perfetto-traces/soundq-native.pftrace",str(evidence/"perfetto.pftrace")],check=False)
        call(["shell","run-as","com.soundq.nativepreview","rm","-f","files/native-fixture-credentials.json"],check=False)
        receipt={"status":status,"serial":args.serial,"avd":args.avd,"apkSha256":hashlib.sha256(apk.read_bytes()).hexdigest(),"testApkSha256":hashlib.sha256(testapk.read_bytes()).hexdigest(),"commands":commands,"limits":"Dedicated API34 arm64 emulator, host contention preserved. Frame stats and Perfetto are raw evidence, not a fabricated FPS summary. No physical device or existing account touched."}
        (evidence/"receipt.json").write_text(json.dumps(receipt,indent=2)+"\n")
    print(json.dumps({"status":status,"evidence":str(evidence)}))
    if status!="passed":raise SystemExit(1)

if __name__=="__main__":main()

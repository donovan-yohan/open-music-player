#!/usr/bin/env python3
"""Pinned environment, retained native run and staged receipt transport; never builds."""
import argparse
from pathlib import Path
import re
import subprocess

import capture_contract
import studio


def transfer_request(adb: list[str], package: str, request: Path) -> str:
    """Stream the complete request into the owned package, never into shell argv."""
    filename = 'studio-render-request.json'
    subprocess.run([*adb, 'shell', 'run-as', package, 'mkdir', '-p', 'files'], check=True)
    with request.open('rb') as stream:
        subprocess.run([*adb, 'shell', '-T', 'run-as', package, 'dd', 'of=files/'+filename],
            stdin=stream, check=True)
    device_hash = subprocess.check_output(
        [*adb, 'shell', 'run-as', package, 'sha256sum', 'files/'+filename], text=True).split()
    if not device_hash or device_hash[0] != studio.digest(request.read_bytes()):
        raise ValueError('private request hash mismatch after transfer')
    return filename


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('action', choices=['environment', 'run', 'collect'])
    p.add_argument('--adb', default='adb')
    p.add_argument('--serial', required=True)
    p.add_argument('--locale', help='Pinned actual Android locale, e.g. en-US; native test checks it')
    p.add_argument('--package', default='com.soundq.designsystem.test')
    p.add_argument('--output', required=True)
    p.add_argument('--apk', help='Isolated-source library test APK from build_capture.py')
    p.add_argument('--request', help='Exact current render request')
    a = p.parse_args()
    adb = [a.adb, '-s', a.serial]

    def text(*args):
        return subprocess.check_output([*adb, *args], text=True).strip()

    def installed_hash():
        paths = [line.removeprefix('package:') for line in text('shell', 'pm', 'path', a.package).splitlines() if line.startswith('package:')]
        if len(paths) != 1:
            raise ValueError('expected one installed test APK; splits unsupported')
        return text('shell', 'sha256sum', paths[0]).split()[0]

    if a.action == 'environment':
        if not a.locale:
            p.error('--locale must explicitly pin the Android locale')
        env = {'sdk':int(text('shell','getprop','ro.build.version.sdk')), 'fingerprint':text('shell','getprop','ro.build.fingerprint'), 'model':text('shell','getprop','ro.product.model'), 'density':2, 'fontScale':1, 'locale':a.locale, 'renderer':'compose-captureToImage', 'widthDp':360}
        if any(v == '' for v in env.values()):
            raise ValueError('missing device environment')
        studio.save(a.output, env)
        print(a.output)
        return
    if not a.apk or not a.request:
        p.error(a.action+' requires --apk and --request')
    if a.package != 'com.soundq.designsystem.test':
        p.error('only the isolated library test package is supported')
    request = studio.load(a.request)
    if request['sources'] != studio.identities():
        raise ValueError('sources changed since render request')
    apk = Path(a.apk)
    # This check happens before installing or reading artifacts from the device.
    binding = capture_contract.apk_binding(apk, request['sources'])
    studio.require_native_host()
    if a.action == 'run':
        # am instrument retains the owned app and artifacts; Gradle connected uninstalls it.
        print(text('install', '-r', str(apk.resolve())))
        if installed_hash() != binding['apk_sha256']:
            raise ValueError('installed APK differs from supplied isolated build')
        subprocess.run([*adb,'shell','run-as',a.package,'rm','-f','files/design-studio/receipt.json'], check=True)
        request_file = transfer_request(adb, a.package, Path(a.request))
        result = subprocess.run([*adb,'shell','am','instrument','-w','-r','-e','class',
            'com.soundq.designsystem.StudioNativeComponentTest','-e','studioRequestFile',request_file,
            a.package+'/androidx.test.runner.AndroidJUnitRunner'], capture_output=True, text=True)
        out = Path(a.output); out.mkdir(parents=True, exist_ok=True)
        (out/'instrumentation.log').write_text(result.stdout+result.stderr, encoding='utf-8')
        print(result.stdout[-5000:])
        if result.returncode or not re.search(r'OK \(1 test\)', result.stdout) or 'FAILURES!!!' in result.stdout:
            raise ValueError('native component instrumentation did not report exactly one successful test')
        print('Native run complete; use collect before visual verify')
        return
    proof = capture_contract.apk_binding(apk, request['sources'], installed_hash())
    data = subprocess.check_output([*adb,'exec-out','run-as',a.package,'tar','-C','files/design-studio','-cf','-','.'])
    if request['sources'] != studio.identities() or studio.load(a.request) != request:
        raise ValueError('source/request changed during collection')
    if proof['apk_sha256'] != studio.digest(apk.read_bytes()):
        raise ValueError('local APK changed during collection')
    capture_contract.collect_archive(data, a.output, a.request, proof, input_paths=(apk,))
    print(str(a.output)+' (validated native transport; embedded source binding; isolated-source-snapshot; visual comparison still required)')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        raise SystemExit('ERROR: '+str(error))

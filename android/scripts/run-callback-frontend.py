#!/usr/bin/env python3
"""Run one explicit installed-app frontend journey on an authorized Android device."""
import argparse
import hashlib
import json
import re
import subprocess
import runpy
from pathlib import Path

p = argparse.ArgumentParser()
p.add_argument('--adb', required=True)
p.add_argument('--serial', required=True)
p.add_argument('--app-apk', type=Path, required=True)
p.add_argument('--test-apk', type=Path, required=True)
p.add_argument('--apksigner', required=True)
p.add_argument('--apkanalyzer', required=True)
p.add_argument('--report', type=Path, required=True)
p.add_argument('--test', default='com.soundq.android.CallbackFrontendJourneyTest#libraryRowPlaysNativeThenPauseSeekAndQueueCommandsRemainUsable')
a = p.parse_args()
a.report.mkdir(parents=True, exist_ok=False)
package = 'com.soundq.android.dev'
test_package = package+'.test'
runner = 'com.soundq.android.CallbackFrontendFixtureRunner'
selected = a.test
assert re.fullmatch(r'com\.soundq\.android\.[A-Za-z0-9_.]+#[A-Za-z0-9_]+', selected)

def run(argv, timeout=40):
    return subprocess.run(argv, capture_output=True, timeout=timeout)

def adb(*args, timeout=40):
    return run([a.adb, '-s', a.serial, *args], timeout)

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def signers(path):
    r = run([a.apksigner, 'verify', '--print-certs', str(path)])
    assert r.returncode == 0, r.stderr.decode(errors='replace')
    result = sorted(re.findall(rb'certificate SHA-256 digest: ([0-9a-fA-F]{64})', r.stdout))
    assert result
    return [x.decode().lower() for x in result]

def installed_path(pkg):
    r = adb('shell', 'pm', 'path', '--user', '0', pkg)
    lines = [x.removeprefix('package:') for x in r.stdout.decode().splitlines() if x.startswith('package:')]
    assert len(lines) <= 1, 'Split APK identity needs explicit qualification'
    return lines[0] if lines else None

assert adb('shell', 'am', 'get-current-user').stdout.strip() == b'0'
protected = {pkg: installed_path(pkg) for pkg in ['com.soundq.nativepreview', 'com.openmusicplayer.app']}
receipt = {'package': package, 'selectedTest': selected, 'runner': runner, 'installed': {}, 'protectedAppsUnchanged': False}
for pkg, apk in [(package, a.app_apk), (test_package, a.test_apk)]:
    actual = run([a.apkanalyzer, 'manifest', 'application-id', str(apk)])
    assert actual.returncode == 0 and actual.stdout.decode().strip() == pkg
    certificate = signers(apk)
    before = installed_path(pkg)
    if before:
        previous = a.report/(pkg+'-before.apk')
        assert adb('pull', before, str(previous)).returncode == 0
        assert signers(previous) == certificate, 'Refuse incompatible replacement; never uninstall'
    r = adb('install', '-r', str(apk), timeout=90)
    (a.report/(pkg+'-install.log')).write_bytes(r.stdout+r.stderr)
    assert r.returncode == 0 and b'Success' in r.stdout
    target = installed_path(pkg)
    assert target
    pulled = a.report/(pkg+'-installed.apk')
    assert adb('pull', target, str(pulled)).returncode == 0
    assert digest(pulled) == digest(apk)
    receipt['installed'][pkg] = {'sha256': digest(apk), 'signerSha256': certificate}

# Instrument only this fixture application. No production account or shared ADB changes.
try:
    r = adb('shell', 'am', 'instrument', '-w', '-r', '-e', 'class', selected,
            test_package+'/'+runner, timeout=180)
    raw = r.stdout+r.stderr
    (a.report/'instrumentation.log').write_bytes(raw)
    text = raw.decode(errors='replace')
    receipt['instrumentationExit'] = r.returncode
    parser = runpy.run_path(str(Path(__file__).with_name('callback-instrumentation-result.py')))['passed']
    receipt['passed'] = parser(raw, r.returncode, [tuple(selected.split('#', 1))])
finally:
    receipt['protectedAppsUnchanged'] = all(installed_path(pkg) == path for pkg, path in protected.items())
    for pkg in [package, test_package]:
        target = installed_path(pkg)
        assert target, pkg
        after = a.report/(pkg+'-after.apk')
        assert adb('pull', target, str(after)).returncode == 0
        assert digest(after) == receipt['installed'][pkg]['sha256']
    (a.report/'result.json').write_text(json.dumps(receipt, indent=2)+'\n')

assert receipt['protectedAppsUnchanged']
print(json.dumps(receipt, indent=2))
raise SystemExit(0 if receipt['passed'] else 1)

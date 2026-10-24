#!/usr/bin/env python3
"""Build real Dart AOT changes in a private source + Flutter SDK copy.

Run from any checkout, for example:
  python3 client/macos/test_incremental_signing.py --scratch "$TMPDIR/soundq-signing-test"

Requires macOS/APFS clone support, Python 3, rsync, Flutter and the ordinary
client-macos build prerequisites. --scratch must be new and outside the source
and SDK. No original Dart/source/SDK/build outputs are modified. Four builds
exercise cold, initial incremental and steady-state incremental packaging; an
initial passing incremental can be masked by unrelated native/plist work.
Receipts and the last app remain in --scratch for inspection/launch.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess


def run(args, *, cwd, env, log):
    with log.open('w') as output:
        result = subprocess.run(args, cwd=cwd, env=env, stdout=output,
                                stderr=subprocess.STDOUT)
    if result.returncode:
        raise RuntimeError(f'{args[0]} failed ({result.returncode}); see {log}')


def signature(app, env, log):
    run(['/usr/bin/codesign', '--verify', '--deep', '--strict', '--verbose=4',
         str(app)], cwd=app.parent, env=env, log=log)
    entitlements = subprocess.check_output(
        ['/usr/bin/codesign', '-d', '--entitlements', '-', str(app)],
        stderr=subprocess.DEVNULL)
    framework = app / 'Contents/Frameworks/App.framework'
    details = subprocess.check_output(
        ['/usr/bin/codesign', '-d', '--verbose=4', str(framework)],
        stderr=subprocess.STDOUT, text=True)
    cdhash = next(line.split('=', 1)[1] for line in details.splitlines()
                  if line.startswith('CDHash='))
    seal = (app / 'Contents/_CodeSignature/CodeResources').read_bytes()
    nested = plistlib.loads(seal)['files2']['Frameworks/App.framework']
    assert bytes.fromhex(cdhash) == nested['cdhash'], 'Outer seal has stale App.framework cdhash'
    return {
        'framework_sha256': hashlib.sha256((framework / 'App').read_bytes()).hexdigest(),
        'framework_cdhash': cdhash,
        'outer_seal_sha256': hashlib.sha256(seal).hexdigest(),
        'entitlements': entitlements.decode('utf-8'),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--scratch', type=Path, required=True)
    parser.add_argument('--flutter-sdk', type=Path,
                        help='Defaults to the SDK owning Flutter on PATH')
    args = parser.parse_args()
    source = Path(__file__).resolve().parents[2]
    flutter = shutil.which('flutter')
    if args.flutter_sdk is None and flutter is None:
        parser.error('Flutter is not on PATH; pass --flutter-sdk')
    sdk = (args.flutter_sdk or Path(flutter).resolve().parent.parent).resolve()
    scratch = args.scratch.resolve()
    for protected in (source, sdk):
        if scratch == protected or protected in scratch.parents or scratch in protected.parents:
            parser.error('--scratch must be outside the original source and Flutter SDK')
    scratch.mkdir(parents=True, exist_ok=False)
    private_sdk = scratch / 'flutter-sdk'
    subprocess.run(['/bin/cp', '-cR', str(sdk), str(private_sdk)], check=True)
    copy = scratch / 'source'
    copy.mkdir()
    excludes = ['.git', 'build/', '.dart_tool/', 'ephemeral/', 'Pods/',
                'node_modules/', '.gradle/', '.venv/', 'venv/', '.env', '.env.*']
    subprocess.run(['rsync', '-a', *[f'--exclude={p}' for p in excludes],
                    str(source) + '/', str(copy) + '/'], check=True)
    env = os.environ.copy()
    env['PATH'] = str(private_sdk / 'bin') + os.pathsep + env['PATH']
    env['TMPDIR'] = str(scratch / 'tmp')
    Path(env['TMPDIR']).mkdir()
    for key in ('SOUNDQ_NATIVE_DEVICE_LIBRARY', 'SQ_OPUS_ARCHIVE_DIR'):
        env.pop(key, None)
    dart = copy / 'client/lib/main.dart'
    original = dart.read_bytes()
    needle = b'  WidgetsFlutterBinding.ensureInitialized();'
    assert original.count(needle) == 1, 'Cannot locate production startup marker seam'
    app = copy / 'client/build/macos/Build/Products/Release/SoundQ.app'
    results = []
    try:
        for stage in ('cold', 'initial-incremental', 'steady-incremental-1', 'steady-incremental-2'):
            # A retained print changes executable AOT, unlike comments/tree-shaken constants.
            marker = f"\n  debugPrint('SOUNDQ_SIGNING_REGRESSION_{stage}');".encode()
            dart.write_bytes(original.replace(needle, needle + marker))
            run([str(copy / 'scripts/build'), 'client-macos'], cwd=copy, env=env,
                log=scratch / f'{stage}-build.log')
            item = signature(app, env, scratch / f'{stage}-verify.log')
            item['stage'] = stage
            if results:
                assert item['framework_sha256'] != results[-1]['framework_sha256'], 'Dart AOT did not change'
                assert item['outer_seal_sha256'] != results[-1]['outer_seal_sha256'], 'Outer seal did not change'
                assert item['entitlements'] == results[-1]['entitlements'], 'Entitlements changed'
            results.append(item)
            (scratch / 'receipt.json').write_text(json.dumps(results, indent=2) + '\n')
            print(f'PASS {stage}: App.framework {item["framework_cdhash"]}', flush=True)
    finally:
        dart.write_bytes(original)
    print(f'PASS cold + steady incremental strict/deep packaging; receipts: {scratch}', flush=True)


if __name__ == '__main__':
    main()

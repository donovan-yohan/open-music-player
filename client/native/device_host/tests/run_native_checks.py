#!/usr/bin/env python3
"""Build/test host without opening or starting any real audio device."""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--ndk', type=Path, required=True)
parser.add_argument('--archive-dir', type=Path)
parser.add_argument('--android-cmake', type=Path,
                    help='Use the actual SDK-selected CMake (e.g. 3.22.1)')
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
output = args.output.resolve()
if output.exists() and any(output.iterdir()):
    parser.error('--output must be new or empty to preserve build evidence')
output.mkdir(parents=True, exist_ok=True)
records = []
sources = [p for base in (root, root.parent/'mix_renderer', root.parent/'opus_decoder') for p in base.rglob('*')
           if p.is_file() and p.suffix in {'.cpp', '.c', '.h', '.py', '.txt'}
           and '__pycache__' not in p.parts]
(output/'source-sha256.json').write_text(json.dumps({
    str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(sources)
}, indent=2) + '\n')

def run(name, argv, timeout=180):
    started = time.monotonic()
    record = {'name': name, 'argv': [str(a) for a in argv], 'cwd': str(root), 'timeout_seconds': timeout}
    try:
        result = subprocess.run(record['argv'], cwd=root, stdin=subprocess.DEVNULL,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                timeout=timeout, check=False)
        record['exit_code'] = result.returncode
        record['stdout_base64'] = base64.b64encode(result.stdout).decode()
        record['stderr_base64'] = base64.b64encode(result.stderr).decode()
        text = result.stdout.decode('utf-8', errors='replace') + result.stderr.decode('utf-8', errors='replace')
    except (subprocess.TimeoutExpired, OSError) as exc:
        record['exit_code'] = -1
        text = str(exc)
    record['seconds'] = time.monotonic() - started
    log = output / f'{name}.log'
    log.write_text(text)
    record['log'] = str(log)
    records.append(record)
    (output / 'receipts.json').write_text(json.dumps(records, indent=2) + '\n')
    print(f'{name}: exit {record["exit_code"]}; {log}', flush=True)
    if record['exit_code'] or any(line.startswith(('ERROR:', 'ERROR ', 'CMake Error'))
                                  for line in text.splitlines()):
        raise SystemExit(text)
    return text

cmake = shutil.which('cmake')
if not cmake:
    raise SystemExit('cmake unavailable')
common = [f'-DSQ_OPUS_ARCHIVE_DIR={args.archive_dir.resolve()}'] if args.archive_dir else []
# Preserve caller-wide cache choices while source-building static decoder deps.
common += ['-DBUILD_TESTING:BOOL=ON', '-DBUILD_SHARED_LIBS:BOOL=ON']
for name, extra in [('macos', []), ('asan', ['-DSQ_DEVICE_SANITIZE=ON', '-DSQ_OPUS_SANITIZE=ON'])]:
    build = output / name
    run(f'{name}-configure', [cmake, '-S', root, '-B', build, '-DCMAKE_BUILD_TYPE=Debug',
                             '-DCMAKE_EXPORT_COMPILE_COMMANDS=ON', *common, *extra])
    cache = (build/'CMakeCache.txt').read_text()
    assert 'BUILD_TESTING:BOOL=ON' in cache and 'BUILD_SHARED_LIBS:BOOL=ON' in cache
    run(f'{name}-build', [cmake, '--build', build, '-j', '4'])
    run(f'{name}-tests', [str(Path(cmake).with_name('ctest')), '--test-dir', build,
                         '--output-on-failure', '-V'])
# Execute the existing real ffmpeg oracle against the PRODUCTION host, no device open.
probe = root.parent/'opus_decoder/tests/test_decoder.py'
run('opus-fixtures', [sys.executable, probe, '--generate', '--fixtures', output/'fixtures'])
run('host-opus-output', [sys.executable, probe, '--library', output/'macos/libsoundq_device.dylib',
                         '--fixtures', output/'fixtures'])
# Exercise instrumented decoder+upstream through the instrumented production
# host (ctypes cannot load ASan into an unsanitized Python process on macOS).
run('asan-opus-probe-build', ['clang', '-std=c11', '-fsanitize=address,undefined',
    '-fno-omit-frame-pointer', '-UNDEBUG', '-I', root.parent/'opus_decoder/include',
    root.parent/'opus_decoder/tests/smoke.c', '-L', output/'asan', '-lsoundq_device',
    f'-Wl,-rpath,{output}/asan', '-o', output/'asan-opus-probe'])
run('asan-host-opus-output', [output/'asan-opus-probe', output/'fixtures'])
ndk = args.ndk.resolve()
android_cmake = str(args.android_cmake.resolve()) if args.android_cmake else cmake
run('android-cmake-version', [android_cmake, '--version'])
android = output / 'android-arm64'
run('android-configure', [android_cmake, '-S', root, '-B', android,
    f'-DCMAKE_TOOLCHAIN_FILE={ndk}/build/cmake/android.toolchain.cmake',
    '-DANDROID_ABI=arm64-v8a', '-DANDROID_PLATFORM=android-26',
    '-DANDROID_STL=c++_shared', '-DCMAKE_BUILD_TYPE=Debug', '-DSQ_DEVICE_TESTS=OFF',
    '-DCMAKE_EXPORT_COMPILE_COMMANDS=ON', *common])
run('android-build', [android_cmake, '--build', android, '-j', '4'])
required = {'sq_opus_decoder_open', 'sq_opus_decoder_sample_rate', 'sq_opus_decoder_channels',
            'sq_opus_decoder_frame_count', 'sq_opus_decoder_pre_skip',
            'sq_opus_decoder_read_window', 'sq_opus_decoder_destroy', 'sq_opus_status_string',
            'sq_create', 'sq_destroy', 'sq_submit', 'sq_render', 'sq_applied_revision',
            'sq_rendered_frames', 'sq_device_open', 'sq_device_start', 'sq_device_pause',
            'sq_device_close', 'sq_device_error', 'sq_device_native_error',
            'sq_device_sample_rate', 'sq_device_max_block_frames'}
artifacts = []
for name, library, command in [
    ('macos', output/'macos/libsoundq_device.dylib', ['nm', '-gU']),
    ('android', android/'libsoundq_device.so',
     [str(ndk/'toolchains/llvm/prebuilt/darwin-x86_64/bin/llvm-nm'), '--dynamic', '--defined-only'])]:
    text = run(f'{name}-exports', [*command, library])
    symbols = {line.split()[-1].lstrip('_') for line in text.splitlines() if line.split()}
    missing = sorted(required - symbols)
    if missing:
        raise SystemExit(f'{name}: missing exports {missing}')
    artifacts.append({'path': str(library), 'bytes': library.stat().st_size,
                      'sha256': hashlib.sha256(library.read_bytes()).hexdigest(),
                      'required_exports': sorted(required)})
mac_linkage = run('macos-linkage', ['otool', '-L', output/'macos/libsoundq_device.dylib'])
android_linkage = run('android-linkage', [str(ndk/'toolchains/llvm/prebuilt/darwin-x86_64/bin/llvm-readelf'),
                         '-h', '-d', android/'libsoundq_device.so'])
assert 'homebrew' not in (mac_linkage + android_linkage).lower()
assert not any(name in android_linkage for name in ['libopus.so', 'libogg.so', 'libopusfile.so'])
(output/'artifacts.json').write_text(json.dumps(artifacts, indent=2) + '\n')
print('Verified native host macOS + ASan/UBSan + Android arm64 compilation and exports. No OS output opened/started.')

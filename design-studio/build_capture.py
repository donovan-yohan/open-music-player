#!/usr/bin/env python3
"""Build only the library capture test APK from a private, source-bound snapshot."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

import capture_contract
import studio

APK_RELATIVE = 'android/designsystem/build/outputs/apk/androidTest/debug/designsystem-debug-androidTest.apk'


def snapshot_identities(snapshot):
    return studio.identities(snapshot)


def prepare_snapshot(root, snapshot, sources):
    """Copy bytes, not links; no git history, output/cache trees or local credentials."""
    root, snapshot = Path(root), Path(snapshot)
    for name in sources:
        source, target = root/name, snapshot/name
        target.parent.mkdir(parents=True, exist_ok=True)
        if source.is_symlink():
            raise ValueError('source symlink: '+name)
        data = source.read_bytes()
        if studio.digest(data) != sources[name]:
            raise ValueError('source changed during snapshot copy: '+name)
        target.write_bytes(data)
        target.chmod(0o444 | (source.stat().st_mode & 0o111))
    if snapshot_identities(snapshot) != sources or studio.identities(root) != sources:
        raise ValueError('sources changed during snapshot copy')
    studio.save(snapshot/studio.BUILD_ASSET, {'schema':1, 'build_mode':'isolated-source-snapshot', 'sources':sources})
    (snapshot/studio.BUILD_ASSET).chmod(0o444)


def verify_sources(snapshot, sources):
    if snapshot_identities(snapshot) != sources:
        raise ValueError('snapshot source identities changed; build not publishable')
    if studio.identities() != sources:
        raise ValueError('current source identities changed during build; rerun from stable sources')
    asset = studio.load(Path(snapshot)/studio.BUILD_ASSET)
    if asset != {'schema':1, 'build_mode':'isolated-source-snapshot', 'sources':sources}:
        raise ValueError('snapshot build asset changed')


def build(output, environment=None, runner=subprocess.run):
    studio.require_native_host()
    env = dict(os.environ if environment is None else environment)
    for name in ('JAVA_HOME', 'ANDROID_HOME'):
        if not env.get(name) or not Path(env[name]).is_dir():
            raise ValueError(name+' must explicitly name an existing toolchain directory')
    scratch = env.get('TMPDIR')
    if not scratch or not Path(scratch).is_dir():
        raise ValueError('TMPDIR must explicitly name an owned scratch directory')
    sources = studio.identities()
    output = Path(output).resolve()
    if output != (studio.HOME/'build').resolve():
        raise ValueError('build output is restricted to design-studio/build')
    # mkdtemp creates mode 0700; no caller-controlled snapshot path or shared source inode.
    with tempfile.TemporaryDirectory(prefix='studio-source-', dir=scratch) as temp:
        snapshot = Path(temp)
        prepare_snapshot(studio.ROOT, snapshot, sources)
        # Neither inherited Gradle init scripts/credentials nor caches enter this build.
        env['GRADLE_USER_HOME'] = str(snapshot/'.gradle-user-home')
        env['PYTHONDONTWRITEBYTECODE'] = '1'
        # Prevent caller-injected Gradle/JVM flags from changing build inputs/tasks.
        for key in ('GRADLE_OPTS', 'JAVA_TOOL_OPTIONS', '_JAVA_OPTIONS', 'JDK_JAVA_OPTIONS'):
            env.pop(key, None)
        catalog_command = [sys.executable, '-B', 'design-studio/studio.py', 'catalog', 'generate']
        runner(catalog_command, cwd=snapshot, env=env, check=True)
        if studio.load(snapshot/'design-studio/generated/catalog.json')['identities'] != sources:
            raise ValueError('snapshot catalog identities mismatch')
        verify_sources(snapshot, sources)
        command = ['./gradlew', ':designsystem:assembleDebugAndroidTest', '--no-daemon', '--max-workers=2', '--rerun-tasks', '--no-build-cache', '--no-configuration-cache']
        runner(command, cwd=snapshot/'android', env=env, check=True)
        verify_sources(snapshot, sources)
        apk = snapshot/APK_RELATIVE
        binding = capture_contract.apk_binding(apk, sources)
        receipt = {'schema':1, 'producer':'design-studio/build_capture.py',
                   'build_mode':'isolated-source-snapshot', 'sources':sources,
                   'apk_sha256':binding['apk_sha256'], 'embedded_asset_sha256':binding['embedded_asset_sha256'],
                   'command':command, 'toolchain':{key:env[key] for key in ('JAVA_HOME', 'ANDROID_HOME')},
                   'snapshot_sources_unchanged':True, 'current_sources_unchanged':True,
                   'catalog_identities_match':True}
        # Export as one directory replacement only after every validation succeeds.
        output.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='.studio-export-', dir=output.parent) as export_temp:
            staged = Path(export_temp)/'build'; staged.mkdir()
            shutil.copyfile(apk, staged/'designsystem-debug-androidTest.apk')
            studio.save(staged/'build-receipt.json', receipt)
            verify_sources(snapshot, sources)
            previous = Path(export_temp)/'previous'
            if output.exists(): output.rename(previous)
            try:
                staged.rename(output)
            except BaseException:
                if previous.exists(): previous.rename(output)
                raise
    return receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', default=str(studio.HOME/'build'), help='Must be design-studio/build')
    args = parser.parse_args()
    receipt = build(args.output)
    print(json.dumps({'apk':str(Path(args.output)/'designsystem-debug-androidTest.apk'),
                      'apk_sha256':receipt['apk_sha256'], 'build_mode':receipt['build_mode']}))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, KeyError, subprocess.CalledProcessError) as error:
        raise SystemExit('ERROR: '+str(error))

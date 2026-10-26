#!/usr/bin/env python3
"""Exercise extracted production readback control flow with method-channel fakes.

This is an adapter contract probe, not an actual AudioPlayer/native measurement.
The public AudioPlayer default-off test remains a separate real-package control.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
from typing import Any

ROOT = Path(__file__).resolve().parents[1]


def extract(source):
    start = source.index('  Future<Map<String, dynamic>> soundqNativeReadback(')
    # The method signature has a named-argument block before the body.
    body = source.index('}) async {', start) + len('}) async ')
    level = 0
    for i in range(body, len(source)):
        if source[i] == '{':
            level += 1
        elif source[i] == '}':
            level -= 1
            if level == 0:
                return source[start:i + 1]
    raise ValueError('readback-method-not-closed')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--prepare-only', action='store_true')
    args = parser.parse_args()
    args.output.mkdir(mode=0o700, parents=True, exist_ok=False)
    source = ROOT / 'third_party/just_audio/lib/just_audio.dart'
    original = extract(source.read_text())
    # Explicit test-only substitutions. No private field activation or native
    # player is represented; every transport response below is synthetic.
    method = original.replace('kProfileMode', 'profileMode')
    method = method.replace('_IdleAudioPlayer', 'IdleFacade')
    method = method.replace("const bool.fromEnvironment('SOUNDQ_NATIVE_PLAYER_READBACK')", 'diagnosticDefine')
    declaration = """import 'dart:async';
import 'package:flutter/services.dart';
bool profileMode = true;
bool darwinPlatform = true;
const diagnosticDefine = bool.fromEnvironment('SOUNDQ_NATIVE_PLAYER_READBACK');
class PlatformFacade {PlatformFacade(this.id);final String id;}
class IdleFacade extends PlatformFacade {IdleFacade(super.id);}
class SourceFacade {SourceFacade(this._id);final String _id;}
class SequenceFacade {SourceFacade? currentSource=SourceFacade('00000000-0000-4000-8000-000000000002');}
class DiagnosticFacade {
 DiagnosticFacade(String id):_id=id,_platformValue=PlatformFacade(id);
 bool _active=true,_disposed=false;String? _id;PlatformFacade? _platformValue;
 int activations=0;
 final sequenceState=SequenceFacade();
 void replaceSource()=>sequenceState.currentSource=SourceFacade('00000000-0000-4000-8000-000000000002');
 bool _isDarwin()=>darwinPlatform;
 set active(bool v)=>_active=v;
 set disposed(bool v)=>_disposed=v;
 set platform(PlatformFacade? v)=>_platformValue=v;
 set ownerId(String v)=>_id=v;
"""
    facade = args.output / 'production_method.dart'
    facade.write_text(declaration + method + '\n}\n')
    template = ROOT / 'test/just_audio_native_readback_cases.template'
    cases = template.read_text().replace('// __PRODUCTION_METHOD_IMPORT__', "import 'production_method.dart';")
    test = args.output / 'production_method_test.dart'
    test.write_text(cases)
    receipt: dict[str, Any] = dict(
        scope='synthetic adapter contract, not package/native runtime',
        production_method_sha256=hashlib.sha256(original.encode()).hexdigest(),
        source_sha256=hashlib.sha256(source.read_bytes()).hexdigest(),
        generated_method_sha256=hashlib.sha256(facade.read_bytes()).hexdigest(),
        generated_test_sha256=hashlib.sha256(test.read_bytes()).hexdigest(),
        substitutions=['kProfileMode -> mutable profileMode',
                       '_IdleAudioPlayer -> IdleFacade',
                       'compile define -> identical compile-define alias'],
        prepared=True, executed=False, exit_code=None,
        TMPDIR=os.environ.get('TMPDIR'),
    )
    if not args.prepare_only:
        flutter = shutil.which('flutter')
        if flutter is None:
            raise RuntimeError('installed-flutter-required')
        argv = [flutter, 'test', '--no-pub', '--dart-define=SOUNDQ_NATIVE_PLAYER_READBACK=true', str(test)]
        with (args.output / 'run.log').open('wb') as log:
            result = subprocess.run(argv, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, timeout=180)
        receipt.update(executed=True, exit_code=result.returncode, argv=argv)
    (args.output / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps(dict(output=str(args.output), executed=receipt['executed'], exit_code=receipt['exit_code'])))
    return receipt['exit_code'] or 0


if __name__ == '__main__':
    raise SystemExit(main())

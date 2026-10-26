"""Offline exact-file integrity check for the bounded just_audio readback fork.

The source is pinned to installed package bytes, not archive-authenticated.
Reverse the declared patch and require exact upstream hashes and license.
"""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

CLIENT = Path(__file__).resolve().parents[1]
VENDOR = CLIENT / 'third_party/just_audio'
PROVENANCE = CLIENT / 'third_party/just_audio_provenance'


def main():
    manifest = json.loads((PROVENANCE / 'upstream.json').read_bytes())
    assert manifest['version'] == '0.10.6'
    assert manifest['origin'] == 'installed-pub-cache-exact-files'
    assert manifest['upstream_archive_authenticated'] is False
    expected = manifest['files']
    actual = {p.relative_to(VENDOR).as_posix() for p in VENDOR.rglob('*') if p.is_file()}
    assert actual == set(expected), actual ^ set(expected)
    assert not any(p.is_symlink() for p in VENDOR.rglob('*'))
    assert all(oct((VENDOR / name).stat().st_mode & 0o777) == value['mode']
               for name, value in expected.items())
    assert hashlib.sha256((VENDOR / 'LICENSE').read_bytes()).hexdigest() == expected['LICENSE']['sha256']
    assert 'soundqNativeReadback' in (VENDOR / 'lib/just_audio.dart').read_text()
    assert 'soundqNativeReadback' in (VENDOR / 'darwin/just_audio/Sources/just_audio/AudioPlayer.m').read_text()
    patch = PROVENANCE / 'native-readback.patch'
    assert patch.is_file() and patch.stat().st_size > 0
    with tempfile.TemporaryDirectory(prefix='just-audio-integrity-') as tmp:
        root = Path(tmp)
        for name in actual:
            target = root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(VENDOR / name, target)
        subprocess.run(['patch', '--batch', '--fuzz=0', '-R', '-p1', '-i', str(patch)], cwd=root, check=True, capture_output=True)
        for name, value in expected.items():
            assert hashlib.sha256((root / name).read_bytes()).hexdigest() == value['sha256'], name
    assert 'path: third_party/just_audio' in (CLIENT / 'pubspec.yaml').read_text()
    print(f'PASS just_audio 0.10.6: {len(actual)} exact upstream files after reversible diagnostic patch')


if __name__ == '__main__':
    main()

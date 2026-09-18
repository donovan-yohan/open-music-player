"""Offline integrity gate. Optionally authenticate against the pinned pub archive.

python3 test/audio_service_vendor_check.py [--archive /path/to/archive.tar.gz]
Every included upstream byte must match after reversing the sole documented patch.
"""
import argparse
import hashlib
import io
import json
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile

client = Path(__file__).resolve().parents[1]
vendor = client / 'third_party/audio_service'
provenance = client / 'third_party/audio_service_provenance'
manifest = json.loads((provenance / 'upstream.json').read_text())
assert manifest['version'] == '0.18.18'
assert manifest['archive_sha256'] == 'cb122c7c2639d2a992421ef96b67948ad88c5221da3365ccef1031393a76e044'
assert 'version: 0.18.18\n' in (vendor / 'pubspec.yaml').read_text()
# Ignore only tool-generated output, never source files.
ignored = {'.dart_tool', 'build', '.gradle', '__pycache__'}
files = {p.relative_to(vendor).as_posix() for p in vendor.rglob('*')
         if p.is_file() and not (set(p.relative_to(vendor).parts) & ignored)}
assert files == set(manifest['files']), files ^ set(manifest['files'])
patch = provenance / 'completed-stopped.patch'
assert patch.read_text().count('\n-        case completed:') == 1
assert patch.read_text().count('\n+        case completed:') == 1
with tempfile.TemporaryDirectory() as tmp:
    root = Path(tmp)
    for name in files:
        target = root / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(vendor / name, target)
    subprocess.run(['patch', '--batch', '--fuzz=0', '-R', '-p1', '-i', str(patch)],
                   cwd=root, check=True)
    for name, expected in manifest['files'].items():
        assert hashlib.sha256((root / name).read_bytes()).hexdigest() == expected, name
args = argparse.ArgumentParser()
args.add_argument('--archive', type=Path)
archive = args.parse_args().archive
if archive:
    data = archive.read_bytes()
    assert hashlib.sha256(data).hexdigest() == manifest['archive_sha256']
    with tarfile.open(fileobj=io.BytesIO(data)) as tar:
        selected = {m.name for m in tar.getmembers() if m.isfile()
                    and Path(m.name).parts[0] in manifest['included_roots']}
        assert selected == files
        for name, expected in manifest['files'].items():
            member = tar.extractfile(name)
            assert member is not None, name
            assert hashlib.sha256(member.read()).hexdigest() == expected, name
print(f'PASS: audio_service 0.18.18, {len(files)} upstream files, sole reversible patch')

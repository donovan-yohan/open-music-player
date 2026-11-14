"""Native artifact contracts; no ADB, builds, or import-time side effects."""
import io
import re
import struct
import zlib
import json
from pathlib import Path
import zipfile
import tarfile
import tempfile

import studio


def apk_binding(apk, sources, installed_hash=None):
    """Read binding from APK bytes, never from caller request echoes or mtimes."""
    data = Path(apk).read_bytes()
    try:
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            if archive.namelist().count('assets/studio-build.json') != 1:
                raise ValueError('missing/duplicate embedded build asset')
            raw = archive.read('assets/studio-build.json')
        asset = json.loads(raw)
    except (zipfile.BadZipFile, KeyError, json.JSONDecodeError) as error:
        raise ValueError('invalid embedded build asset') from error
    if asset.get('schema') != 1 or asset.get('build_mode') != 'isolated-source-snapshot':
        raise ValueError('unsupported embedded build mode')
    if asset.get('sources') != sources:
        raise ValueError('embedded APK source identities mismatch; rebuild using build_capture.py')
    apk_hash = studio.digest(data)
    if installed_hash is not None and installed_hash != apk_hash:
        raise ValueError('installed APK differs from supplied isolated build')
    proof = {'producer':'design-studio/native_capture.py collect',
             'apk_sha256':apk_hash, 'installed_apk_sha256':installed_hash,
             'source_identity_sha256':studio.digest(json.dumps(sources, sort_keys=True).encode()),
             'build_mode':asset['build_mode'], 'embedded_binding':asset,
             'embedded_asset_sha256':studio.digest(raw)}
    return proof


def read_archive(data):
    """Return only this transfer's files, rejecting aliases, duplicates and links."""
    files = {}
    with tarfile.open(fileobj=io.BytesIO(data)) as archive:
        for member in archive.getmembers():
            if member.isdir() and member.name in ('.', './'):
                continue
            name = Path(member.name).name
            if (not member.isfile() or member.name not in (name, './'+name)
                    or not (name == 'receipt.json' or name.startswith('components-') and name.endswith('.png'))
                    or name in files):
                raise ValueError('unexpected/duplicate native artifact: '+member.name)
            stream = archive.extractfile(member)
            if stream is None:
                raise ValueError('unreadable native artifact: '+member.name)
            files[name] = stream.read()
    if 'receipt.json' not in files:
        raise ValueError('native receipt missing from received archive')
    return files


def admit_output(output, request, input_paths=()):
    """Only replace an empty target or an intact, exclusively owned collection.

    Resolve ancestors as well as leaf aliases before comparing inputs. Historical
    collection sources may differ; recognition is not current evidence approval.
    """
    target = Path(output)
    out = target.resolve()
    protected = [Path(request), *studio.source_files(), *map(Path, input_paths)]
    for path in protected:
        path = path.resolve()
        if out == path or out in path.parents or path in out.parents:
            raise ValueError('collection output must not overlap inputs: '+str(path))
    refusal = 'output must be empty or a recognized collection containing only receipt case files'
    if target.is_symlink():
        raise ValueError(refusal)
    if not out.exists():
        return out
    if not out.is_dir():
        raise ValueError(refusal)
    entries = list(out.iterdir())
    if not entries:
        return out
    if any(p.is_symlink() or not p.is_file() for p in entries):
        raise ValueError(refusal)
    try:
        receipt = studio.load(out/'receipt.json')
        if (receipt.get('schema') != 1 or receipt.get('kind') not in ('harness-only', 'android-compose-native')
                or not isinstance(receipt.get('sources'), dict) or not isinstance(receipt.get('environment'), dict)):
            raise ValueError(refusal)
        cases = receipt['cases']
        if not isinstance(cases, list) or not cases:
            raise ValueError(refusal)
        names = {'receipt.json'}
        for case in cases:
            name = case['file']
            if (not re.fullmatch(r'[a-z0-9-]+', case['id']) or name != case['id']+'.png'
                    or name in names or studio.digest((out/name).read_bytes()) != case['sha256']):
                raise ValueError(refusal)
            studio.png(out/name)
            names.add(name)
        if {p.name for p in entries} != names:
            raise ValueError(refusal)
    except (ValueError, KeyError, TypeError, AttributeError, OSError, struct.error, zlib.error) as error:
        raise ValueError(refusal) from error
    return out


def collect_archive(data, output, request, proof, harness=False, input_paths=()):
    """Validate an isolated complete transfer before replacing any prior collection."""
    files = read_archive(data)
    out = admit_output(output, request, input_paths)
    out.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.native-transfer-', dir=out.parent) as temp:
        stage = Path(temp)/'captures'
        stage.mkdir()
        for name, content in files.items():
            (stage/name).write_bytes(content)
        receipt = studio.load(stage/'receipt.json')
        req = studio.load(request)
        if receipt.get('sources') != req['sources'] or receipt.get('environment') != req['environment']:
            raise ValueError('native receipt is stale or from a different environment')
        if not harness:
            receipt['build_provenance'] = proof
            studio.save(stage/'receipt.json', receipt)
        studio.validate(stage, request, harness=harness)
        expected = {'receipt.json'} | {c['file'] for c in receipt['cases']}
        if set(files) != expected:
            raise ValueError('unexpected files outside receipt case set')
        # Same-filesystem renames: no stale files are merged into the new result.
        # On publish failure restore the original, including its provenance bytes.
        admit_output(output, request, input_paths)
        backup = Path(temp)/'previous'
        if out.exists():
            out.rename(backup)
        try:
            stage.rename(out)
        except BaseException:
            if backup.exists():
                backup.rename(out)
            raise
    return receipt

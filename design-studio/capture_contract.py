"""Native artifact contracts; no ADB, builds, or import-time side effects."""
import io
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


def collect_archive(data, output, request, proof, harness=False):
    """Validate an isolated complete transfer before replacing any prior collection."""
    files = read_archive(data)
    out = Path(output).resolve()
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

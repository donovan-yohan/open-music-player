#!/usr/bin/env python3
"""Acquire verified Compose Robolectric inputs for a later workflow step."""
import hashlib
import os
from pathlib import Path
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
from typing import NamedTuple


CENTRAL = 'https://repo.maven.apache.org/maven2/'
NATIVE = 'org/robolectric/nativeruntime-dist-compat/1.0.18/'


class Pin(NamedTuple):
    path: str
    target: str
    size: int
    sha512: str


def sdk(version, size, digest):
    name = f'android-all-instrumented-{version}.jar'
    return Pin(f'org/robolectric/android-all-instrumented/{version}/{name}', f'sdk/{name}', size, digest)


def native(extension, size, digest):
    path = NATIVE + 'nativeruntime-dist-compat-1.0.18.' + extension
    return Pin(path, 'maven/' + path, size, digest)


# Robolectric 4.16: app APIs 28/30/34, designsystem API 34, JDK 21 compile resources API 36.
# SHA-512 pins verified against official Maven Central sidecars and full bytes.
PINS = (
    sdk('9-robolectric-4913185-2-i7', 106130412, '24687b9ea919eb20f5e27e47274f2aa711e98eb332d4769d34044a3b4952a71393831d0a3f61ba726dc8fe220673a76138c11a0716f304999e5b029146fe88eb'),
    sdk('11-robolectric-6757853-i7', 126899852, '686c3d5faf7772795fc28f356baf9a92dcd89dedc2f7a16720ce4eb8d7b5ee5932500c623c3028355cc13a14c855210bcba796180681a01b0a7f2a276eb5303d'),
    sdk('14-robolectric-10818077-i7', 151142227, '7cdc0b1306e7865f1acd25a363073149654caee5b8e278c5ae37ff4724185724eff39f0b0111800b521e640bb28698d9d2e655134a801569a0f07470e7b5f455'),
    sdk('16-robolectric-13921718-i7', 213431622, '0576318b89abb0a1c9a760a61bb68ccd2d509b33164b8265d6b1fb587a4b7629e1e805b6c7f8fbefab94fc03c8db8100b1d4856a32728803c242d2677aa7ec76'),
    native('pom', 1334, 'fe784d6dfb4c860c95c768dcb285522f1cfd29e2b88aabb188b3623ea33525c794551dcdb4b014c22c63848d85f71af967481b762b82ac02d7bb936ee8c5b041'),
    native('jar', 159128857, '1d4122a1c9ea6ad7e5a8ba2d3fc08691fa5d6da9151acfbae93a111c57d2772b65d440e75abee9ed69ebf3b42c42530df1e2e17e7ab48cca2df6c215d4fd4415'),
)


class AdmissionError(Exception):
    pass


class Cancelled(Exception):
    pass


class Children:
    """Own only the curl transfer group; this helper never starts Gradle."""
    sig = 0

    def cancel(self, signum, _frame):
        self.sig = self.sig or signum

    def check(self):
        if self.sig:
            raise Cancelled(self.sig)

    def run(self, argv, **kwargs):
        self.check()
        child = subprocess.Popen(argv, start_new_session=True, **kwargs)
        try:
            while True:
                self.check()
                try:
                    result, _ = child.communicate(timeout=0.2)
                except subprocess.TimeoutExpired:
                    continue
                self.check()
                return child.returncode, result
        except BaseException:
            # A process may exit before its descendants; signal the group, not the leader.
            for signum in (signal.SIGTERM, signal.SIGKILL):
                try:
                    os.killpg(child.pid, signum)
                except ProcessLookupError:
                    break
                if signum == signal.SIGTERM:
                    try:
                        child.wait(timeout=2)
                    except subprocess.TimeoutExpired:
                        pass
            child.communicate()
            raise


def download(children, pin, output):
    code, status = children.run([
        'curl', '--disable', '--silent', '--fail', '--proto', '=https',
        '--retry', '0', '--connect-timeout', '8', '--max-time', '90',
        '--max-filesize', str(pin.size), '--output', str(output), '--write-out', '%{http_code}',
        CENTRAL + pin.path,
    ], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    if code or status != b'200':
        http = status.decode('ascii') if re.fullmatch(rb'[0-9]{3}', status) else 'unknown'
        raise AdmissionError(f'{output.name}: HTTP {http}, curl exit {code}')


def canonical_dir(directory):
    try:
        canonical = directory.is_absolute() and directory.resolve(strict=True) == directory and directory.is_dir()
    except (OSError, RuntimeError):
        canonical = False
    if not canonical:
        raise AdmissionError('staging root must be an existing canonical directory')


def validate_inventory():
    sources, destinations = set(), set()
    for pin in PINS:
        if any(not re.fullmatch(r'[A-Za-z0-9_.-]+', part) or part in ('.', '..')
               for path in (pin.path, pin.target) for part in path.split('/')):
            raise AdmissionError('unsafe staging inventory path')
        if pin.path in sources or pin.target in destinations:
            raise AdmissionError('duplicate staging inventory path')
        if pin.size <= 0 or not re.fullmatch(r'[0-9a-f]{128}', pin.sha512):
            raise AdmissionError('invalid staging pin')
        sources.add(pin.path)
        destinations.add(pin.target)


def stage(output, fetch, check=lambda: None):
    """Return an all-or-nothing private tree; fetch is injected only by offline tests."""
    canonical_dir(output)
    info = output.stat()
    if info.st_uid != os.getuid() or info.st_mode & 0o077 or any(output.iterdir()):
        raise AdmissionError('staging requires a private, owned, fresh empty root')
    validate_inventory()
    # TemporaryDirectory cleans all unadmitted bytes, including on handled interruption.
    with tempfile.TemporaryDirectory(prefix='.partial-', dir=output) as partial:
        pending = Path(partial)
        for pin in PINS:
            check()
            path = pending / pin.target
            path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            fetch(pin, path)
            try:
                info = path.lstat()
                if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
                    raise AdmissionError(f'{path.name}: not a private regular file')
                if info.st_size != pin.size:
                    raise AdmissionError(f'{path.name}: expected {pin.size} bytes, got {info.st_size}')
                digest = hashlib.sha512()
                with path.open('rb') as stream:
                    for block in iter(lambda: stream.read(1024 * 1024), b''):
                        check()
                        digest.update(block)
            except OSError:
                raise AdmissionError(f'{path.name}: staged file missing or unreadable') from None
            if digest.hexdigest() != pin.sha512:
                raise AdmissionError(f'{path.name}: SHA-512 mismatch')
            path.chmod(0o400)
        check()
        ready = output / 'verified'
        if ready.exists() or ready.is_symlink():
            raise AdmissionError('staging destination already exists')
        pending.rename(ready)
    return ready


def main():
    children = Children()
    for signum in (signal.SIGINT, signal.SIGTERM):
        signal.signal(signum, children.cancel)
    try:
        runner_temp = Path(os.environ.get('RUNNER_TEMP', ''))
        canonical_dir(runner_temp)
        output = os.environ.get('GITHUB_OUTPUT')
        if not output or any(ch in str(runner_temp) for ch in '\r\n'):
            raise AdmissionError('expected GitHub step output and a single-line runner temp path')
        scratch = Path(tempfile.mkdtemp(prefix='compose-admission-', dir=runner_temp))
        published = False
        try:
            ready = stage(scratch, lambda pin, path: download(children, pin, path), children.check)
            with open(output, 'a', encoding='utf-8') as stream:
                children.check()
                stream.write(f'stage={ready}\n')
            published = True
        finally:
            if not published:
                shutil.rmtree(scratch)
        # The successful step hands the complete stage to the hosted job, not to
        # the Gradle launcher. Runner teardown owns removal, even on gate cancellation.
        print('Compose Robolectric: verified API 28/30/34 runtimes, API 36 compile resources and native distribution', flush=True)
        return 0
    except Cancelled as exc:
        print('Compose Robolectric: cancelled before publishing the stage', file=sys.stderr)
        return 128 + int(exc.args[0])
    except (AdmissionError, OSError) as exc:
        print(f'Compose Robolectric: {exc}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    if len(sys.argv) != 1:
        sys.exit('usage: compose_robolectric.py')
    sys.exit(main())

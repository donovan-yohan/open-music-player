"""Stage the exact Robolectric SDKs used by the Native Android host-test job."""
import hashlib
from pathlib import Path
import re
import subprocess
import sys
import tempfile


CENTRAL = 'https://repo.maven.apache.org/maven2/org/robolectric/android-all-instrumented'
# Robolectric 4.16: both classes run on API 34; SandboxManager also supplies the
# highest supported compile-resource SDK (API 35 on JDK 17; API 36 requires 21).
# SHA-512 pins match both Maven Central hosts' sidecars and downloaded JAR bytes.
SDK_PINS = {
    '14-robolectric-10818077-i7': '7cdc0b1306e7865f1acd25a363073149654caee5b8e278c5ae37ff4724185724eff39f0b0111800b521e640bb28698d9d2e655134a801569a0f07470e7b5f455',
    '15-robolectric-13954326-i7': '5fc64ffccf4788154162686b3966ddd63abea8326542c465e2a7f0129fc92770d0e1e8ddcfabd7f1500e491ec02e3b4104b9e51b61fccd9cf08006c9dc02987c',
}


def stage_sdk(output):
    # TemporaryDirectory owns partials; publish the directory only after all
    # pins pass. No cache, Maven local repository or alternate host is writable.
    with tempfile.TemporaryDirectory(prefix='sdk-staging-', dir=output) as staging:
        verified = Path(staging) / 'robolectric-sdk'
        verified.mkdir(mode=0o700)
        for version, digest in SDK_PINS.items():
            name = f'android-all-instrumented-{version}.jar'
            jar = verified / name
            try:
                result = subprocess.run([
                    'curl', '--disable', '--silent', '--fail', '--proto', '=https',
                    '--connect-timeout', '8', '--max-time', '30', '--retry', '2',
                    '--retry-max-time', '40', '--max-filesize', '210000000',
                    '--output', str(jar), '--write-out', '%{http_code}',
                    f'{CENTRAL}/{version}/{name}',
                ], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=75)
            except subprocess.TimeoutExpired:
                raise SystemExit(f'Robolectric SDK staging: {version}: transfer deadline') from None
            except OSError:
                raise SystemExit(f'Robolectric SDK staging: {version}: cannot launch downloader') from None
            if result.returncode or result.stdout != b'200':
                status = result.stdout.decode('ascii') if re.fullmatch(rb'[0-9]{3}', result.stdout) else 'unknown'
                raise SystemExit(f'Robolectric SDK staging: {version}: HTTP {status}, curl exit {result.returncode}')
            try:
                with jar.open('rb') as stream:
                    actual = hashlib.file_digest(stream, 'sha512').hexdigest()
            except OSError:
                raise SystemExit(f'Robolectric SDK staging: {version}: staged JAR missing or unreadable') from None
            if actual != digest:
                raise SystemExit(f'Robolectric SDK staging: {version}: SHA-512 mismatch')
            jar.chmod(0o400)
        sdk_dir = output / 'robolectric-sdk'
        # output is the workflow's fresh 0700 mkdtemp; never overwrite an SDK.
        if sdk_dir.exists() or sdk_dir.is_symlink():
            raise SystemExit('Robolectric SDK staging: destination already exists')
        verified.rename(sdk_dir)
    print('Robolectric SDK staging: verified API 34 runtime and API 35 compile resources', flush=True)
    return sdk_dir


def report_presentation_failure(phase, output, test_class):
    """Print a bounded, allowlisted setup classification, never log/XML bytes."""
    signals = {
        b'SSLHandshakeException': 'tls-handshake',
        b'UnknownHostException': 'dns-resolution',
        b'SocketTimeoutException': 'socket-timeout',
        b'Server returned HTTP response code:': 'http-refusal',
        b'SHA-512 mismatch': 'checksum-mismatch',
        b'Failed to fetch maven artifact org.robolectric:android-all-instrumented:': 'sdk-maven-fetch',
        b'Path is not a file:': 'sdk-file-missing',
        b'Unable to read file:': 'sdk-file-unreadable',
        b'Could not resolve all files for configuration': 'gradle-dependency-resolution',
    }
    found = set()
    xml_name = f'project/app/build/test-results/testDebugUnitTest/TEST-com.soundq.nativepreview.{test_class}.xml'
    reports = 0
    try:
        for work in (output, *sorted(output.iterdir())[:9]):
            xml = work / xml_name
            with_log = work / 'gradle.log'
            for path in (xml, with_log):
                if not path.is_file():
                    continue
                reports += path == xml
                with path.open('rb') as stream:
                    text = stream.read(128 * 1024)
                found.update(label for token, label in signals.items() if token in text)
    except OSError:
        found.add('diagnostic-read-unavailable')
    print(f'Native Android presentation failure ({phase}): {reports} JUnit report(s); '
          + (', '.join(sorted(found)) if found else 'no classified setup cause'), file=sys.stderr)

"""Build actual-file oracles against the canonical Android callback sources."""
from pathlib import Path
import subprocess


def build_file_oracle(build: Path, decoder: Path, fixture: str) -> Path:
    host = Path(__file__).resolve().parents[1]
    directory = build.resolve() / 'host-build'
    target = f'{fixture}-file-test'
    config = 'Debug'
    subprocess.run([
        'cmake', '-S', str(host), '-B', str(directory),
        f'-DCMAKE_BUILD_TYPE={config}', '-DSOUNDQ_CALLBACK_TESTS=ON',
        '-DSOUNDQ_CALLBACK_SANITIZE=ON',
        f'-DSOUNDQ_CALLBACK_FIXTURE_DECODER={decoder.resolve(strict=True)}',
    ], check=True)
    subprocess.run([
        'cmake', '--build', str(directory), '--config', config, '--target', target, '--parallel', '2',
    ], check=True)
    receipt = directory / 'file-oracles' / config / f'{target}.path'
    return Path(receipt.read_text(encoding='utf-8'))

#!/usr/bin/env python3
"""Regenerate Sound Q logo/icon PNG assets from the checked-in SVG source."""
from __future__ import annotations

import argparse
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_SOURCE = ROOT / 'client/assets/brand/soundq-logo.svg'

TARGETS = {
    ROOT / 'client/assets/brand/soundq-logo.png': 1024,
    ROOT / 'client/web/favicon.png': 32,
    ROOT / 'client/web/icons/Icon-192.png': 192,
    ROOT / 'client/web/icons/Icon-512.png': 512,
    ROOT / 'client/web/icons/Icon-maskable-192.png': 192,
    ROOT / 'client/web/icons/Icon-maskable-512.png': 512,
    ROOT / 'client/android/app/src/main/res/mipmap-mdpi/ic_launcher.png': 48,
    ROOT / 'client/android/app/src/main/res/mipmap-hdpi/ic_launcher.png': 72,
    ROOT / 'client/android/app/src/main/res/mipmap-xhdpi/ic_launcher.png': 96,
    ROOT / 'client/android/app/src/main/res/mipmap-xxhdpi/ic_launcher.png': 144,
    ROOT / 'client/android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png': 192,
    ROOT / 'extension/icons/icon16.png': 16,
    ROOT / 'extension/icons/icon48.png': 48,
    ROOT / 'extension/icons/icon128.png': 128,
    ROOT / 'extension/assets/icon-16.png': 16,
    ROOT / 'extension/assets/icon-48.png': 48,
    ROOT / 'extension/assets/icon-128.png': 128,
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        '--source',
        type=Path,
        default=DEFAULT_SOURCE,
        help='Square SVG source to render into platform icon assets.',
    )
    return parser.parse_args()


def main() -> None:
    if not shutil.which('ffmpeg'):
        raise SystemExit(
            "Error: 'ffmpeg' executable not found in PATH.\n"
            'Install ffmpeg to regenerate the Sound Q brand assets.'
        )

    args = parse_args()
    source = args.source.resolve()
    if not source.exists():
        raise SystemExit(f'missing source logo: {source}')

    for target, size in TARGETS.items():
        target.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(
            [
                'ffmpeg',
                '-y',
                '-v',
                'error',
                '-i',
                str(source),
                '-vf',
                f'scale={size}:{size}:flags=lanczos,format=rgba',
                '-frames:v',
                '1',
                str(target),
            ],
            check=True,
        )
        print(f'wrote {target.relative_to(ROOT)} {size}x{size}')


if __name__ == '__main__':
    main()

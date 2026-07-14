#!/usr/bin/env python3
"""Generate or verify the committed Sound Q raster brand assets."""
from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import struct
import subprocess
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT_PATH = Path(__file__).resolve()
MANIFEST_PATH = ROOT / 'client/assets/brand/soundq-brand-assets.json'
CANONICAL_SOURCE = 'client/assets/brand/soundq-logo.png'
RESTORED_CANONICAL_SOURCE_SHA256 = '8b8ec5737c39efab15cc513772ee83360bda623c7aaf02aaa0cb4bc0c4e589f8'
GENERATOR_PATH = 'scripts/generate_soundq_brand_assets.py'
GENERATOR_REVISION = 'soundq-brand-assets-v4'
EXPECTED_FFMPEG_VERSION = 'ffmpeg version 5.1.9-0+deb12u1'
MASKABLE_SAFE_SCALE_NUMERATOR = 9
MASKABLE_SAFE_SCALE_DENOMINATOR = 16
RENDERER_METADATA = {
    'dependency': 'FFmpeg 5.1.9-0+deb12u1 with librsvg (Debian 12 package)',
    'check_requires_renderer': False,
}

TARGETS = {
    'client/web/favicon.png': (32, CANONICAL_SOURCE, 'canonical'),
    'client/web/icons/Icon-192.png': (192, CANONICAL_SOURCE, 'canonical'),
    'client/web/icons/Icon-512.png': (512, CANONICAL_SOURCE, 'canonical'),
    'client/web/icons/Icon-maskable-192.png': (192, CANONICAL_SOURCE, 'maskable-safe-zone'),
    'client/web/icons/Icon-maskable-512.png': (512, CANONICAL_SOURCE, 'maskable-safe-zone'),
    'client/android/app/src/main/res/mipmap-mdpi/ic_launcher.png': (48, CANONICAL_SOURCE, 'canonical'),
    'client/android/app/src/main/res/mipmap-hdpi/ic_launcher.png': (72, CANONICAL_SOURCE, 'canonical'),
    'client/android/app/src/main/res/mipmap-xhdpi/ic_launcher.png': (96, CANONICAL_SOURCE, 'canonical'),
    'client/android/app/src/main/res/mipmap-xxhdpi/ic_launcher.png': (144, CANONICAL_SOURCE, 'canonical'),
    'client/android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png': (192, CANONICAL_SOURCE, 'canonical'),
    'extension/assets/icon-16.png': (16, CANONICAL_SOURCE, 'canonical'),
    'extension/assets/icon-48.png': (48, CANONICAL_SOURCE, 'canonical'),
    'extension/assets/icon-128.png': (128, CANONICAL_SOURCE, 'canonical'),
    'extension/icons/icon16.png': (16, CANONICAL_SOURCE, 'canonical'),
    'extension/icons/icon48.png': (48, CANONICAL_SOURCE, 'canonical'),
    'extension/icons/icon128.png': (128, CANONICAL_SOURCE, 'canonical'),
}

GENERATED_SCOPES = {
    'client/assets/brand': '*.png',
    'client/web': '*.png',
    'client/web/icons': '*.png',
    'client/android/app/src/main/res/mipmap-mdpi': '*.png',
    'client/android/app/src/main/res/mipmap-hdpi': '*.png',
    'client/android/app/src/main/res/mipmap-xhdpi': '*.png',
    'client/android/app/src/main/res/mipmap-xxhdpi': '*.png',
    'client/android/app/src/main/res/mipmap-xxxhdpi': '*.png',
    'extension/assets': '*.png',
    'extension/icons': '*.png',
}


class BrandAssetError(Exception):
    pass


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        '--check',
        action='store_true',
        help='Verify committed metadata and PNGs without invoking a renderer.',
    )
    return parser.parse_args()


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def png_chunks(path: Path) -> tuple[dict[str, int], bytes]:
    data = path.read_bytes()
    if data[:8] != b'\x89PNG\r\n\x1a\n':
        raise BrandAssetError(f'{path.relative_to(ROOT)}: invalid PNG signature')
    offset = 8
    header = None
    compressed = bytearray()
    while offset < len(data):
        length = struct.unpack('>I', data[offset:offset + 4])[0]
        kind = data[offset + 4:offset + 8]
        payload = data[offset + 8:offset + 8 + length]
        offset += 12 + length
        if kind == b'IHDR':
            values = struct.unpack('>IIBBBBB', payload)
            header = dict(zip(
                ('width', 'height', 'bit_depth', 'color_type', 'compression', 'filter', 'interlace'),
                values,
            ))
        elif kind == b'IDAT':
            compressed.extend(payload)
        elif kind == b'IEND':
            break
    if header is None:
        raise BrandAssetError(f'{path.relative_to(ROOT)}: missing PNG header')
    return header, bytes(compressed)


def paeth(left: int, above: int, upper_left: int) -> int:
    estimate = left + above - upper_left
    distances = (abs(estimate - left), abs(estimate - above), abs(estimate - upper_left))
    return (left, above, upper_left)[distances.index(min(distances))]


def png_pixels(path: Path) -> tuple[int, int, list[list[tuple[int, int, int, int]]]]:
    header, compressed = png_chunks(path)
    if header['bit_depth'] != 8 or header['color_type'] not in (2, 6):
        raise BrandAssetError(f'{path.relative_to(ROOT)}: expected 8-bit RGB/RGBA PNG')
    if header['compression'] or header['filter'] or header['interlace']:
        raise BrandAssetError(f'{path.relative_to(ROOT)}: unsupported PNG encoding')
    channels = 4 if header['color_type'] == 6 else 3
    width = header['width']
    height = header['height']
    stride = width * channels
    raw = zlib.decompress(compressed)
    expected_length = height * (stride + 1)
    if len(raw) != expected_length:
        raise BrandAssetError(f'{path.relative_to(ROOT)}: invalid decompressed length')

    rows: list[bytearray] = []
    offset = 0
    previous = bytearray(stride)
    for _ in range(height):
        filter_type = raw[offset]
        encoded = raw[offset + 1:offset + 1 + stride]
        offset += stride + 1
        decoded = bytearray(stride)
        for index, value in enumerate(encoded):
            left = decoded[index - channels] if index >= channels else 0
            above = previous[index]
            upper_left = previous[index - channels] if index >= channels else 0
            if filter_type == 0:
                predictor = 0
            elif filter_type == 1:
                predictor = left
            elif filter_type == 2:
                predictor = above
            elif filter_type == 3:
                predictor = (left + above) // 2
            elif filter_type == 4:
                predictor = paeth(left, above, upper_left)
            else:
                raise BrandAssetError(f'{path.relative_to(ROOT)}: unknown PNG filter {filter_type}')
            decoded[index] = (value + predictor) & 0xff
        rows.append(decoded)
        previous = decoded

    pixels = []
    for row in rows:
        pixel_row = []
        for index in range(0, len(row), channels):
            red, green, blue = row[index:index + 3]
            alpha = row[index + 3] if channels == 4 else 255
            pixel_row.append((red, green, blue, alpha))
        pixels.append(pixel_row)
    return width, height, pixels


def is_orange(pixel: tuple[int, int, int, int]) -> bool:
    red, green, blue, alpha = pixel
    return alpha >= 192 and red >= 180 and 30 <= green <= 150 and blue <= 48


def is_cream(pixel: tuple[int, int, int, int]) -> bool:
    red, green, blue, alpha = pixel
    return alpha >= 192 and red >= 220 and green >= 215 and blue >= 190


def is_teal(pixel: tuple[int, int, int, int]) -> bool:
    red, green, blue, alpha = pixel
    return alpha >= 192 and 20 <= red <= 100 and 110 <= green <= 190 and 100 <= blue <= 185


def validate_canonical_source() -> None:
    path = ROOT / CANONICAL_SOURCE
    if digest(path) != RESTORED_CANONICAL_SOURCE_SHA256:
        raise BrandAssetError(
            f'{CANONICAL_SOURCE}: must match the restored b0eca3d striped-Q source asset'
        )
    header, _ = png_chunks(path)
    if (header['width'], header['height']) != (1024, 1024):
        raise BrandAssetError(f'{CANONICAL_SOURCE}: expected 1024x1024 source dimensions')
    assert_striped_q_acceptance(path)


def assert_maskable_geometry(path: Path, size: int) -> None:
    safe_side = size * MASKABLE_SAFE_SCALE_NUMERATOR // MASKABLE_SAFE_SCALE_DENOMINATOR
    if safe_side * MASKABLE_SAFE_SCALE_DENOMINATOR != size * MASKABLE_SAFE_SCALE_NUMERATOR:
        raise BrandAssetError(f'{path.relative_to(ROOT)}: non-integral safe-zone scale')
    # A centered square is inside the guaranteed radius when side/sqrt(2) <= 0.4 * size.
    if 25 * safe_side * safe_side > 8 * size * size:
        raise BrandAssetError(f'{path.relative_to(ROOT)}: declared render exceeds maskable safe circle')

    width, height, pixels = png_pixels(path)
    orange_pixels = [
        (x, y)
        for y, row in enumerate(pixels)
        for x, pixel in enumerate(row)
        if is_orange(pixel)
    ]
    if not orange_pixels:
        raise BrandAssetError(f'{path.relative_to(ROOT)}: mark has no orange pixels')
    for x, y in orange_pixels:
        delta_x = 2 * x + 1 - size
        delta_y = 2 * y + 1 - size
        if 25 * (delta_x * delta_x + delta_y * delta_y) > 16 * size * size:
            raise BrandAssetError(f'{path.relative_to(ROOT)}: mark escapes maskable safe circle')
    if (width, height) != (size, size):
        raise BrandAssetError(f'{path.relative_to(ROOT)}: maskable dimensions changed')


def assert_striped_q_acceptance(path: Path) -> None:
    _, _, pixels = png_pixels(path)
    cream = sum(is_cream(pixel) for row in pixels for pixel in row)
    teal = sum(is_teal(pixel) for row in pixels for pixel in row)
    if not cream:
        raise BrandAssetError(f'{path.relative_to(ROOT)}: striped Q mark has no cream left glyph')
    if not teal:
        raise BrandAssetError(f'{path.relative_to(ROOT)}: striped Q mark has no teal center')


def expected_sources() -> dict[str, str]:
    return {
        CANONICAL_SOURCE: digest(ROOT / CANONICAL_SOURCE),
    }


def expected_inventory() -> set[str]:
    found = set()
    for directory, pattern in GENERATED_SCOPES.items():
        found.update(path.relative_to(ROOT).as_posix() for path in (ROOT / directory).glob(pattern))
    found.discard(CANONICAL_SOURCE)
    return found


def manifest_output(relative: str) -> dict[str, object]:
    size, source, render = TARGETS[relative]
    return {
        'width': size,
        'height': size,
        'source': source,
        'render': render,
        'sha256': digest(ROOT / relative),
    }


def renderer_details() -> dict[str, object]:
    ffmpeg = shutil.which('ffmpeg')
    if not ffmpeg:
        raise BrandAssetError("generation requires 'ffmpeg' in PATH")
    result = subprocess.run([ffmpeg, '-version'], text=True, capture_output=True, check=True)
    lines = result.stdout.splitlines()
    if not lines or not lines[0].startswith(EXPECTED_FFMPEG_VERSION):
        actual = lines[0] if lines else 'unknown'
        raise BrandAssetError(f'expected {EXPECTED_FFMPEG_VERSION}; found {actual}')
    configuration = next((line for line in lines if line.startswith('configuration:')), '')
    if '--enable-librsvg' not in configuration:
        raise BrandAssetError('generation requires FFmpeg built with --enable-librsvg')
    return dict(RENDERER_METADATA)


def render(relative: str) -> None:
    size, source, render_kind = TARGETS[relative]
    target = ROOT / relative
    target.parent.mkdir(parents=True, exist_ok=True)
    if render_kind == 'maskable-safe-zone':
        safe_side = size * MASKABLE_SAFE_SCALE_NUMERATOR // MASKABLE_SAFE_SCALE_DENOMINATOR
        video_filter = (
            f'scale={safe_side}:{safe_side}:flags=lanczos,format=rgba,'
            f'pad={size}:{size}:(ow-iw)/2:(oh-ih)/2:color=0x050505ff'
        )
    elif render_kind == 'micro':
        video_filter = f'scale={size}:{size}:flags=neighbor,format=rgba'
    else:
        video_filter = f'scale={size}:{size}:flags=lanczos,format=rgba'
    subprocess.run([
        'ffmpeg', '-y', '-v', 'error', '-i', str(ROOT / source),
        '-vf', video_filter, '-frames:v', '1', str(target),
    ], check=True)
    print(f'wrote {relative} {size}x{size} ({render_kind})')


def write_manifest(renderer: dict[str, object]) -> None:
    manifest = {
        'schema_version': 1,
        'generator': {
            'path': GENERATOR_PATH,
            'revision': GENERATOR_REVISION,
            'sha256': digest(SCRIPT_PATH),
        },
        'renderer': renderer,
        'sources': expected_sources(),
        'outputs': {relative: manifest_output(relative) for relative in sorted(TARGETS)},
    }
    MANIFEST_PATH.write_text(json.dumps(manifest, indent=2, sort_keys=True) + '\n', encoding='utf-8')
    print(f'wrote {MANIFEST_PATH.relative_to(ROOT)}')


def check_manifest() -> None:
    if not MANIFEST_PATH.is_file():
        raise BrandAssetError(f'missing generated manifest: {MANIFEST_PATH.relative_to(ROOT)}')
    try:
        manifest = json.loads(MANIFEST_PATH.read_text(encoding='utf-8'))
    except (OSError, json.JSONDecodeError) as exc:
        raise BrandAssetError(f'invalid generated manifest: {exc}') from exc

    expected_generator = {
        'path': GENERATOR_PATH,
        'revision': GENERATOR_REVISION,
        'sha256': digest(SCRIPT_PATH),
    }
    if manifest.get('schema_version') != 1:
        raise BrandAssetError('generated manifest schema version changed')
    if manifest.get('generator') != expected_generator:
        raise BrandAssetError('generator revision/hash is stale')
    if manifest.get('sources') != expected_sources():
        raise BrandAssetError('canonical or micro source hash is stale')
    if manifest.get('renderer') != RENDERER_METADATA:
        raise BrandAssetError('generation dependency metadata is stale')

    outputs = manifest.get('outputs')
    if not isinstance(outputs, dict) or set(outputs) != set(TARGETS):
        raise BrandAssetError('generated manifest output inventory is stale')
    actual_inventory = expected_inventory()
    unexpected = sorted(actual_inventory - set(TARGETS))
    missing = sorted(set(TARGETS) - actual_inventory)
    if unexpected or missing:
        details = []
        if missing:
            details.append('missing outputs: ' + ', '.join(missing))
        if unexpected:
            details.append('unexpected outputs: ' + ', '.join(unexpected))
        raise BrandAssetError('; '.join(details))

    for relative in sorted(TARGETS):
        expected = outputs[relative]
        size, source, render_kind = TARGETS[relative]
        declared = {
            'width': size,
            'height': size,
            'source': source,
            'render': render_kind,
            'sha256': digest(ROOT / relative),
        }
        if expected != declared:
            raise BrandAssetError(f'{relative}: dimensions, source, render, or hash is stale')
        header, _ = png_chunks(ROOT / relative)
        if (header['width'], header['height']) != (size, size):
            raise BrandAssetError(f'{relative}: expected {size}x{size}')

    for size in (192, 512):
        regular = ROOT / f'client/web/icons/Icon-{size}.png'
        maskable = ROOT / f'client/web/icons/Icon-maskable-{size}.png'
        if digest(regular) == digest(maskable):
            raise BrandAssetError(f'{maskable.relative_to(ROOT)}: must differ from regular icon')
        assert_maskable_geometry(maskable, size)
    if digest(ROOT / 'extension/assets/icon-16.png') != digest(ROOT / 'extension/icons/icon16.png'):
        raise BrandAssetError('16px extension micro outputs differ')


def main() -> None:
    args = parse_args()
    try:
        validate_canonical_source()
        if args.check:
            check_manifest()
            print(f'validated {len(TARGETS)} generated Sound Q brand assets without a renderer')
            return
        renderer = renderer_details()
        for relative in TARGETS:
            render(relative)
        write_manifest(renderer)
        check_manifest()
    except (BrandAssetError, OSError, subprocess.CalledProcessError, zlib.error) as exc:
        raise SystemExit(f'brand asset validation failed: {exc}') from exc


if __name__ == '__main__':
    main()

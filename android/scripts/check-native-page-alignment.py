#!/usr/bin/env python3
"""Require every packaged 64-bit native library to support 16 KiB pages."""
import argparse
import struct
import zipfile
from pathlib import Path


def check(apk):
    failures = []
    checked = []
    with zipfile.ZipFile(apk) as archive, open(apk, 'rb') as source:
        for entry in archive.infolist():
            if not entry.filename.startswith(('lib/arm64-v8a/', 'lib/x86_64/')) or not entry.filename.endswith('.so'):
                continue
            payload = archive.read(entry)
            assert payload[:6] == b'\x7fELF\x02\x01', entry.filename
            header = struct.unpack_from('<16sHHIQQQIHHHHHH', payload)
            offset, size, count = header[5], header[9], header[10]
            assert size >= 56 and offset + size * count <= len(payload), entry.filename
            loads = [struct.unpack_from('<IIQQQQQQ', payload, offset + i * size) for i in range(count)]
            loads = [segment for segment in loads if segment[0] == 1]
            assert loads, entry.filename
            if any(segment[7] < 16384 or (segment[2] - segment[3]) % 16384 for segment in loads):
                failures.append(entry.filename + ': ELF LOAD alignment')
            if entry.compress_type == zipfile.ZIP_STORED:
                source.seek(entry.header_offset)
                local = struct.unpack('<IHHHHHIIIHH', source.read(30))
                data_offset = entry.header_offset + 30 + local[-2] + local[-1]
                if data_offset % 16384:
                    failures.append(entry.filename + ': APK data alignment')
            checked.append(entry.filename)
    assert checked, 'No packaged 64-bit native libraries'
    if failures:
        raise AssertionError('\n'.join(failures))
    return checked


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('apk', type=Path)
    args = parser.parse_args()
    for name in check(args.apk):
        print('PASS', name)

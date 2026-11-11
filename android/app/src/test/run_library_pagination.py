#!/usr/bin/env python3
"""Run focused production Kotlin pagination checks without Gradle or Android.

Only LibraryTrackCapture's exact declaration is extracted from its larger owner.
Compose observer rendering remains an Android instrumentation obligation.
"""
import argparse
import os
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "scripts"))
from host_probe import scratch_root, gradle_cache, kotlin_plugin, android_jar
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--repository", type=Path, help="Replay against preserved LibraryRepository.kt")
parser.add_argument("--product", action="store_true", help="Include pure near-bottom policy tests")
args = parser.parse_args()
android = Path(__file__).resolve().parents[3]
main = android / "app/src/main/kotlin/com/soundq/android"
tests = android / "app/src/test/kotlin/com/soundq/android"
cache = gradle_cache() / 'modules-2/files-2.1'
scratch = scratch_root()


def jar(group, artifact, version):
    matches = list((cache / group / artifact / version).glob(f"*/{artifact}-{version}.jar"))
    if len(matches) != 1:
        raise SystemExit(f"Expected one cached jar for {group}:{artifact}:{version}; got {matches}")
    return str(matches[0])


cp = os.pathsep.join([
    jar("junit", "junit", "4.13.2"),
    jar("org.hamcrest", "hamcrest-core", "1.3"),
    jar("org.jetbrains.kotlinx", "kotlinx-coroutines-core-jvm", "1.10.2"),
    jar("com.squareup.okhttp3", "okhttp", "4.12.0"),
    jar("com.squareup.okio", "okio-jvm", "3.6.0"),
])
with tempfile.TemporaryDirectory(prefix="soundq-pagination-", dir=scratch) as directory:
    output = Path(directory)
    capture_source = (main / "data/playlists/PlaylistMembershipRepository.kt").read_text()
    declaration = next(line for line in capture_source.splitlines() if line.startswith("class LibraryTrackCapture "))
    capture = output / "LibraryTrackCapture.kt"
    capture.write_text("package com.soundq.android.data.playlists\nimport com.soundq.android.data.*\n" + declaration + "\n")
    sources = [
        main / "data/Contracts.kt", main / "data/AccountSession.kt",
        args.repository or main / "data/LibraryRepository.kt", capture,
        tests / "data/AccountSessionTest.kt", tests / "data/LibraryPaginationRepositoryTest.kt",
        tests / "data/LibraryRepositoryTest.kt", tests / "data/LibraryMetadataOwnershipTest.kt",
        tests / "data/LibraryRowOwnershipTest.kt", tests / "data/RefusedSiblingReadbackTest.kt",
    ]
    classes = ["AccountSessionTest", "LibraryPaginationRepositoryTest", "LibraryRepositoryTest", "LibraryMetadataOwnershipTest", "LibraryRowOwnershipTest", "RefusedSiblingReadbackTest"]
    names = ["com.soundq.android.data." + name for name in classes]
    if args.product:
        sources += [main / "product/LibraryPaginationPolicy.kt", tests / "product/LibraryPaginationPolicyTest.kt"]
        names.append("com.soundq.android.product.LibraryPaginationPolicyTest")
    env = dict(os.environ, TMPDIR=str(scratch))
    compile_command = ["kotlinc", *map(str, sources), "-cp", cp, "-d", str(output / "checks.jar")]
    compiled = subprocess.run(compile_command, env=env, check=False)
    if compiled.returncode:
        raise SystemExit(compiled.returncode)
    executed = subprocess.run(["kotlin", "-cp", str(output / "checks.jar") + os.pathsep + cp, "org.junit.runner.JUnitCore", *names], env=env, check=False)
    raise SystemExit(executed.returncode)

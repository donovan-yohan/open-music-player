"""Explicit local prerequisites for optional source-extraction probes.

These probes consume a populated dependency cache. The root android-product
launcher remains the supported clean-build/test path.
"""
import os
from pathlib import Path


def directory(name):
    value = os.environ.get(name)
    if not value:
        raise SystemExit(f"Set {name} to an existing absolute directory")
    path = Path(value)
    if not path.is_absolute() or not path.is_dir() or path.resolve() != path:
        raise SystemExit(f"{name} must be an existing canonical absolute directory")
    return path


def scratch_root():
    return directory("TMPDIR")


def gradle_cache():
    path = directory("GRADLE_USER_HOME") / "caches"
    if not path.is_dir():
        raise SystemExit("GRADLE_USER_HOME must contain a populated caches directory; run the root Android product setup first")
    return path


def kotlin_plugin(name):
    path = directory("KOTLIN_HOME") / "lib" / name
    if not path.is_file():
        raise SystemExit(f"KOTLIN_HOME is missing lib/{name}; use a compatible Kotlin distribution")
    return str(path)


def android_jar():
    path = directory("ANDROID_HOME") / "platforms/android-37.0/android.jar"
    if not path.is_file():
        raise SystemExit("ANDROID_HOME is missing platforms/android-37.0/android.jar")
    return path

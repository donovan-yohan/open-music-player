"""Discover read-only native test dependencies without personal path literals."""
import os
from pathlib import Path
import shutil
import sys


def java_home():
    for name in ('SOUNDQ_JAVA_HOME', 'JAVA_HOME'):
        if os.environ.get(name):
            root = Path(os.environ[name])
            break
    else:
        javac = shutil.which('javac')
        root = Path(javac).resolve().parent.parent if javac else Path()
    if not all((root/'bin'/tool).is_file() for tool in ('java', 'javap')):
        raise RuntimeError('A JDK is required; set SOUNDQ_JAVA_HOME or JAVA_HOME to its home directory')
    return root


def android_sdk():
    for name in ('ANDROID_HOME', 'ANDROID_SDK_ROOT'):
        if os.environ.get(name):
            return Path(os.environ[name])
    return Path.home()/('Library/Android/sdk' if sys.platform == 'darwin' else 'Android/Sdk')


def android_jar():
    override = os.environ.get('SOUNDQ_ANDROID_JAR')
    path = Path(override) if override else android_sdk()/'platforms/android-36/android.jar'
    if not path.is_file():
        raise RuntimeError('Android API36 metadata is required; set ANDROID_HOME/ANDROID_SDK_ROOT or SOUNDQ_ANDROID_JAR')
    return path


def gson_jar():
    override = os.environ.get('SOUNDQ_GSON_JAR')
    if override:
        path = Path(override)
        if not path.is_file():
            raise RuntimeError('SOUNDQ_GSON_JAR must name an existing Gson dependency JAR')
        return path
    # Prefer the SDK's active command-line tools, then versioned installations.
    tools = android_sdk()/'cmdline-tools'
    roots = [tools/'latest']+sorted((p for p in tools.glob('*') if p.name != 'latest'), reverse=True)
    for root in roots:
        matches = sorted(root.glob('lib/external/com/google/code/gson/gson/*/gson-*.jar'))
        if matches:
            return matches[-1]
    raise RuntimeError('Gson is required for the composed test; set SOUNDQ_GSON_JAR or install Android command-line tools under ANDROID_HOME')


def kotlin_compiler():
    override = os.environ.get('SOUNDQ_KOTLINC')
    path = shutil.which(override or 'kotlinc')
    if not path:
        raise RuntimeError('Kotlin compiler is required; put kotlinc on PATH or set SOUNDQ_KOTLINC')
    return path

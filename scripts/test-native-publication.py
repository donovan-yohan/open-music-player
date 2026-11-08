#!/usr/bin/env python3
"""Fast publication/tooling regressions. No SDK, account or installed app needed."""
import hashlib
import json
import os
from pathlib import Path
import runpy
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SCAN = runpy.run_path(str(ROOT / "scripts/check-native-payload.py"))
CYCLE = runpy.run_path(str(ROOT / "scripts/agentic-cycle"))
PROBE = runpy.run_path(str(ROOT / "android/scripts/host_probe.py"))


class NativePublicationTest(unittest.TestCase):
    def test_private_payload_patterns_and_portable_controls(self):
        for value in ("/Users/example/project", "/home/example/build", r"C:\Users\example\source",
                      "$HOME/.hermes/profiles/example/cache", "/opt/homebrew/bin/kotlinc"):
            with self.subTest(value=value):
                self.assertTrue(SCAN["violations"](value))
        self.assertEqual([], SCAN["violations"]('Path(os.environ["TMPDIR"]); android/design-input/tokens'))

    def test_explicit_host_probe_paths_fail_closed(self):
        with patch.dict(os.environ, {}, clear=True), self.assertRaises(SystemExit):
            PROBE["scratch_root"]()
        with tempfile.TemporaryDirectory(dir=os.environ["TMPDIR"]) as directory:
            root = Path(directory)
            alias = root / "alias"
            alias.symlink_to(root, target_is_directory=True)
            for value in ("relative", str(root / "missing"), str(alias)):
                with patch.dict(os.environ, TMPDIR=value), self.assertRaises(SystemExit):
                    PROBE["scratch_root"]()
            with patch.dict(os.environ, TMPDIR=str(root)):
                self.assertEqual(root, PROBE["scratch_root"]())
            with patch.dict(os.environ, GRADLE_USER_HOME=str(root)), self.assertRaises(SystemExit):
                PROBE["gradle_cache"]()
            with patch.dict(os.environ, KOTLIN_HOME=str(root)), self.assertRaises(SystemExit):
                PROBE["kotlin_plugin"]("kotlinx-serialization-compiler-plugin.jar")

    def test_compose_routes_to_compose_gates_and_never_flutter_install(self):
        paths = ["android/app/src/main/kotlin/com/soundq/android/product/ProductApp.kt"]
        self.assertEqual({"android-product"}, CYCLE["components_for"](paths))
        self.assertEqual("mobile-audio-device", CYCLE["risk_tier"](paths))
        gates, manual = CYCLE["plan_gates"]({"android-product"}, True, False, True, True)
        commands = [gate.command for gate in gates]
        for command in (("scripts/test", "android-product"), ("scripts/lint", "android-product"), ("scripts/build", "android-product")):
            self.assertIn(command, commands)
        self.assertNotIn(("scripts/dogfood-android", "all"), commands)
        self.assertTrue(any("Compose runtime" in gate.name for gate in manual))
        self.assertEqual({"client", "android-product"}, CYCLE["components_for"](["client/native/transport/CMakeLists.txt"]))
        self.assertEqual({"native"}, CYCLE["components_for"](["native/android/app/build.gradle.kts"]))

    def test_wire_payload_hashes_are_exact_and_complete(self):
        root = ROOT / "android/app/src/test/resources/catalog-resolution"
        hashes = json.loads((root / "wire-hashes.json").read_text())
        actual = {p.name for p in root.glob("*.json")} - {"wire-hashes.json"}
        self.assertEqual(9, len(hashes))
        self.assertEqual(actual, set(hashes))
        for name, digest in hashes.items():
            self.assertEqual(digest, hashlib.sha256((root / name).read_bytes()).hexdigest(), name)

    def test_appearance_publication_preserves_historical_hashes(self):
        root = ROOT / "android/design-input/appearance-w9"
        provenance = json.loads((root / "provenance.json").read_text())
        source = json.loads((root / "MANIFEST.json").read_text())
        self.assertEqual(source["files"]["INPUTS.json"]["sha256"], provenance["publicationTransforms"]["INPUTS.json"]["sourceSha256"])
        transform = provenance["publicationTransforms"]["INPUTS.json"]
        self.assertEqual("55c913b7f113ad22caa23f4306e865f20c3bbbb11f041dc317d72e1bbe243507", transform["sourceSha256"])
        self.assertEqual(provenance["releaseManifestSha256"], hashlib.sha256((root / "MANIFEST.json").read_bytes()).hexdigest())
        self.assertNotEqual(transform["sourceSha256"], provenance["files"]["INPUTS.json"])
        for name, digest in provenance["files"].items():
            self.assertEqual(digest, hashlib.sha256((root / name).read_bytes()).hexdigest(), name)

    def test_secret_scan_exceptions_are_exact_negative_fixtures(self):
        harness = runpy.run_path(str(ROOT / "scripts/agentic-harness"))
        for name, digest in harness["SECRET_SCAN_FIXTURES"].items():
            lines = (ROOT / name).read_text().splitlines()
            line = next(line for line in lines if hashlib.sha256(line.encode()).hexdigest() == digest)
            self.assertTrue(harness["secret_scan_fixture"](name, line))
            self.assertFalse(harness["secret_scan_fixture"]("different-file.kt", line))
            self.assertFalse(harness["secret_scan_fixture"](name, line + " changed"))

    def test_payload_refuses_local_config_and_generated_files_without_reading(self):
        import contextlib
        import io
        with tempfile.TemporaryDirectory(dir=os.environ["TMPDIR"]) as directory:
            root = Path(directory)
            names = ["android/local.properties", "android/.env", "android/release.jks",
                     "android/app/build/private.txt", "android/link.txt", "android/ok.txt"]
            for name in names[:-2]:
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("SYNTHETIC-MUST-NOT-BE-READ")
            (root / "android/link.txt").symlink_to(root / "android/local.properties")
            (root / "android/ok.txt").write_text("portable source")
            module = runpy.run_path(str(ROOT / "scripts/check-native-payload.py"))
            module["main"].__globals__["ROOT"] = root
            output = io.StringIO()
            with patch("subprocess.check_output", return_value=("\0".join(names) + "\0").encode()), \
                    patch.object(Path, "read_bytes", autospec=True, side_effect=lambda p: b"portable source" if p.name == "ok.txt" else self.fail("opened prohibited payload")), \
                    contextlib.redirect_stdout(output):
                self.assertEqual(1, module["main"]())
            result = json.loads(output.getvalue())
            self.assertEqual(5, len(result["findings"]))
            self.assertEqual(1, result["textFilesScanned"])
            self.assertNotIn("SYNTHETIC-MUST-NOT-BE-READ", output.getvalue())

    def test_asset_inventory_and_publication_guide_are_complete(self):
        root = ROOT / "android/app/src/androidTest/assets"
        inventory = json.loads((ROOT / "android/docs/test-assets.json").read_text())["files"]
        actual = {p.relative_to(root).as_posix() for p in root.rglob("*") if p.is_file()}
        self.assertEqual(actual, set(inventory))
        for name, entry in inventory.items():
            payload = (root / name).read_bytes()
            self.assertEqual(entry["sha256"], hashlib.sha256(payload).hexdigest(), name)
            self.assertEqual(entry["bytes"], len(payload), name)
        guide = ROOT / "android/docs/PUBLICATION.md"
        self.assertTrue(guide.is_file())
        self.assertIn("not audio-runtime qualification", guide.read_text())

    def test_android_artifacts_never_select_deprecated_flutter_product(self):
        ci = (ROOT / ".github/workflows/ci.yml").read_text()
        client = ci.split("  client:", 1)[1].split("  extension:", 1)[0]
        self.assertIn("name: Client (Flutter)", client)
        for command in ("scripts/test client", "scripts/lint client", "scripts/build client-web"):
            self.assertIn(command, client)
        self.assertNotIn("flutter-apk", client)
        self.assertNotIn("Build debug APK", client)
        nightly = (ROOT / ".github/workflows/nightly-apk.yml").read_text()
        self.assertIn("scripts/android-product check", nightly)
        self.assertIn("https://fixture.invalid/api/v1", nightly)
        self.assertIn("android/app/build/outputs/apk/debug/app-debug.apk", nightly)
        self.assertNotIn("flutter-action", nightly)
        self.assertNotIn("OMP_NIGHTLY_API_BASE_URL", nightly)
        self.assertNotIn("gh api -X DELETE", nightly)
        for name in ("native-clients.yml", "nightly-apk.yml"):
            workflow = (ROOT / ".github/workflows" / name).read_text()
            self.assertIn("packages: platform-tools", workflow)
            self.assertLess(workflow.index("Prepare private build directories"),
                            workflow.index("actions/setup-java@v4"))
            self.assertIn('export PATH="$ANDROID_HOME/cmake/3.22.1/bin:$PATH"', workflow)

    def test_default_android_build_and_dogfood_route_to_compose(self):
        import subprocess
        with tempfile.TemporaryDirectory(dir=os.environ["TMPDIR"]) as directory:
            root = Path(directory)
            recorder = root / "python3"
            recorder.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$RECORDED_ARGS"\n')
            recorder.chmod(0o755)
            output = root / "args.txt"
            env = dict(os.environ, PATH=str(root) + ":" + os.environ["PATH"],
                       RECORDED_ARGS=str(output), OMP_API_BASE_URL="https://fixture.invalid/api/v1")
            for command in (["bash", str(ROOT / "scripts/build"), "client"],
                            ["bash", str(ROOT / "scripts/dogfood-android"), "build"]):
                with self.subTest(command=command):
                    result = subprocess.run(command, env=env, capture_output=True, text=True)
                    self.assertEqual(0, result.returncode, result.stderr)
                    recorded = output.read_text().splitlines()
                    self.assertEqual(str(ROOT / "scripts/android-product"), recorded[0])
                    self.assertEqual("build", recorded[1])
            # Recovery stays explicit and forwards only caller-selected build inputs.
            flutter = root / "flutter"
            flutter.write_text('#!/bin/sh\nprintf "%s\\n" "$@" >> "$RECORDED_ARGS"\n')
            flutter.chmod(0o755)
            output.unlink()
            legacy_env = dict(env, OMP_SOURCE_REF="synthetic-recovery", OMP_BUILD_ID="synthetic-recovery")
            result = subprocess.run(["bash", str(ROOT / "scripts/build"), "client-flutter-android-legacy"],
                                    env=legacy_env, capture_output=True, text=True)
            self.assertEqual(0, result.returncode, result.stderr)
            recorded = output.read_text().splitlines()
            self.assertIn("apk", recorded)
            self.assertIn("--dart-define=OMP_API_BASE_URL=https://fixture.invalid/api/v1", recorded)
            self.assertIn("--dart-define=OMP_SOURCE_REF=synthetic-recovery", recorded)
            self.assertNotIn(str(ROOT / "scripts/android-product"), recorded)

    def test_dogfood_never_installs_without_explicit_native_target(self):
        import subprocess
        env = dict(os.environ, OMP_API_BASE_URL="https://fixture.invalid/api/v1")
        env.pop("ANDROID_SERIAL", None)
        result = subprocess.run(["bash", str(ROOT / "scripts/dogfood-android"), "install"],
                                env=env, capture_output=True, text=True)
        self.assertNotEqual(0, result.returncode)
        self.assertIn("ANDROID_SERIAL", result.stderr)

    def test_native_install_preserves_incompatible_app_and_reads_back_compatible_bytes(self):
        import subprocess
        with tempfile.TemporaryDirectory(dir=os.environ["TMPDIR"]) as directory:
            root = Path(directory)
            scripts = root / "scripts"
            scripts.mkdir()
            (scripts / "dogfood-android").write_bytes((ROOT / "scripts/dogfood-android").read_bytes())
            apk = root / "android/app/build/outputs/apk/debug/app-debug.apk"
            apk.parent.mkdir(parents=True)
            apk.write_bytes(b"synthetic-candidate")
            installed = root / "installed.apk"
            bin = root / "bin"
            bin.mkdir()
            tools = root / "sdk/build-tools/37.0.0"
            tools.mkdir(parents=True)
            log = root / "adb-calls.jsonl"
            fake_adb = '''#!/usr/bin/env python3
import json, os, pathlib, shutil, sys
args = sys.argv[1:]
with open(os.environ["FAKE_ADB_LOG"], "a") as f: f.write(json.dumps(args)+"\\n")
assert args[:2] == ["-s", "synthetic-only"]
a = args[2:]
installed = pathlib.Path(os.environ["FAKE_INSTALLED"])
if a == ["devices", "-l"]: print("synthetic-only device")
elif a == ["get-state"]: print("device")
elif a == ["shell", "pm", "path", "com.soundq.android.dev"]: print("package:/data/fixture/base.apk")
elif a[0] == "pull": shutil.copyfile(installed, a[2])
elif a[:2] == ["install", "-r"]: shutil.copyfile(a[2], installed); print("Success")
else: raise SystemExit("unexpected device operation")
'''
            (bin / "adb").write_text(fake_adb)
            (tools / "aapt").write_text("#!/bin/sh\nprintf \"package: name='com.soundq.android.dev'\\n\"\n")
            (tools / "apksigner").write_text('''#!/usr/bin/env python3
import os, sys
candidate = sys.argv[-1].endswith("app-debug.apk")
cert = "a" * 64 if candidate or os.environ["FAKE_MATCH"] == "1" else "b" * 64
prefix = "V2 Signer:" if candidate else "Signer #1"
print(prefix + " certificate SHA-256 digest: " + cert)
''')
            for path in (bin / "adb", tools / "aapt", tools / "apksigner"):
                path.chmod(0o755)
            env = dict(os.environ, PATH=str(bin) + ":" + os.environ["PATH"],
                       ANDROID_HOME=str(root / "sdk"), TMPDIR=str(root),
                       ANDROID_SERIAL="synthetic-only", OMP_ALLOW_ANDROID_INSTALL="1",
                       OMP_DOGFOOD_EVIDENCE_DIR=str(root / "receipts"),
                       FAKE_INSTALLED=str(installed), FAKE_ADB_LOG=str(log))
            for match in ("0", "1"):
                installed.write_bytes(b"synthetic-existing-data-owner")
                log.unlink(missing_ok=True)
                result = subprocess.run(["bash", str(scripts / "dogfood-android"), "install"],
                                        env=dict(env, FAKE_MATCH=match), capture_output=True, text=True)
                calls = [json.loads(line)[2:] for line in log.read_text().splitlines()]
                self.assertFalse(any("uninstall" in call or "clear" in call for call in calls))
                installs = [call for call in calls if call[0] == "install"]
                if match == "0":
                    self.assertNotEqual(0, result.returncode)
                    self.assertIn("Signer mismatch", result.stderr)
                    self.assertEqual([], installs)
                    self.assertEqual(b"synthetic-existing-data-owner", installed.read_bytes())
                else:
                    self.assertEqual(0, result.returncode, result.stderr)
                    self.assertEqual([["install", "-r", str(apk)]], installs)
                    self.assertEqual(apk.read_bytes(), installed.read_bytes())
                    self.assertEqual(2, sum(call[0] == "pull" for call in calls))
                    self.assertIn("APK SHA256", (root / "receipts/evidence.md").read_text())

    def test_delivery_ci_supplies_explicit_temporary_root(self):
        workflow = (ROOT / ".github/workflows/ci.yml").read_text()
        delivery = workflow.split("  delivery-harness:", 1)[1].split("  backend:", 1)[0]
        self.assertIn("TMPDIR: ${{ runner.temp }}", delivery)

    def test_vendored_source_pins_and_distributed_notices(self):
        pins = {
            "client/native/file_decoder/third_party/dr_mp3.h": "390e4e0ef0cff80fb86ebf1b461d6947cfa4ed699a4fe107e5a5e69a47db2950",
            "client/native/third_party/signalsmith/stretch.tar.gz": "4dc468e46f208415ca66567cacfd8fb22b01d321fcdb4c2452278fee2426b09d",
            "client/native/third_party/signalsmith/linear.tar.gz": "e6d6a914189894fd728111b2a3209445ecd065aa9a5c1958f41b64ac3cef8b32",
        }
        for name, digest in pins.items():
            self.assertEqual(digest, hashlib.sha256((ROOT / name).read_bytes()).hexdigest(), name)
        notices = ROOT / "android/app/src/main/assets/licenses"
        self.assertIn((notices / "dr_mp3-NOTICE.txt").read_bytes(),
                      (ROOT / "client/native/file_decoder/third_party/dr_mp3.h").read_bytes())
        self.assertEqual("cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30",
                         hashlib.sha256((notices / "oboe-LICENSE.txt").read_bytes()).hexdigest())
        for name in ("Signalsmith-Stretch-LICENSE.txt", "Signalsmith-Linear-LICENSE.txt"):
            self.assertEqual((ROOT / "client/native/third_party/signalsmith" / name).read_bytes(),
                             (ROOT / "android/app/src/main/assets/licenses" / name).read_bytes())


if __name__ == "__main__":
    unittest.main()

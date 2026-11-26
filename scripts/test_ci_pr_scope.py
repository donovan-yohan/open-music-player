"""Exercise the CI selector against real synthetic commits and shallow checkout."""

import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


SELECTOR = Path(__file__).with_name("ci_pr_scope.py").resolve()
PRODUCT_RUNBOOK = "docs/ACOUSTICBRAINZ_IMPORT.md"  # Read by the Go artifact-table contract test.


def fixture_env(**overrides):
    # Keep normal process settings (e.g. PATH and TMPDIR) but do not let Git
    # redirect fixture operations or load user/system configuration. Keep the
    # harmless hash default so the explicit fixture format can be tested.
    env = {key: value for key, value in dict(os.environ, **overrides).items()
           if not key.startswith("GIT_") or key == "GIT_DEFAULT_HASH"}
    return dict(env, GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1")


def git(path, *args):
    return subprocess.check_output(
        ["git", "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgSign=false", "-C", str(path), *args],
        env=fixture_env(), text=True,
    ).strip()


class PullRequestScopeTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="soundq-ci-pr-scope-")
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        git(self.repo, "init", "-q", "--object-format=sha1", "-b", "base")
        git(self.repo, "config", "user.name", "CI fixture")
        git(self.repo, "config", "user.email", "fixture@example.invalid")
        self.file("README.md", "original")
        self.file("docs/context-map.md", "original")
        self.file(PRODUCT_RUNBOOK, "original product input")
        self.file("scripts/release-audit", "original").chmod(0o755)
        self.file("scripts/test", "test wrapper")
        self.commit()
        git(self.repo, "branch", "topic")
        # Base moved independently after the topic fork. A topic-vs-current-base
        # diff would wrongly attribute this product input to the documentation PR.
        self.file("backend/go.sum", "base-only change")
        self.base = self.commit()
        git(self.repo, "switch", "-q", "topic")

    def file(self, name, content):
        path = self.repo / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
        return path

    def commit(self):
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "-qm", "fixture change", "--allow-empty")
        return git(self.repo, "rev-parse", "HEAD")

    def merge(self):
        self.topic = self.commit()
        git(self.repo, "switch", "-q", "base")
        git(self.repo, "merge", "-q", "--no-ff", "--no-edit", "topic")
        self.sha = git(self.repo, "rev-parse", "HEAD")
        self.assertEqual(git(self.repo, "show", "-s", "--format=%P", "HEAD"), f"{self.base} {self.topic}")

    def run_selector(self, output, checkout=None, **env_override):
        event = dict(GITHUB_EVENT_NAME="pull_request", GITHUB_SHA=self.sha,
                     PR_HEAD_SHA=self.topic, GITHUB_OUTPUT=str(output))
        event.update(env_override)
        return subprocess.run(
            [sys.executable, "-I", "-B", str(SELECTOR)], cwd=checkout or self.repo, env=fixture_env(**event),
            capture_output=True, text=True, check=False,
        )

    def route(self, expected, checkout=None, **env_override):
        output = self.root / "output"
        output.write_text("")
        result = self.run_selector(output, checkout, **env_override)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(output.read_text(), f"scope={expected}\n", result.stdout + result.stderr)

    def ambient_git(self):
        # Every redirection target is disposable, even when isolation regresses.
        ambient = self.root / "ambient"
        checkout = ambient / "checkout"
        shutil.copytree(self.repo, checkout)
        index = ambient / "alternate-index"
        shutil.copyfile(checkout / ".git/index", index)
        (checkout / "README.md").write_text("decoy edit")
        return ambient, {
            "GIT_DIR": str(checkout / ".git"),
            "GIT_WORK_TREE": str(checkout),
            "GIT_INDEX_FILE": str(index),
        }

    def test_fixture_git_mutates_only_fixture_under_inherited_git_env(self):
        ambient, env = self.ambient_git()

        def snapshot():
            return {p.relative_to(ambient): p.read_bytes() for p in ambient.rglob("*") if p.is_file()}

        before = snapshot()
        self.file("README.md", "fixture edit")
        with patch.dict(os.environ, env):
            self.commit()
        after = snapshot()
        changed = sorted(path.as_posix() for path in before.keys() | after.keys()
                         if before.get(path) != after.get(path))
        self.assertEqual(changed, [], "fixture Git changed the ambient repository or alternate index")
        self.assertEqual(git(self.repo, "show", "HEAD:README.md"), "fixture edit")

    def test_selector_routes_fixture_under_inherited_git_env(self):
        _, env = self.ambient_git()
        self.file("README.md", "doc update")
        self.merge()
        with patch.dict(os.environ, env):
            self.route("delivery-only")

    def test_fixture_uses_sha1_object_format(self):
        self.assertEqual(git(self.repo, "rev-parse", "--show-object-format"), "sha1")

    def test_modified_delivery_inputs_use_tested_base(self):
        self.file("README.md", "doc update")
        self.file("docs/context-map.md", "another doc update")
        self.file("scripts/release-audit", "audit tool update")
        self.merge()
        self.assertIn("backend/go.sum", git(self.repo, "diff", "--name-only", self.base, self.topic))
        self.route("delivery-only")

    def test_shared_wrapper_mixed_with_doc_runs_full(self):
        self.file("README.md", "doc update")
        self.file("scripts/test", "changed shared test wrapper")
        self.merge()
        self.route("full")

    def test_product_owned_markdown_is_not_deliverable_docs(self):
        self.file(PRODUCT_RUNBOOK, "updated product input")
        self.merge()
        self.assertEqual(git(self.repo, "diff", "--name-status", self.base, self.sha), f"M\t{PRODUCT_RUNBOOK}")
        self.route("full")

    def test_unrecognized_paths_are_not_allowlisted(self):
        self.file("docs/unreviewed\ncontext-map.md", "unknown")
        self.merge()
        self.route("full")

    def test_deletion_runs_full(self):
        (self.repo / "README.md").unlink()
        self.merge()
        self.route("full")

    def test_new_file_at_allowlisted_path_runs_full(self):
        self.file("CLAUDE.md", "new file at an allowlisted path")
        self.merge()
        self.route("full")

    def test_move_between_two_allowlisted_paths_runs_full(self):
        (self.repo / "docs/context-map.md").unlink()
        git(self.repo, "mv", "-f", "README.md", "docs/context-map.md")
        self.merge()
        self.route("full")

    def test_mode_change_runs_full(self):
        self.file("README.md", "doc update").chmod(0o755)
        self.merge()
        self.route("full")

    def test_symlink_runs_full(self):
        (self.repo / "README.md").unlink()
        (self.repo / "README.md").symlink_to("../backend/go.sum")
        self.merge()
        self.route("full")

    def test_empty_git_delta_runs_full(self):
        self.merge()
        self.route("full")

    def test_event_identity_and_non_pull_request_run_full(self):
        self.file("README.md", "doc update")
        self.merge()
        for env in (
            {"GITHUB_EVENT_NAME": "push"},
            {"GITHUB_SHA": self.base},
            {"PR_HEAD_SHA": self.base},
            {"PR_HEAD_SHA": ""},
        ):
            with self.subTest(env=env):
                self.route("full", **env)

    def test_pull_request_head_without_merge_runs_full(self):
        self.file("README.md", "doc update")
        self.merge()
        git(self.repo, "switch", "-q", "topic")
        self.route("full", GITHUB_SHA=self.topic)

    def test_checkout_fetch_depth_2_and_1(self):
        self.file("README.md", "doc update")
        self.merge()
        for depth, expected in ((2, "delivery-only"), (1, "full")):
            with self.subTest(depth=depth):
                detached = self.root / f"depth-{depth}"
                git(self.root, "clone", "-q", "--no-local", "--depth", str(depth), self.repo.as_uri(), str(detached))
                git(detached, "switch", "-q", "--detach", self.sha)
                self.assertEqual(git(detached, "rev-parse", "--is-shallow-repository"), "true")
                self.route(expected, checkout=detached)

    def test_missing_git_checkout_runs_full(self):
        self.file("README.md", "doc update")
        self.merge()
        empty = self.root / "no-git"
        empty.mkdir()
        self.route("full", checkout=empty)

    def test_more_than_300_changed_files_are_seen(self):
        self.file("README.md", "doc update")
        for index in range(301):
            self.file(f"docs/filler/{index:03}.md", "unknown")
        self.file("scripts/test", "changed shared test wrapper")
        self.merge()
        self.assertGreater(len(git(self.repo, "diff", "--name-only", "HEAD^1", "HEAD").splitlines()), 300)
        self.route("full")

    def test_unusable_output_file_returns_error(self):
        self.file("README.md", "doc update")
        self.merge()
        result = self.run_selector(self.root)
        self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()

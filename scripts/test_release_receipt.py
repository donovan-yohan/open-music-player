"""Offline tests for the production publication boundary."""
import importlib.util
from pathlib import Path
import unittest


class ReceiptTests(unittest.TestCase):
    def test_requires_exact_main_ci_and_owner_merged_pr(self):
        path = Path(__file__).with_name('release_receipt.py')
        self.assertTrue(path.exists(), 'release qualification implementation missing')
        spec = importlib.util.spec_from_file_location('release_receipt', path)
        assert spec is not None and spec.loader is not None
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        sha = 'a' * 40
        repo = 'donovan-yohan/open-music-player'
        run = dict(status='completed', conclusion='success', event='push', head_branch='main',
                   head_sha=sha, path='.github/workflows/ci.yml', repository={'full_name': repo})
        pr = dict(number=523, merged_at='2026-11-03T00:00:00Z', merge_commit_sha=sha,
                  base={'ref': 'main', 'repo': {'full_name': repo}})
        detail = dict(pr, merged=True, merged_by={'login': 'donovan-yohan'})
        self.assertEqual(module.qualify(run, [pr], detail, sha), 523)
        for field, value in [('conclusion', 'failure'), ('head_branch', 'feature'),
                             ('head_sha', 'b' * 40), ('event', 'pull_request'),
                             ('path', '.github/workflows/untrusted.yml')]:
            with self.subTest(field=field), self.assertRaises(ValueError):
                module.qualify(dict(run, **{field: value}), [pr], detail, sha)
        with self.assertRaises(ValueError):
            module.qualify(run, [], detail, sha)
        with self.assertRaises(ValueError):
            module.qualify(run, [pr], dict(detail, merged_by={'login': 'unknown'}), sha)


if __name__ == '__main__':
    unittest.main()

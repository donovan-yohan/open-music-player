"""Credential-free regression checks for operator diagnostics."""
import io
from email.message import Message
import unittest
from unittest.mock import patch
import urllib.error

from check import API


class ErrorRedactionTests(unittest.TestCase):
    def test_credentials_crossing_diagnostic_boundary_are_redacted(self):
        for key in ("OPENOBSERVE_AUTH", "ZO_ROOT_USER_PASSWORD"):
            with self.subTest(key=key):
                canary = "dummy-generated-credential-" + "x" * 48
                api = API({"OPENOBSERVE_AUTH": "dummy-auth", key: canary})
                body = "a" * 1480 + canary + "z" * 200
                error = urllib.error.HTTPError(api.base + "/test", 503,
                                               "unavailable", Message(), io.BytesIO(body.encode()))
                with patch("urllib.request.urlopen", side_effect=error):
                    with self.assertRaises(RuntimeError) as caught:
                        api.request("/test")
                diagnostic = str(caught.exception)
                self.assertIn("HTTP 503 for /test", diagnostic)
                self.assertIn("[REDACTED]", diagnostic)
                self.assertNotIn(canary[:20], diagnostic)
                self.assertLessEqual(len(diagnostic), 1550)

    def test_invalid_utf8_error_remains_a_bounded_safe_diagnostic(self):
        api = API({"OPENOBSERVE_AUTH": "dummy-auth"})
        error = urllib.error.HTTPError(api.base + "/test", 502, "unavailable", Message(),
                                       io.BytesIO(b"upstream invalid: \xff"))
        with patch("urllib.request.urlopen", side_effect=error):
            with self.assertRaises(RuntimeError) as caught:
                api.request("/test")
        self.assertIn("HTTP 502 for /test", str(caught.exception))


if __name__ == "__main__":
    unittest.main()

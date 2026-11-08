import hashlib
import io
import tempfile
import unittest
import urllib.error
from pathlib import Path
from unittest.mock import patch

import prepare_dependencies as dependencies


class DependencyDownloadTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.cache = Path(self.temp.name)
        self.content = b"checksum-pinned source archive"
        self.pin = {"url": "https://example.invalid/source.tar.gz",
                    "sha256": hashlib.sha256(self.content).hexdigest()}
        self.lock = patch.dict(dependencies.LOCK, {"fixture": self.pin})
        self.lock.start()
        self.addCleanup(self.lock.stop)

    @patch.object(dependencies.time, "sleep")
    @patch.object(dependencies.urllib.request, "urlopen")
    def test_retries_temporary_failure_and_caches_verified_archive(self, urlopen, sleep):
        urlopen.side_effect = [urllib.error.HTTPError(self.pin["url"], 503, "Unavailable", {}, None),
                               io.BytesIO(self.content)]
        result = dependencies.archive("fixture", self.cache)
        self.assertEqual(result.read_bytes(), self.content)
        self.assertEqual(dependencies.archive("fixture", self.cache), result)
        self.assertEqual(urlopen.call_count, 2)
        sleep.assert_called_once_with(1)
        self.assertFalse(list(self.cache.glob("*.partial")))

    @patch.object(dependencies.time, "sleep")
    @patch.object(dependencies.urllib.request, "urlopen")
    def test_permanent_failure_does_not_retry(self, urlopen, sleep):
        urlopen.side_effect = urllib.error.HTTPError(self.pin["url"], 404, "Not Found", {}, None)
        with self.assertRaises(urllib.error.HTTPError):
            dependencies.archive("fixture", self.cache)
        urlopen.assert_called_once()
        sleep.assert_not_called()
        self.assertFalse(list(self.cache.iterdir()))

    @patch.object(dependencies.time, "sleep")
    @patch.object(dependencies.urllib.request, "urlopen")
    def test_bounds_network_retries(self, urlopen, sleep):
        urlopen.side_effect = urllib.error.URLError("Connection closed")
        with self.assertRaises(urllib.error.URLError):
            dependencies.archive("fixture", self.cache)
        self.assertEqual(urlopen.call_count, 3)
        self.assertEqual([call.args for call in sleep.call_args_list], [(1,), (2,)])
        self.assertFalse(list(self.cache.iterdir()))

    @patch.object(dependencies.urllib.request, "urlopen")
    def test_never_accepts_a_checksum_mismatch(self, urlopen):
        urlopen.return_value = io.BytesIO(b"wrong source")
        with self.assertRaisesRegex(RuntimeError, "Checksum mismatch"):
            dependencies.archive("fixture", self.cache)
        urlopen.assert_called_once()
        self.assertFalse(list(self.cache.iterdir()))


if __name__ == "__main__":
    unittest.main()

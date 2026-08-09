from __future__ import annotations

import hashlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

from tools import download_public_pdf_corpus as corpus


class _Response(io.BytesIO):
    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, traceback):
        self.close()
        return False


def _digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _manifest_entry(**overrides: object) -> dict:
    entry = {
        "id": "pinned-case",
        "enabled": True,
        "title": "Pinned case",
        "url": (
            "https://raw.githubusercontent.com/example/project/"
            "0123456789abcdef0123456789abcdef01234567/test.pdf"
        ),
        "source_page": "https://github.com/example/project",
        "source_org": "Example",
        "local_path": "web-acquired/example/test.pdf",
        "expected_sha256": "0" * 64,
        "license_note": "Local-only test input.",
        "features": ["synthetic"],
        "test_intent": "Downloader contract test.",
    }
    entry.update(overrides)
    return entry


class ManifestContractTests(unittest.TestCase):
    def _load(self, entry: dict) -> dict:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "manifest.json"
            path.write_text(
                json.dumps(
                    {
                        "schema": "bcs.public_pdf_corpus/1.1",
                        "updated": "2026-08-09",
                        "default_root": "__private_validation_assets_not_configured__",
                        "description": "Synthetic test manifest.",
                        "entries": [entry],
                    }
                ),
                encoding="utf-8",
            )
            return corpus.load_manifest(path)

    def test_enabled_download_requires_exact_lowercase_sha256(self) -> None:
        for value in (None, "", "f" * 63, "F" * 64, "g" * 64, 1):
            with self.subTest(value=value):
                entry = _manifest_entry()
                if value is None:
                    entry.pop("expected_sha256")
                else:
                    entry["expected_sha256"] = value
                with self.assertRaisesRegex(SystemExit, "expected_sha256"):
                    self._load(entry)

    def test_raw_github_url_must_pin_a_full_commit(self) -> None:
        for ref in ("master", "main", "0123456"):
            with self.subTest(ref=ref):
                entry = _manifest_entry(
                    url=f"https://raw.githubusercontent.com/example/project/{ref}/test.pdf"
                )
                with self.assertRaisesRegex(SystemExit, "commit"):
                    self._load(entry)

    def test_repository_manifest_has_only_digest_bound_enabled_downloads(self) -> None:
        manifest = corpus.load_manifest(corpus.DEFAULT_MANIFEST)
        enabled = [entry for entry in manifest["entries"] if entry.get("enabled")]
        self.assertGreater(len(enabled), 0)
        for entry in enabled:
            expected = entry.get("expected_sha256")
            self.assertIsInstance(expected, str)
            if not isinstance(expected, str):
                continue
            self.assertRegex(expected, r"\A[0-9a-f]{64}\Z")
            if entry["url"].startswith("https://raw.githubusercontent.com/"):
                self.assertNotIn("/master/", entry["url"])
                self.assertNotIn("/main/", entry["url"])


class VerifiedDownloadTests(unittest.TestCase):
    def _downloader(self):
        downloader = getattr(corpus, "download_verified", None)
        self.assertTrue(callable(downloader), "download_verified API is required")
        return downloader

    def test_mismatched_download_never_publishes_target(self) -> None:
        payload = b"not the expected PDF"
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(
            corpus.urllib.request,
            "urlopen",
            return_value=_Response(payload),
        ):
            target = Path(tmp) / "case.pdf"
            downloader = self._downloader()
            with self.assertRaisesRegex(Exception, "download_digest_mismatch"):
                downloader("https://example.invalid/case.pdf", target, 1, "0" * 64)
            self.assertFalse(target.exists())
            self.assertEqual([], list(target.parent.glob("*.part*")))

    def test_existing_mismatch_is_preserved_and_network_is_not_used(self) -> None:
        existing = b"worker-owned existing bytes"
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "case.pdf"
            target.write_bytes(existing)
            downloader = self._downloader()
            with mock.patch.object(
                corpus.urllib.request,
                "urlopen",
                side_effect=AssertionError("existing mismatch must not download"),
            ):
                with self.assertRaisesRegex(Exception, "existing_digest_mismatch"):
                    downloader("https://example.invalid/case.pdf", target, 1, "0" * 64)
            self.assertEqual(existing, target.read_bytes())

    def test_verified_bytes_publish_without_replacing_a_race_winner(self) -> None:
        payload = b"%PDF-1.7\nsynthetic\n%%EOF\n"
        winner = b"foreign race winner"
        expected = _digest(payload)

        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(
            corpus.urllib.request,
            "urlopen",
            return_value=_Response(payload),
        ):
            target = Path(tmp) / "case.pdf"
            downloader = self._downloader()
            real_publish = corpus.os.link

            def race_publish(source: object, destination: object) -> None:
                Path(destination).write_bytes(winner)
                real_publish(source, destination)

            with mock.patch.object(corpus.os, "link", side_effect=race_publish):
                with self.assertRaisesRegex(Exception, "publish_conflict"):
                    downloader("https://example.invalid/case.pdf", target, 1, expected)

            self.assertEqual(winner, target.read_bytes())
            self.assertEqual([], list(target.parent.glob("*.part*")))

    def test_verified_bytes_publish_and_return_expected_digest(self) -> None:
        payload = b"%PDF-1.7\nverified\n%%EOF\n"
        expected = _digest(payload)
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(
            corpus.urllib.request,
            "urlopen",
            return_value=_Response(payload),
        ):
            target = Path(tmp) / "case.pdf"
            downloader = self._downloader()
            actual = downloader("https://example.invalid/case.pdf", target, 1, expected)
            self.assertEqual(expected, actual)
            self.assertEqual(payload, target.read_bytes())
            self.assertEqual([], list(target.parent.glob("*.part*")))


class RootBoundaryTests(unittest.TestCase):
    def test_unconfigured_placeholder_refuses_before_creating_a_repo_local_root(self) -> None:
        manifest = {"default_root": "__private_validation_assets_not_configured__"}
        with mock.patch.dict(
            corpus.os.environ,
            {"BCS_PRIVATE_VALIDATION_ROOT": "", "PDF_PRIVATE_VALIDATION_ROOT": ""},
            clear=False,
        ):
            with self.assertRaisesRegex(SystemExit, "explicit --root"):
                corpus.resolve_root(manifest, None)


if __name__ == "__main__":
    unittest.main()

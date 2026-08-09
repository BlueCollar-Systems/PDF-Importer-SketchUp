from __future__ import annotations

import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
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


def _write_manifest(path: Path, entries: list[dict]) -> None:
    path.write_text(
        json.dumps(
            {
                "schema": "bcs.public_pdf_corpus/1.1",
                "updated": "2026-08-09",
                "default_root": "__private_validation_assets_not_configured__",
                "description": "Synthetic test manifest.",
                "entries": entries,
            }
        ),
        encoding="utf-8",
    )


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


class LockPublicationTests(unittest.TestCase):
    def _link_or_skip(self, link: Path, target: Path, *, directory: bool) -> None:
        try:
            link.symlink_to(target, target_is_directory=directory)
        except (NotImplementedError, OSError) as exc:
            self.skipTest(f"filesystem links unavailable: {type(exc).__name__}")

    def _publisher(self):
        publisher = getattr(corpus, "publish_lock_bytes", None)
        self.assertTrue(callable(publisher), "publish_lock_bytes API is required")
        return publisher

    def _make_junction(self, link: Path, target: Path) -> None:
        if os.name != "nt":
            self.skipTest("Windows junction race contract")
        result = subprocess.run(
            ["cmd", "/d", "/c", "mklink", "/J", str(link), str(target)],
            capture_output=True,
            text=True,
            check=False,
        )
        if result.returncode != 0:
            self.skipTest("directory junctions are unavailable")

    def _restore_swapped_parent(self, parent: Path, displaced: Path) -> None:
        try:
            metadata = os.lstat(parent)
        except FileNotFoundError:
            metadata = None
        if metadata is not None and corpus._is_link_or_reparse(metadata):
            os.rmdir(parent)
        if displaced.exists() and not parent.exists():
            os.replace(displaced, parent)

    def test_parent_link_outside_root_fails_before_network_or_lock_write(self) -> None:
        payload = b"%PDF-1.7\nsynthetic\n%%EOF\n"
        with tempfile.TemporaryDirectory() as tmp:
            work = Path(tmp)
            root = work / "corpus"
            outside = work / "outside"
            root.mkdir()
            outside.mkdir()
            sentinel = outside / "sentinel.bin"
            sentinel.write_bytes(b"outside sentinel")
            self._link_or_skip(root / "web-acquired", outside, directory=True)
            manifest = work / "manifest.json"
            _write_manifest(
                manifest,
                [_manifest_entry(expected_sha256=_digest(payload))],
            )

            with mock.patch.object(
                corpus.urllib.request,
                "urlopen",
                return_value=_Response(payload),
            ) as urlopen:
                result = corpus.main(
                    ["--manifest", str(manifest), "--root", str(root)]
                )

            self.assertEqual(1, result)
            urlopen.assert_not_called()
            self.assertEqual(b"outside sentinel", sentinel.read_bytes())
            self.assertFalse((outside / corpus.LOCK_NAME).exists())
            self.assertTrue((root / "web-acquired").is_symlink())

    def test_leaf_link_and_broken_link_fail_closed_without_touching_referent(self) -> None:
        for broken in (False, True):
            with self.subTest(broken=broken), tempfile.TemporaryDirectory() as tmp:
                work = Path(tmp)
                root = work / "corpus"
                lock_parent = root / "web-acquired"
                lock_parent.mkdir(parents=True)
                referent = work / "outside.lock"
                if not broken:
                    referent.write_bytes(b"foreign lock referent")
                lock_path = lock_parent / corpus.LOCK_NAME
                self._link_or_skip(lock_path, referent, directory=False)
                manifest = work / "manifest.json"
                _write_manifest(manifest, [])

                result = corpus.main(
                    ["--manifest", str(manifest), "--root", str(root)]
                )

                self.assertEqual(1, result)
                self.assertTrue(lock_path.is_symlink())
                if broken:
                    self.assertFalse(referent.exists())
                else:
                    self.assertEqual(b"foreign lock referent", referent.read_bytes())

    def test_foreign_regular_lock_blocks_before_network_and_target_creation(self) -> None:
        payload = b"%PDF-1.7\nsynthetic\n%%EOF\n"
        with tempfile.TemporaryDirectory() as tmp:
            work = Path(tmp)
            root = work / "corpus"
            lock_parent = root / "web-acquired"
            lock_parent.mkdir(parents=True)
            lock_path = lock_parent / corpus.LOCK_NAME
            foreign = b"worker-owned lock bytes"
            lock_path.write_bytes(foreign)
            manifest = work / "manifest.json"
            entry = _manifest_entry(expected_sha256=_digest(payload))
            _write_manifest(manifest, [entry])

            with mock.patch.object(
                corpus.urllib.request,
                "urlopen",
                return_value=_Response(payload),
            ) as urlopen:
                result = corpus.main(
                    ["--manifest", str(manifest), "--root", str(root)]
                )

            self.assertEqual(1, result)
            urlopen.assert_not_called()
            self.assertEqual(foreign, lock_path.read_bytes())
            self.assertFalse((root / entry["local_path"]).exists())

    def test_lock_race_winner_is_preserved_and_current_temp_is_removed(self) -> None:
        candidate = b'{"schema":"synthetic"}\n'
        winner = b"foreign race winner"
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "corpus"
            lock_parent = root / "web-acquired"
            lock_parent.mkdir(parents=True)
            lock_path = lock_parent / corpus.LOCK_NAME
            publisher = self._publisher()
            real_publish = corpus.os.link

            def race_publish(source: object, destination: object) -> None:
                Path(destination).write_bytes(winner)
                real_publish(source, destination)

            with mock.patch.object(corpus.os, "link", side_effect=race_publish):
                with self.assertRaisesRegex(Exception, "lock_publish_conflict"):
                    publisher(root, lock_path, candidate)

            self.assertEqual(winner, lock_path.read_bytes())
            self.assertEqual([], list(lock_parent.glob("*.part*")))

    def test_new_lock_is_fsynced_before_atomic_no_replace_publication(self) -> None:
        candidate = b'{"schema":"synthetic","complete":true}\n'
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "corpus"
            lock_parent = root / "web-acquired"
            lock_parent.mkdir(parents=True)
            lock_path = lock_parent / corpus.LOCK_NAME
            publisher = self._publisher()
            events: list[str] = []
            real_fsync = corpus.os.fsync
            real_publish = corpus.os.link

            def observed_fsync(fd: int) -> None:
                events.append("fsync")
                real_fsync(fd)

            def observed_publish(source: object, destination: object) -> None:
                events.append("publish")
                self.assertEqual(candidate, Path(source).read_bytes())
                self.assertFalse(Path(destination).exists())
                real_publish(source, destination)

            with mock.patch.object(corpus.os, "fsync", side_effect=observed_fsync), mock.patch.object(
                corpus.os,
                "link",
                side_effect=observed_publish,
            ):
                publisher(root, lock_path, candidate)

            self.assertEqual(["fsync", "publish"], events)
            self.assertEqual(candidate, lock_path.read_bytes())
            self.assertEqual([], list(lock_parent.glob("*.part*")))

    def test_parent_swap_before_revalidation_never_redirects_cleanup(self) -> None:
        candidate = b'{"schema":"synthetic","race":"revalidate"}\n'
        foreign = b"foreign same-name temp"
        with tempfile.TemporaryDirectory() as tmp:
            work = Path(tmp)
            root = work / "corpus"
            parent = root / "web-acquired"
            outside = work / "outside"
            displaced = work / "owned-parent"
            parent.mkdir(parents=True)
            outside.mkdir()
            lock_path = parent / corpus.LOCK_NAME
            publisher = self._publisher()
            real_check = corpus._contained_lock_parent
            checks = 0
            attempted = False
            swapped = False
            blocked = False
            foreign_temp: Path | None = None

            def attacked_check(root_arg: Path, *, create: bool) -> Path:
                nonlocal checks, attempted, swapped, blocked, foreign_temp
                checks += 1
                if checks != 2:
                    return real_check(root_arg, create=create)
                attempted = True
                temp_names = [item.name for item in parent.glob("*.part")]
                self.assertEqual(1, len(temp_names))
                try:
                    os.replace(parent, displaced)
                except OSError:
                    blocked = True
                    return real_check(root_arg, create=create)
                swapped = True
                self._make_junction(parent, outside)
                foreign_temp = outside / temp_names[0]
                foreign_temp.write_bytes(foreign)
                return real_check(root_arg, create=create)

            outcome = None
            try:
                with mock.patch.object(
                    corpus, "_contained_lock_parent", side_effect=attacked_check
                ):
                    try:
                        publisher(root, lock_path, candidate)
                    except corpus.CorpusDownloadError as exc:
                        outcome = str(exc)

                self.assertTrue(attempted)
                self.assertFalse((outside / corpus.LOCK_NAME).exists())
                if swapped:
                    self.assertIn(outcome, {"lock_path_unsafe", "lock_publish_io_error"})
                    self.assertIsNotNone(foreign_temp)
                    self.assertTrue(foreign_temp.exists())
                    if foreign_temp.exists():
                        self.assertEqual(foreign, foreign_temp.read_bytes())
                    self.assertEqual([], list(displaced.glob("*.part")))
                else:
                    self.assertTrue(blocked)
                    self.assertIsNone(outcome)
                    self.assertEqual(candidate, lock_path.read_bytes())
            finally:
                self._restore_swapped_parent(parent, displaced)

    def test_parent_swap_inside_no_replace_publish_cannot_escape_root(self) -> None:
        candidate = b'{"schema":"synthetic","race":"publish"}\n'
        foreign = b"foreign same-name source"
        with tempfile.TemporaryDirectory() as tmp:
            work = Path(tmp)
            root = work / "corpus"
            parent = root / "web-acquired"
            outside = work / "outside"
            displaced = work / "owned-parent"
            parent.mkdir(parents=True)
            outside.mkdir()
            lock_path = parent / corpus.LOCK_NAME
            publisher = self._publisher()
            real_link = corpus.os.link
            attempted = False
            swapped = False
            blocked = False
            foreign_temp: Path | None = None

            def attacked_link(source: object, destination: object) -> None:
                nonlocal attempted, swapped, blocked, foreign_temp
                attempted = True
                source_name = Path(source).name
                try:
                    os.replace(parent, displaced)
                except OSError:
                    blocked = True
                    real_link(source, destination)
                    return
                swapped = True
                self._make_junction(parent, outside)
                foreign_temp = outside / source_name
                foreign_temp.write_bytes(foreign)
                real_link(source, destination)

            outcome = None
            try:
                with mock.patch.object(corpus.os, "link", side_effect=attacked_link):
                    try:
                        publisher(root, lock_path, candidate)
                    except corpus.CorpusDownloadError as exc:
                        outcome = str(exc)

                self.assertTrue(attempted)
                self.assertFalse((outside / corpus.LOCK_NAME).exists())
                if swapped:
                    self.assertIn(
                        outcome,
                        {"lock_path_unsafe", "lock_publish_io_error", "lock_cleanup_io_error"},
                    )
                    self.assertIsNotNone(foreign_temp)
                    self.assertEqual(foreign, foreign_temp.read_bytes())
                    self.assertEqual([], list(displaced.glob("*.part")))
                else:
                    self.assertTrue(blocked)
                    self.assertIsNone(outcome)
                    self.assertEqual(candidate, lock_path.read_bytes())
            finally:
                self._restore_swapped_parent(parent, displaced)

    def test_lock_io_failures_use_closed_path_free_tokens(self) -> None:
        candidate = b'{"schema":"synthetic"}\n'
        private = r"C:\\private\\account\\lock.json"

        with self.subTest(seam="lstat"), tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "corpus"
            root.mkdir()
            with mock.patch.object(
                corpus.os, "lstat", side_effect=PermissionError(private)
            ):
                with self.assertRaises(Exception) as raised:
                    corpus.prepare_lock_destination(root)
            self.assertIsInstance(raised.exception, corpus.CorpusDownloadError)
            self.assertEqual("lock_path_io_error", str(raised.exception))
            self.assertNotIn("private", str(raised.exception).lower())

        for seam in ("temp_create", "fsync", "link"):
            with self.subTest(seam=seam), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp) / "corpus"
                parent = root / "web-acquired"
                parent.mkdir(parents=True)
                lock_path = parent / corpus.LOCK_NAME
                if seam == "temp_create":
                    patcher = mock.patch.object(
                        corpus,
                        "_create_lock_temp_capability",
                        side_effect=PermissionError(private),
                        create=True,
                    )
                elif seam == "fsync":
                    patcher = mock.patch.object(
                        corpus.os, "fsync", side_effect=OSError(private)
                    )
                else:
                    patcher = mock.patch.object(
                        corpus.os, "link", side_effect=OSError(private)
                    )
                with patcher:
                    with self.assertRaises(Exception) as raised:
                        self._publisher()(root, lock_path, candidate)
                self.assertIsInstance(raised.exception, corpus.CorpusDownloadError)
                self.assertEqual("lock_publish_io_error", str(raised.exception))
                self.assertNotIn("private", str(raised.exception).lower())

    def test_cleanup_failure_is_reported_without_deleting_foreign_bytes(self) -> None:
        candidate = b'{"schema":"synthetic","cleanup":true}\n'
        private = r"C:\\private\\account\\cleanup.part"
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "corpus"
            parent = root / "web-acquired"
            parent.mkdir(parents=True)
            lock_path = parent / corpus.LOCK_NAME
            with mock.patch.object(
                corpus,
                "_dispose_lock_temp_capability",
                side_effect=PermissionError(private),
                create=True,
            ):
                with self.assertRaises(corpus.CorpusDownloadError) as raised:
                    self._publisher()(root, lock_path, candidate)

            self.assertEqual("lock_cleanup_io_error", str(raised.exception))
            self.assertNotIn("private", str(raised.exception).lower())
            self.assertEqual(candidate, lock_path.read_bytes())


if __name__ == "__main__":
    unittest.main()

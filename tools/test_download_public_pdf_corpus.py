from __future__ import annotations

import hashlib
import io
import inspect
import json
import os
from pathlib import Path
import subprocess
import stat
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
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
            real_publish = getattr(corpus, "_publish_entry_temp_no_replace", None)
            self.assertTrue(
                callable(real_publish),
                "verified entries require capability-bound publication",
            )

            def race_publish(temp: object, parent: object, destination: object) -> None:
                Path(destination).write_bytes(winner)
                real_publish(temp, parent, destination)

            with mock.patch.object(
                corpus, "_publish_entry_temp_no_replace", side_effect=race_publish
            ):
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

    def _assert_windows_entry_swap_is_contained(self, seam: str) -> None:
        payload = b"%PDF-1.7\nverified entry capability\n%%EOF\n"
        expected = _digest(payload)
        with tempfile.TemporaryDirectory() as tmp:
            work = Path(tmp)
            parent = work / "owned"
            outside = work / "outside"
            displaced = work / "displaced-owned"
            parent.mkdir()
            outside.mkdir()
            target = parent / "case.pdf"
            outside_target = outside / target.name
            sentinel = outside / "sentinel.bin"
            sentinel.write_bytes(b"foreign sentinel")
            attempted = False
            swapped = False
            blocked = False
            foreign_temp: Path | None = None

            seam_name = {
                "pre_temp": "_create_entry_temp_capability",
                "publish": "_publish_entry_temp_no_replace",
                "winner_read": "_read_entry_destination_digest",
                "cleanup": "_dispose_entry_temp_capability",
            }[seam]
            real_seam = getattr(corpus, seam_name, None)

            def attacked(*args, **kwargs):
                nonlocal attempted, swapped, blocked, foreign_temp
                if seam == "winner_read" and kwargs.get("expected_identity") is None:
                    return real_seam(*args, **kwargs)
                attempted = True
                temp = args[0] if seam in {"publish", "cleanup"} else None
                try:
                    os.replace(parent, displaced)
                except OSError:
                    blocked = True
                else:
                    swapped = True
                    self._make_junction(parent, outside)
                    if temp is not None:
                        foreign_temp = outside / Path(temp.path).name
                        foreign_temp.write_bytes(b"foreign same-name temp")
                return real_seam(*args, **kwargs)

            outcome: Exception | None = None
            try:
                with mock.patch.object(
                    corpus,
                    seam_name,
                    side_effect=attacked if callable(real_seam) else AssertionError(
                        f"missing verified-entry seam {seam_name}"
                    ),
                    create=True,
                ), mock.patch.object(
                    corpus.urllib.request,
                    "urlopen",
                    return_value=_Response(payload),
                ):
                    try:
                        self._downloader()(
                            "https://example.invalid/case.pdf", target, 1, expected
                        )
                    except Exception as exc:  # the containment result may fail closed
                        outcome = exc

                self.assertTrue(attempted, f"verified entry did not use {seam_name}")
                self.assertFalse(outside_target.exists())
                self.assertEqual(b"foreign sentinel", sentinel.read_bytes())
                if foreign_temp is not None:
                    self.assertTrue(foreign_temp.exists())
                    self.assertEqual(b"foreign same-name temp", foreign_temp.read_bytes())
                owned_parent = displaced if swapped else parent
                self.assertEqual([], list(owned_parent.glob("*.part*")))
                if blocked:
                    self.assertIsNone(outcome)
                    self.assertEqual(payload, target.read_bytes())
                elif swapped:
                    self.assertIsInstance(outcome, corpus.CorpusDownloadError)
            finally:
                self._restore_swapped_parent(parent, displaced)

    @unittest.skipUnless(os.name == "nt", "Windows junction race contract")
    def test_windows_entry_parent_swap_before_temp_creation_cannot_escape(self) -> None:
        self._assert_windows_entry_swap_is_contained("pre_temp")

    @unittest.skipUnless(os.name == "nt", "Windows junction race contract")
    def test_windows_entry_parent_swap_during_publish_cannot_escape(self) -> None:
        self._assert_windows_entry_swap_is_contained("publish")

    @unittest.skipUnless(os.name == "nt", "Windows junction race contract")
    def test_windows_entry_parent_swap_during_winner_read_cannot_escape(self) -> None:
        self._assert_windows_entry_swap_is_contained("winner_read")

    @unittest.skipUnless(os.name == "nt", "Windows junction race contract")
    def test_windows_entry_parent_swap_during_cleanup_cannot_escape(self) -> None:
        self._assert_windows_entry_swap_is_contained("cleanup")

    def _run_cli_failure_seam(self, seam: str) -> tuple[str, dict, Path]:
        private_path = r"C:\private\customer\secret.part"
        private_url = "https://private-user:private-password@example.invalid/case.pdf"
        payload = b"%PDF-1.7\npath-free failure evidence\n%%EOF\n"
        expected = _digest(payload)
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        work = Path(tmp.name)
        root = work / "corpus"
        manifest = work / "manifest.json"
        _write_manifest(
            manifest,
            [
                _manifest_entry(
                    url=private_url,
                    expected_sha256=expected,
                )
            ],
        )
        stderr = io.StringIO()
        stdout = io.StringIO()
        expected_token = {
            "preflight": "entry_path_io_error",
            "temp": "download_temp_io_error",
            "network": "download_network_error",
            "write": "download_write_io_error",
            "fsync": "download_fsync_io_error",
            "publish": "publish_io_error",
            "readback": "publish_readback_io_error",
            "cleanup": "download_cleanup_io_error",
        }[seam]

        if seam == "network":
            patches = [
                mock.patch.object(
                    corpus.urllib.request,
                    "urlopen",
                    side_effect=corpus.urllib.error.URLError(
                        f"{private_path} {private_url}"
                    ),
                )
            ]
        else:
            seam_name = {
                "preflight": "_open_entry_parent_capability",
                "temp": "_create_entry_temp_capability",
                "write": "_write_entry_temp_from_url",
                "fsync": "_fsync_entry_temp_capability",
                "publish": "_publish_entry_temp_no_replace",
                "readback": "_read_entry_destination_digest",
                "cleanup": "_dispose_entry_temp_capability",
            }[seam]
            patches = [
                mock.patch.object(
                    corpus,
                    seam_name,
                    side_effect=OSError(f"{private_path} {private_url}"),
                    create=True,
                ),
                mock.patch.object(
                    corpus.urllib.request,
                    "urlopen",
                    return_value=_Response(payload),
                ),
            ]

        entered = []
        try:
            for patcher in patches:
                entered.append(patcher.start())
            with redirect_stderr(stderr), redirect_stdout(stdout):
                result = corpus.main(
                    ["--manifest", str(manifest), "--root", str(root)]
                )
        finally:
            for patcher in reversed(patches):
                patcher.stop()

        self.assertEqual(1, result, seam)
        lock_path = root / "web-acquired" / corpus.LOCK_NAME
        self.assertTrue(lock_path.is_file(), seam)
        lock = json.loads(lock_path.read_text(encoding="utf-8"))
        entry = lock["entries"][0]
        self.assertEqual(expected_token, entry["reason"], seam)
        evidence = stderr.getvalue() + json.dumps(lock, sort_keys=True)
        self.assertNotIn("private-user", evidence)
        self.assertNotIn("private-password", evidence)
        self.assertNotIn("secret.part", evidence)
        self.assertNotIn("C:\\private", evidence)
        self.assertEqual([], list((root / "web-acquired").glob("*.part*")))
        return stderr.getvalue(), lock, root

    def test_download_failures_are_path_free_in_stderr_and_lock_evidence(self) -> None:
        for seam in (
            "preflight",
            "temp",
            "network",
            "write",
            "fsync",
            "publish",
            "readback",
            "cleanup",
        ):
            with self.subTest(seam=seam):
                self._run_cli_failure_seam(seam)


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
    def test_posix_parent_capability_ignores_mutable_directory_metadata(self) -> None:
        path = Path("/synthetic/corpus/web-acquired")
        opened = type(
            "SyntheticStat",
            (),
            {"st_mode": 0o40700, "st_ino": 91, "st_dev": 7, "st_nlink": 2, "st_size": 4096},
        )()
        after_temp_create = type(
            "SyntheticStat",
            (),
            {"st_mode": 0o40700, "st_ino": 91, "st_dev": 7, "st_nlink": 3, "st_size": 8192},
        )()
        capability = corpus._LockParentCapability(
            path=path,
            handle=123,
            identity=corpus._stat_identity(opened),
            windows=False,
        )

        with mock.patch.object(corpus.os, "lstat", return_value=after_temp_create), mock.patch.object(
            corpus.os, "fstat", return_value=after_temp_create
        ):
            corpus._validate_lock_parent_capability(capability)

    def _link_or_skip(self, link: Path, target: Path, *, directory: bool) -> None:
        try:
            link.symlink_to(target, target_is_directory=directory)
        except (NotImplementedError, OSError) as exc:
            self.skipTest(f"filesystem links unavailable: {type(exc).__name__}")

    def _publisher(self):
        publisher = getattr(corpus, "publish_lock_bytes", None)
        self.assertTrue(callable(publisher), "publish_lock_bytes API is required")
        return publisher

    def _no_replace_publisher(self):
        publisher = getattr(corpus, "_publish_lock_temp_no_replace", None)
        self.assertTrue(
            callable(publisher), "handle-bound no-replace publisher API is required"
        )
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
            real_publish = self._no_replace_publisher()

            def race_publish(temp_cap: object, parent_cap: object, destination: object) -> None:
                Path(destination).write_bytes(winner)
                real_publish(temp_cap, parent_cap, destination)

            with mock.patch.object(
                corpus, "_publish_lock_temp_no_replace", side_effect=race_publish
            ):
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
            real_publish = self._no_replace_publisher()

            def observed_fsync(fd: int) -> None:
                events.append("fsync")
                real_fsync(fd)

            def observed_publish(
                temp_cap: object, parent_cap: object, destination: object
            ) -> None:
                events.append("publish")
                self.assertEqual(candidate, corpus._read_lock_temp_capability(temp_cap))
                self.assertFalse(Path(destination).exists())
                real_publish(temp_cap, parent_cap, destination)

            with mock.patch.object(corpus.os, "fsync", side_effect=observed_fsync), mock.patch.object(
                corpus,
                "_publish_lock_temp_no_replace",
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
            real_publish = self._no_replace_publisher()
            attempted = False
            swapped = False
            blocked = False
            foreign_temp: Path | None = None

            def attacked_link(
                temp_cap: object, parent_cap: object, destination: object
            ) -> None:
                nonlocal attempted, swapped, blocked, foreign_temp
                attempted = True
                source_name = Path(temp_cap.path).name
                try:
                    os.replace(parent, displaced)
                except OSError:
                    blocked = True
                    real_publish(temp_cap, parent_cap, destination)
                    return
                swapped = True
                self._make_junction(parent, outside)
                foreign_temp = outside / source_name
                foreign_temp.write_bytes(foreign)
                real_publish(temp_cap, parent_cap, destination)

            outcome = None
            try:
                with mock.patch.object(
                    corpus, "_publish_lock_temp_no_replace", side_effect=attacked_link
                ):
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
                        corpus,
                        "_publish_lock_temp_no_replace",
                        side_effect=OSError(private),
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

    def _windows_process_handle_count(self) -> int | None:
        if os.name != "nt":
            return None
        import ctypes
        from ctypes import wintypes

        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel32.GetCurrentProcess.restype = wintypes.HANDLE
        kernel32.GetProcessHandleCount.argtypes = [
            wintypes.HANDLE,
            ctypes.POINTER(wintypes.DWORD),
        ]
        kernel32.GetProcessHandleCount.restype = wintypes.BOOL
        count = wintypes.DWORD()
        if not kernel32.GetProcessHandleCount(
            kernel32.GetCurrentProcess(), ctypes.byref(count)
        ):
            raise ctypes.WinError(ctypes.get_last_error())
        return int(count.value)

    def _run_lock_writer_probe(self, payloads: tuple[bytes, ...]) -> dict:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "corpus"
            script = r'''
import ctypes
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import shutil
import sys
import threading
from unittest import mock
from tools import download_public_pdf_corpus as corpus

def handles():
    if os.name != "nt":
        return None
    from ctypes import wintypes
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel32.GetCurrentProcess.restype = wintypes.HANDLE
    kernel32.GetProcessHandleCount.argtypes = [wintypes.HANDLE, ctypes.POINTER(wintypes.DWORD)]
    kernel32.GetProcessHandleCount.restype = wintypes.BOOL
    value = wintypes.DWORD()
    if not kernel32.GetProcessHandleCount(kernel32.GetCurrentProcess(), ctypes.byref(value)):
        raise ctypes.WinError(ctypes.get_last_error())
    return int(value.value)

root = Path(sys.argv[1])
payloads = [bytes.fromhex(value) for value in sys.argv[2:]]
parent = root / "web-acquired"
parent.mkdir(parents=True)
destination = parent / corpus.LOCK_NAME
barrier = threading.Barrier(len(payloads))
real_publish = corpus._publish_lock_temp_no_replace
outcomes = []

def synchronized_publish(*args, **kwargs):
    barrier.wait(timeout=5)
    return real_publish(*args, **kwargs)

def writer(payload):
    try:
        corpus.publish_lock_bytes(root, destination, payload)
    except BaseException as exc:
        outcomes.append(str(exc))
    else:
        outcomes.append("ok")

with ThreadPoolExecutor(max_workers=len(payloads)) as executor:
    warmed = [executor.submit(lambda: barrier.wait(timeout=5)) for _ in payloads]
    for future in warmed:
        future.result(timeout=10)
    del future
    warmed.clear()
    warm_root = root.parent / "warm-corpus"
    warm_parent = warm_root / "web-acquired"
    warm_parent.mkdir(parents=True)
    corpus.publish_lock_bytes(
        warm_root,
        warm_parent / corpus.LOCK_NAME,
        b'{"warm":true}\n',
    )
    shutil.rmtree(warm_root)
    baseline = handles()
    with mock.patch.object(
        corpus,
        "_publish_lock_temp_no_replace",
        side_effect=synchronized_publish,
    ) as observed_publish:
        futures = [executor.submit(writer, payload) for payload in payloads]
        for future in futures:
            future.result(timeout=15)
        del future
        futures.clear()
    observed_publish.reset_mock(return_value=True, side_effect=True)
    del observed_publish
    drained = [executor.submit(lambda: barrier.wait(timeout=5)) for _ in payloads]
    for future in drained:
        future.result(timeout=10)
    del future
    drained.clear()
    after = handles()
print(json.dumps({
    "outcomes": outcomes,
    "winner": destination.read_bytes().hex() if destination.is_file() else None,
    "temps": sorted(item.name for item in parent.glob("*.part*")),
    "handle_delta": None if baseline is None else after - baseline,
}))
'''
            completed = subprocess.run(
                [sys.executable, "-B", "-c", script, str(root)]
                + [payload.hex() for payload in payloads],
                cwd=Path(__file__).resolve().parents[1],
                capture_output=True,
                text=True,
                check=False,
                timeout=30,
            )
            self.assertEqual(0, completed.returncode, completed.stderr)
            return json.loads(completed.stdout.strip().splitlines()[-1])

    def _run_identical_lock_writers(self, writer_count: int) -> None:
        payload = b'{"schema":"synthetic","concurrent":"identical"}\n'
        result = self._run_lock_writer_probe((payload,) * writer_count)
        self.assertEqual(["ok"] * writer_count, sorted(result["outcomes"]))
        self.assertEqual(payload.hex(), result["winner"])
        self.assertEqual([], result["temps"])
        if result["handle_delta"] is not None:
            self.assertEqual(0, result["handle_delta"], "native handles leaked without GC")

    def test_two_four_and_eight_identical_lock_writers_all_succeed_immediately(self) -> None:
        for writer_count in (2, 4, 8):
            with self.subTest(writer_count=writer_count):
                self._run_identical_lock_writers(writer_count)

    def test_differing_lock_winner_is_preserved_and_loser_conflicts(self) -> None:
        payloads = (
            b'{"schema":"synthetic","candidate":"alpha"}\n',
            b'{"schema":"synthetic","candidate":"beta"}\n',
        )
        result = self._run_lock_writer_probe(payloads)
        self.assertCountEqual(["ok", "lock_publish_conflict"], result["outcomes"])
        self.assertIn(bytes.fromhex(result["winner"]), payloads)
        self.assertEqual([], result["temps"])
        if result["handle_delta"] is not None:
            self.assertEqual(0, result["handle_delta"], "native handles leaked without GC")

    @unittest.skipUnless(os.name == "nt", "native Windows handle cleanup contract")
    def test_windows_temp_capability_exceptions_close_every_exact_handle(self) -> None:
        injection_points = ("identity", "file_object", "fstat", "revalidate")
        for injection in injection_points:
            with self.subTest(injection=injection), tempfile.TemporaryDirectory() as tmp:
                parent_path = Path(tmp) / "web-acquired"
                parent_path.mkdir()
                script = r'''
import ctypes
import json
import os
from pathlib import Path
import sys
from unittest import mock
from tools import download_public_pdf_corpus as corpus
from ctypes import wintypes

def handles():
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel32.GetCurrentProcess.restype = wintypes.HANDLE
    kernel32.GetProcessHandleCount.argtypes = [wintypes.HANDLE, ctypes.POINTER(wintypes.DWORD)]
    kernel32.GetProcessHandleCount.restype = wintypes.BOOL
    value = wintypes.DWORD()
    if not kernel32.GetProcessHandleCount(kernel32.GetCurrentProcess(), ctypes.byref(value)):
        raise ctypes.WinError(ctypes.get_last_error())
    return int(value.value)

parent_path = Path(sys.argv[1])
injection = sys.argv[2]
parent = corpus._open_lock_parent_capability(parent_path)
baseline = handles()
real_identity = corpus._windows_handle_identity
real_file_object = corpus._windows_temp_file_object
real_fstat = corpus.os.fstat
real_validate = corpus._validate_lock_parent_capability
identity_calls = 0
validate_calls = 0

def injected_identity(handle):
    global identity_calls
    if handle != parent.handle:
        identity_calls += 1
        if injection == "identity" and identity_calls == 1:
            raise OSError("private identity failure")
    return real_identity(handle)

def injected_file_object(handle):
    if injection == "file_object":
        raise OSError("private duplicate failure")
    return real_file_object(handle)

def injected_fstat(fd):
    if injection == "fstat":
        raise OSError("private fstat failure")
    return real_fstat(fd)

def injected_validate(capability):
    global validate_calls
    validate_calls += 1
    if injection == "revalidate" and validate_calls == 2:
        raise corpus.CorpusDownloadError("lock_path_unsafe")
    return real_validate(capability)

outcome = None
with mock.patch.object(corpus, "_windows_handle_identity", side_effect=injected_identity), \
     mock.patch.object(corpus, "_windows_temp_file_object", side_effect=injected_file_object), \
     mock.patch.object(corpus.os, "fstat", side_effect=injected_fstat), \
     mock.patch.object(corpus, "_validate_lock_parent_capability", side_effect=injected_validate):
    try:
        corpus._create_lock_temp_capability(parent)
    except BaseException as exc:
        outcome = type(exc).__name__
after = handles()
print(json.dumps({
    "outcome": outcome,
    "temps": sorted(item.name for item in parent_path.glob("*.part*")),
    "handle_delta": after - baseline,
}))
'''
                completed = subprocess.run(
                    [
                        sys.executable,
                        "-B",
                        "-c",
                        script,
                        str(parent_path),
                        injection,
                    ],
                    cwd=Path(__file__).resolve().parents[1],
                    capture_output=True,
                    text=True,
                    check=False,
                    timeout=15,
                )
                self.assertEqual(0, completed.returncode, completed.stderr)
                result = json.loads(completed.stdout.strip().splitlines()[-1])
                self.assertIsNotNone(result["outcome"])
                self.assertEqual([], result["temps"])
                self.assertEqual(0, result["handle_delta"])

    def test_posix_temp_creation_uses_exclusive_nofollow_dirfd(self) -> None:
        parent = corpus._LockParentCapability(
            path=Path("/synthetic/web-acquired"),
            handle=71,
            identity=(7, 91, stat.S_IFDIR, 2, 4096),
            windows=False,
        )
        opened = type(
            "SyntheticStat",
            (),
            {"st_mode": stat.S_IFREG | 0o600, "st_ino": 92, "st_dev": 7, "st_nlink": 1, "st_size": 0},
        )()
        fake_file = mock.Mock()
        fake_file.fileno.return_value = 72

        with mock.patch.object(
            corpus, "_validate_lock_parent_capability"
        ), mock.patch.object(
            corpus.tempfile,
            "NamedTemporaryFile",
            side_effect=AssertionError("pathname temp creation is forbidden"),
        ), mock.patch.object(
            corpus.os, "open", return_value=72
        ) as opened_file, mock.patch.object(
            corpus.os, "fdopen", return_value=fake_file
        ), mock.patch.object(
            corpus.os, "fstat", return_value=opened
        ):
            temp = corpus._create_lock_temp_capability(parent)

        args, kwargs = opened_file.call_args
        self.assertNotIn("/", args[0])
        self.assertEqual(71, kwargs["dir_fd"])
        self.assertTrue(args[1] & os.O_CREAT)
        self.assertTrue(args[1] & os.O_EXCL)
        nofollow = getattr(os, "O_NOFOLLOW", 0)
        if nofollow:
            self.assertTrue(args[1] & nofollow)
        self.assertIs(fake_file, temp.handle)

    def test_posix_owned_link_requires_two_then_one_exact_links(self) -> None:
        payload = b'{"schema":"synthetic","posix":true}\n'
        parent = corpus._LockParentCapability(
            path=Path("/synthetic/web-acquired"),
            handle=81,
            identity=(7, 91, stat.S_IFDIR, 2, 4096),
            windows=False,
        )
        destination = parent.path / corpus.LOCK_NAME
        expected_identity = (7, 92, stat.S_IFREG, 1, len(payload))
        path_stat = type(
            "SyntheticStat",
            (),
            {"st_mode": stat.S_IFREG | 0o600, "st_ino": 92, "st_dev": 7, "st_nlink": 2, "st_size": len(payload)},
        )()
        one_link_stat = type(
            "SyntheticStat",
            (),
            {"st_mode": stat.S_IFREG | 0o600, "st_ino": 92, "st_dev": 7, "st_nlink": 1, "st_size": len(payload)},
        )()

        def read_with(metadata, links: int) -> bytes:
            if "expected_links" not in inspect.signature(
                corpus._read_existing_lock_bytes
            ).parameters:
                self.fail("owned-link verification requires an explicit link-count law")
            with mock.patch.object(
                corpus, "_validate_lock_parent_capability"
            ), mock.patch.object(
                corpus, "_lstat_or_none", return_value=metadata
            ), mock.patch.object(
                corpus.os, "open", return_value=82
            ) as opened, mock.patch.object(
                corpus.os, "fstat", return_value=metadata
            ), mock.patch.object(
                corpus.os, "dup", return_value=83
            ), mock.patch.object(
                corpus.os, "fdopen", return_value=io.BytesIO(payload)
            ), mock.patch.object(corpus.os, "close"):
                result = corpus._read_existing_lock_bytes(
                    parent,
                    destination,
                    expected_identity=expected_identity,
                    expected_links=links,
                )
            self.assertEqual(81, opened.call_args.kwargs["dir_fd"])
            return result

        self.assertEqual(payload, read_with(path_stat, 2))
        self.assertEqual(payload, read_with(one_link_stat, 1))

    def test_posix_cleanup_unlinks_only_exact_inode_relative_to_dirfd(self) -> None:
        parent = corpus._LockParentCapability(
            path=Path("/synthetic/web-acquired"),
            handle=91,
            identity=(7, 101, stat.S_IFDIR, 2, 4096),
            windows=False,
        )
        opened = type(
            "SyntheticStat",
            (),
            {"st_mode": stat.S_IFREG | 0o600, "st_ino": 102, "st_dev": 7, "st_nlink": 2, "st_size": 10},
        )()
        fake_file = mock.Mock()
        temp = corpus._LockTempCapability(
            path=parent.path / ".owned.part",
            handle=fake_file,
            identity=(7, 102, stat.S_IFREG, 2, 10),
            parent=parent,
        )
        with mock.patch.object(
            corpus.os, "stat", return_value=opened
        ) as stat_call, mock.patch.object(corpus.os, "unlink") as unlink_call:
            try:
                corpus._dispose_lock_temp_capability(temp)
            except corpus.CorpusDownloadError as exc:
                self.fail(f"POSIX cleanup was not descriptor-relative: {exc}")

        fake_file.close.assert_called_once_with()
        stat_call.assert_called_once_with(
            ".owned.part", dir_fd=91, follow_symlinks=False
        )
        unlink_call.assert_called_once_with(".owned.part", dir_fd=91)
        self.assertTrue(temp.closed)

    @unittest.skipIf(os.name == "nt", "native POSIX descriptor test")
    def test_native_posix_parent_rename_preserves_foreign_same_name_and_leaks_nothing(self) -> None:
        payload = b'{"schema":"synthetic","native_posix":true}\n'
        with tempfile.TemporaryDirectory() as tmp:
            work = Path(tmp)
            parent_path = work / "web-acquired"
            displaced = work / "owned-parent"
            replacement = work / "replacement"
            parent_path.mkdir()
            replacement.mkdir()
            parent = corpus._open_lock_parent_capability(parent_path)
            temp = corpus._create_lock_temp_capability(parent)
            corpus._write_lock_temp_capability(temp, payload)
            os.replace(parent_path, displaced)
            os.replace(replacement, parent_path)
            foreign = parent_path / temp.path.name
            foreign.write_bytes(b"foreign same-name bytes")
            try:
                corpus._publish_lock_temp_no_replace(
                    temp, parent, parent.path / corpus.LOCK_NAME
                )
                corpus._dispose_lock_temp_capability(temp)
                self.assertEqual(payload, (displaced / corpus.LOCK_NAME).read_bytes())
                self.assertEqual(b"foreign same-name bytes", foreign.read_bytes())
                self.assertEqual([], list(displaced.glob("*.part*")))
            finally:
                corpus._force_close_lock_temp_capability(temp)
                corpus._close_lock_parent_capability(parent)


if __name__ == "__main__":
    unittest.main()

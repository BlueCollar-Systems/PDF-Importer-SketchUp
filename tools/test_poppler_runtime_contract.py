#!/usr/bin/env python3
"""Behavior locks for the extension-local Poppler runtime contract."""

from __future__ import annotations

import json
import hashlib
import shutil
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest import mock

TOOLS = Path(__file__).resolve().parent
sys.path.insert(0, str(TOOLS))

import poppler_runtime_contract as prc  # noqa: E402


class RuntimeContractTest(unittest.TestCase):
    def make_runtime(self, parent: Path, marker: bytes = b"x") -> Path:
        support = parent / "bc_pdf_vector_importer"
        for name in prc.PINNED_BINARY_ALLOWLIST:
            path = support / prc.BIN_REL / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(marker + name.encode("ascii"))
        for rel in prc.PINNED_NOTICE_LICENSE_ALLOWLIST:
            path = support / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(marker + rel.as_posix().encode("ascii"))
        data = {
            "CMakeLists.txt": b"cmake",
            "COPYING": b"license index",
            "COPYING.adobe": b"adobe license",
            "COPYING.gpl2": b"gpl2 license",
            "Makefile": b"make",
            "README": b"poppler-data 0.4.12",
            "cMap/Adobe-CNS1/map": b"cns",
            "cMap/Adobe-GB1/map": b"gb",
            "cMap/Adobe-Japan1/map": b"jp",
            "cMap/Adobe-Korea1/map": b"kr",
            "cidToUnicode/Adobe-CNS1": b"cns cid",
            "cidToUnicode/Adobe-GB1": b"gb cid",
            "cidToUnicode/Adobe-Japan1": b"jp cid",
            "cidToUnicode/Adobe-Korea1": b"kr cid",
            "nameToUnicode/Bulgarian": b"names",
            "unicodeMap/ISO-8859-6": b"unicode",
        }
        for rel, payload in data.items():
            path = support / prc.DATA_REL / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(payload)
        return support

    @staticmethod
    def totals(support: Path) -> tuple[int, int]:
        files = [p for p in (support / prc.DATA_REL).rglob("*") if p.is_file()]
        return len(files), sum(p.stat().st_size for p in files)

    def fixture_pins(self, support: Path):
        count, size = self.totals(support)
        inventory_digest = prc._member_inventory_digest(
            prc._build_member_entries(support)
        )
        return (
            mock.patch.object(prc, "PINNED_DATA_FILE_COUNT", count),
            mock.patch.object(prc, "PINNED_DATA_TOTAL_BYTES", size),
            mock.patch.object(
                prc, "PINNED_MEMBER_INVENTORY_SHA256", inventory_digest
            ),
        )

    def write(self, support: Path, status: str = "blocked") -> dict:
        first, second, third = self.fixture_pins(support)
        with first, second, third:
            return prc.write_manifest(
                support,
                license_review={
                    "status": status,
                    "reason": "qualified binary-license review pending"
                    if status == "blocked"
                    else "qualified review approved",
                    "missing": ["binary dependency license closure"]
                    if status == "blocked"
                    else [],
                    **(
                        {
                            "reviewer": "Qualified Reviewer",
                            "reviewed_at": "2026-07-16T00:00:00Z",
                            "evidence": "legal-review-record-1",
                        }
                        if status == "approved"
                        else {}
                    ),
                },
            )

    def verify(self, support: Path, **kwargs) -> dict:
        first, second, third = self.fixture_pins(support)
        with first, second, third:
            return prc.verify_runtime(support, **kwargs)

    def test_only_satisfiable_layout_is_library_bin_plus_share_poppler(self):
        self.assertEqual(Path("Library/bin"), prc.BIN_REL)
        self.assertEqual(Path("share/poppler"), prc.DATA_REL)
        self.assertEqual(Path("poppler-runtime-manifest.json"), prc.MANIFEST_REL)
        self.assertNotIn(Path("bin"), prc.RUNTIME_PAYLOAD_ROOTS)

    def test_source_contract_pins_poppler_data_and_separate_official_gpl3_text(self):
        source = prc._source_contract()
        self.assertEqual(
            "c835b640a40ce357e1b83666aabd95edffa24ddddd49b8daff63adb851cdab74",
            source["poppler_data_archive_sha256"],
        )
        self.assertEqual(
            "3972dc9744f6499f0f9b2dbf76696f2ae7ad8af9b23dde66d6af86c9dfb36986",
            source["gpl3_text_sha256"],
        )
        self.assertIn("poppler-data-0.4.12.tar.gz", source["poppler_data_url"])
        self.assertEqual("https://www.gnu.org/licenses/gpl-3.0.txt", source["gpl3_text_url"])

    def test_ruby_runtime_resolver_uses_the_same_canonical_inventory_digest(self):
        resolver = (
            TOOLS.parent
            / "extracted/sketchup_ext/bc_pdf_vector_importer/dependency_resolver.rb"
        ).read_text(encoding="utf-8")
        self.assertIn(prc.PINNED_MEMBER_INVENTORY_SHA256, resolver)

    def test_notice_templates_match_pins_and_checked_in_runtime(self):
        root = TOOLS.parent
        template_dir = TOOLS / "poppler_runtime_templates"
        notice = (template_dir / "THIRD_PARTY_NOTICES.txt").read_text(encoding="utf-8")
        for value in (
            prc.PINNED_RELEASE_TAG,
            prc.PINNED_ASSET,
            prc.PINNED_ASSET_SHA256,
            prc.PINNED_DATA_ARCHIVE_SHA256,
            prc.GPL3_TEXT_SHA256,
        ):
            self.assertIn(value, notice)

        support = root / "extracted/sketchup_ext/bc_pdf_vector_importer"
        self.assertEqual(
            (template_dir / "THIRD_PARTY_NOTICES.txt").read_bytes(),
            (support / "Library/THIRD_PARTY_NOTICES.txt").read_bytes(),
        )
        self.assertEqual(
            (template_dir / "LICENSE_README.txt").read_bytes(),
            (support / "Library/licenses/README.txt").read_bytes(),
        )

    def test_exact_manifest_rejects_extra_missing_or_changed_members(self):
        with tempfile.TemporaryDirectory() as tmp:
            support = self.make_runtime(Path(tmp))
            expected = self.write(support)
            self.assertEqual(expected, self.verify(support))

            extra = support / prc.BIN_REL / "extra.dll"
            extra.write_bytes(b"extra")
            with self.assertRaisesRegex(prc.ContractError, "extra|inventory"):
                self.verify(support)
            extra.unlink()

            changed = support / prc.DATA_REL / "cMap/Adobe-GB1/map"
            changed.write_bytes(b"changed")
            with self.assertRaisesRegex(prc.ContractError, "incomplete|inventory|hash|size"):
                self.verify(support)

    def test_regenerated_manifest_cannot_self_bless_changed_pinned_member(self):
        root = TOOLS.parent
        source = root / "extracted/sketchup_ext/bc_pdf_vector_importer"
        with tempfile.TemporaryDirectory() as tmp:
            support = Path(tmp) / source.name
            shutil.copytree(source, support)
            helper = support / prc.BIN_REL / "pdftotext.exe"
            payload = bytearray(helper.read_bytes())
            payload[0] ^= 0x01
            helper.write_bytes(payload)

            with self.assertRaisesRegex(prc.ContractError, "pinned member inventory"):
                prc.write_manifest(
                    support,
                    license_review={
                        "status": "blocked",
                        "reason": "qualified binary-license review pending",
                        "missing": ["binary dependency license closure"],
                    },
                )

    def test_manifest_cannot_bless_a_legacy_direct_bin_member(self):
        with tempfile.TemporaryDirectory() as tmp:
            support = self.make_runtime(Path(tmp))
            manifest = self.write(support)
            legacy = support / "bin/legacy.dll"
            legacy.parent.mkdir(parents=True)
            legacy.write_bytes(b"legacy")
            manifest["members"].append(
                {
                    "path": "bin/legacy.dll",
                    "category": "data",
                    "bytes": legacy.stat().st_size,
                    "sha256": hashlib.sha256(legacy.read_bytes()).hexdigest(),
                }
            )
            (support / prc.MANIFEST_REL).write_text(
                json.dumps(manifest), encoding="utf-8"
            )
            with self.assertRaisesRegex(prc.ContractError, "legacy|outside"):
                self.verify(support)

    def test_scope_is_honestly_limited_to_the_adobe_gb1_fixture(self):
        with tempfile.TemporaryDirectory() as tmp:
            manifest = self.write(self.make_runtime(Path(tmp)))
        scope = manifest["semantic_validation"]["scope"]
        self.assertEqual(prc.GB1_FIXTURE_SCOPE, scope)
        self.assertIn("Adobe-GB1", scope)
        self.assertNotIn("CID-complete", json.dumps(manifest))

    def test_blocked_license_review_allows_structure_but_blocks_release(self):
        with tempfile.TemporaryDirectory() as tmp:
            support = self.make_runtime(Path(tmp))
            self.write(support, "blocked")
            self.verify(support, require_license_approved=False)
            with self.assertRaisesRegex(prc.ContractError, "license review.*blocked"):
                self.verify(support, require_license_approved=True)

    def test_approved_review_requires_reviewer_timestamp_and_evidence(self):
        with tempfile.TemporaryDirectory() as tmp:
            support = self.make_runtime(Path(tmp))
            manifest = self.write(support, "blocked")
            manifest["license_review"] = {"status": "approved", "missing": []}
            (support / prc.MANIFEST_REL).write_text(
                json.dumps(manifest), encoding="utf-8"
            )
            with self.assertRaisesRegex(prc.ContractError, "approval metadata"):
                self.verify(support, require_license_approved=True)

            manifest["license_review"].update(
                reviewer="Qualified Reviewer",
                reviewed_at="2026-07-16T00:00:00Z",
                evidence="legal-review-record-1",
            )
            (support / prc.MANIFEST_REL).write_text(
                json.dumps(manifest), encoding="utf-8"
            )
            self.verify(support, require_license_approved=True)

    def test_source_only_excludes_current_and_legacy_runtime_payloads(self):
        for rel in (
            "Library/bin/pdftotext.exe",
            "Library/licenses/share_poppler_COPYING.gpl3",
            "Library/THIRD_PARTY_NOTICES.txt",
            "share/poppler/cMap/Adobe-GB1/map",
            "poppler-runtime-manifest.json",
            "bin/legacy.dll",
        ):
            self.assertTrue(prc.is_runtime_payload(Path(rel)), rel)
        self.assertFalse(prc.is_runtime_payload(Path("main.rb")))

    def test_prepare_stage_clears_stale_files_and_rejects_wrong_parent(self):
        with tempfile.TemporaryDirectory() as tmp:
            parent = Path(tmp) / "parent"
            stage = parent / "stage"
            stage.mkdir(parents=True)
            (stage / "stale").write_bytes(b"stale")
            self.assertEqual(stage.resolve(), prc.prepare_stage(stage, parent))
            self.assertEqual([], list(stage.iterdir()))
            with self.assertRaisesRegex(prc.ContractError, "staging parent"):
                prc.prepare_stage(Path(tmp) / "outside", parent)

    def test_transactional_install_restores_legacy_tree_on_failure(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            live = root / "live" / "bc_pdf_vector_importer"
            stage = self.make_runtime(root / "stage", marker=b"new")
            (live / "bin").mkdir(parents=True)
            (live / "bin/old.dll").write_bytes(b"old")
            (live / "main.rb").write_bytes(b"source")
            self.write(stage)

            def fail(event, index, _path):
                if event == "installed" and index == 0:
                    raise RuntimeError("injected")

            count, size = self.totals(stage)
            inventory_digest = prc._member_inventory_digest(
                prc._build_member_entries(stage)
            )
            with (
                mock.patch.object(prc, "PINNED_DATA_FILE_COUNT", count),
                mock.patch.object(prc, "PINNED_DATA_TOTAL_BYTES", size),
                mock.patch.object(
                    prc, "PINNED_MEMBER_INVENTORY_SHA256", inventory_digest
                ),
                self.assertRaisesRegex(RuntimeError, "injected"),
            ):
                prc.transactional_install(stage, live, step_hook=fail)
            self.assertEqual(b"old", (live / "bin/old.dll").read_bytes())
            self.assertEqual(b"source", (live / "main.rb").read_bytes())
            self.assertFalse((live / prc.BIN_REL).exists())
            self.assertFalse((live.parent / (live.name + ".poppler-backup")).exists())

    def test_transactional_install_refuses_to_delete_a_stale_backup(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            live = root / "live" / "bc_pdf_vector_importer"
            stage = self.make_runtime(root / "stage", marker=b"new")
            (live / "bin").mkdir(parents=True)
            (live / "bin/old.dll").write_bytes(b"old")
            stale = live.parent / (live.name + ".poppler-backup")
            stale.mkdir()
            (stale / "do-not-delete.txt").write_bytes(b"preserve")
            self.write(stage)

            count, size = self.totals(stage)
            inventory_digest = prc._member_inventory_digest(
                prc._build_member_entries(stage)
            )
            with (
                mock.patch.object(prc, "PINNED_DATA_FILE_COUNT", count),
                mock.patch.object(prc, "PINNED_DATA_TOTAL_BYTES", size),
                mock.patch.object(
                    prc, "PINNED_MEMBER_INVENTORY_SHA256", inventory_digest
                ),
                self.assertRaisesRegex(prc.ContractError, "backup.*already exists"),
            ):
                prc.transactional_install(stage, live)
            self.assertEqual(b"preserve", (stale / "do-not-delete.txt").read_bytes())
            self.assertEqual(b"old", (live / "bin/old.dll").read_bytes())

    def test_archive_uses_the_same_exact_manifest(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            support = self.make_runtime(root)
            self.write(support)
            archive = root / "x.rbz"
            with zipfile.ZipFile(archive, "w") as zf:
                for path in support.rglob("*"):
                    if path.is_file():
                        zf.write(path, "bc_pdf_vector_importer/" + path.relative_to(support).as_posix())
            first, second, third = self.fixture_pins(support)
            with first, second, third:
                prc.verify_archive(archive, "bc_pdf_vector_importer")
            with zipfile.ZipFile(archive, "a") as zf:
                zf.writestr("bc_pdf_vector_importer/Library/bin/extra.dll", b"x")
            first, second, third = self.fixture_pins(support)
            with first, second, third, self.assertRaisesRegex(prc.ContractError, "extra"):
                prc.verify_archive(archive, "bc_pdf_vector_importer")


if __name__ == "__main__":
    unittest.main()

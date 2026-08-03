from __future__ import annotations

import hashlib
import tempfile
import unittest
import zipfile
from pathlib import Path

import build_steel_shapes_release


class SteelShapesReleaseBuilderTest(unittest.TestCase):
    def fixture(self, root: Path) -> Path:
        source = root / "steel_shapes"
        (source / "skp").mkdir(parents=True)
        (source / "README.md").write_text("Synthetic SketchUp shape pack\n", encoding="utf-8")
        (source / "skp" / "shape.skp").write_bytes(b"synthetic-skp")
        return source

    def test_build_is_reproducible_and_checksums_are_exact(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = self.fixture(root)
            first = build_steel_shapes_release.build(source, root / "out-a", "steel-v1.0.1")
            second = build_steel_shapes_release.build(source, root / "out-b", "steel-v1.0.1")

            self.assertEqual(first.versioned.read_bytes(), second.versioned.read_bytes())
            self.assertEqual(first.versioned.read_bytes(), first.latest.read_bytes())
            digest = hashlib.sha256(first.versioned.read_bytes()).hexdigest()
            self.assertEqual(
                first.checksums.read_text(encoding="ascii"),
                f"{digest}  {first.versioned.name}\n{digest}  {first.latest.name}\n",
            )
            with zipfile.ZipFile(first.versioned) as archive:
                self.assertEqual(["README.md", "skp/shape.skp"], archive.namelist())
                self.assertTrue(
                    all(member.date_time == (1980, 1, 1, 0, 0, 0) for member in archive.infolist())
                )
                self.assertTrue(
                    all((member.external_attr >> 16) == 0o100644 for member in archive.infolist())
                )

    def test_build_rejects_machine_paths_and_foreign_private_artifacts(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = self.fixture(root)
            (source / "skp" / "shape.skp").write_bytes(
                b"C:\\Users\\Example\\Desktop\\shape.skp"
            )
            with self.assertRaisesRegex(RuntimeError, "machine-bound path"):
                build_steel_shapes_release.build(source, root / "path-out", "steel-v1.0.1")

            (source / "skp" / "shape.skp").write_bytes(b"synthetic-skp")
            (source / "customer.pdf").write_bytes(b"%PDF-1.4\n")
            with self.assertRaisesRegex(RuntimeError, "private CAD/PDF artifact extension"):
                build_steel_shapes_release.build(source, root / "pdf-out", "steel-v1.0.1")

    def test_workflow_is_exact_convergent_and_nonlatest(self):
        root = Path(__file__).resolve().parents[1]
        workflow = (root / ".github" / "workflows" / "steel-shapes-release.yml").read_text(
            encoding="utf-8"
        )
        self.assertIn("tools/build_steel_shapes_release.py", workflow)
        self.assertIn("tools/complete_github_release.py", workflow)
        self.assertIn('--target "$GITHUB_SHA"', workflow)
        self.assertNotIn("--latest", workflow)
        self.assertNotIn("softprops/action-gh-release", workflow)
        self.assertNotIn("overwrite_files", workflow)


if __name__ == "__main__":
    unittest.main(verbosity=2)

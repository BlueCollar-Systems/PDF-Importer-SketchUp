"""Real bundle integrity, notice/source identity and fail-closed build gates."""
import json
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest import mock
from tools import ghostscript_runtime as gs
from tools import smoke_ghostscript_runtime as smoke
import build_release

class GhostscriptRuntimeTest(unittest.TestCase):
    def fixture(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        root=Path(temp.name)
        shutil.copytree(gs.SUPPORT/'Ghostscript',root/'Ghostscript')
        return root

    def test_real_inventory_and_pe_dependency_closure(self):
        manifest=gs.validate()
        self.assertEqual(221,len(manifest['license_notices']))
        self.assertIn('Resource/CMap/Adobe-GB1-0.notice.txt',manifest['license_notices'])
        self.assertIn('jpeg/README',manifest['license_notices'])
        self.assertIn('ijs/ijs.h.txt',manifest['license_notices'])
        self.assertIn('DroidSansFallback.NOTICE',manifest['license_notices'])

    def test_changed_binary_fails(self):
        root=self.fixture(); path=root/'Ghostscript/bin/gswin64c.exe'
        path.write_bytes(path.read_bytes()+b'changed')
        with self.assertRaisesRegex(RuntimeError,'inventory/hash'):gs.validate(root)

    def test_nested_manifest_is_an_unexpected_member(self):
        root=self.fixture()
        (root/'Ghostscript/bin/runtime-manifest.json').write_text('{}')
        with self.assertRaisesRegex(RuntimeError,'inventory/hash'):gs.validate(root)

    def test_missing_crt_or_added_binary_fails(self):
        root=self.fixture();path=root/'Ghostscript/bin/msvcp140.dll';path.unlink()
        with self.assertRaisesRegex(RuntimeError,'inventory/hash'):gs.validate(root)
        (root/'Ghostscript/bin/surprise.dll').write_bytes(b'MZ')
        with self.assertRaisesRegex(RuntimeError,'inventory/hash'):gs.validate(root)

    def test_modified_notice_cannot_be_reapproved_by_rewriting_manifest(self):
        root=self.fixture(); (root/'Ghostscript/licenses/doc/COPYING').write_text('shortened')
        path=root/'Ghostscript/runtime-manifest.json';data=json.loads(path.read_text())
        data['members']=gs.inventory(root/'Ghostscript');path.write_text(json.dumps(data))
        with self.assertRaisesRegex(RuntimeError,'inventory/hash'):gs.validate(root)

    def test_wrong_source_url_fails_even_with_unchanged_payload(self):
        root=self.fixture();path=root/'Ghostscript/runtime-manifest.json';data=json.loads(path.read_text())
        data['corresponding_source']['url']='https://example.invalid/source'
        path.write_text(json.dumps(data))
        with self.assertRaisesRegex(RuntimeError,'corresponding source'):gs.validate(root)

    def test_release_build_requires_ghostscript_validation(self):
        with mock.patch.object(build_release.ghostscript_runtime,'validate',side_effect=RuntimeError('gs rejected')):
            with self.assertRaisesRegex(RuntimeError,'gs rejected'):build_release._require_bundled_runtime()

    def test_required_native_smoke_cannot_silently_skip_non_windows(self):
        with mock.patch.object(smoke.os,'name','posix'):
            # Validation happens first; pin identity cannot be replaced by a skip.
            with mock.patch.object(smoke.gs,'validate'):
                with self.assertRaisesRegex(RuntimeError,'needs Windows'):smoke.smoke(required=True)

    def test_windows_workflows_include_explicit_integrity_and_native_smoke(self):
        for name in ('auto-release.yml','su-pdfimporter-ci.yml'):
            text=(gs.ROOT/'.github/workflows'/name).read_text()
            self.assertIn('python -m unittest tools.test_ghostscript_runtime',text)
            self.assertIn('python tools/smoke_ghostscript_runtime.py --required',text)

if __name__=='__main__': unittest.main()

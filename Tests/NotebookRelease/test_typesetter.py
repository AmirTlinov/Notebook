from pathlib import Path
import json, tempfile, unittest
from unittest.mock import patch
import prepare_notebook_typesetter as runtime
from notebook_macho import macho
import typesetter_fixture as fixture
import macho_fixture

class TypesetterPackagingTests(unittest.TestCase):
    def setUp(self):
        temporary=tempfile.TemporaryDirectory();self.addCleanup(temporary.cleanup)
        self.root=fixture.stage(Path(temporary.name)/'runtime')
        for name,value in {'LOCK':fixture.LOCK,'input_digest':lambda:fixture.IDENTITY}.items():
            p=patch.object(runtime,name,value);p.start();self.addCleanup(p.stop)
    def test_bundle_check_never_builds_or_changes_resources(self):
        before={p:p.stat().st_mtime_ns for p in self.root.rglob('*')}
        with patch.object(runtime.subprocess,'run',side_effect=AssertionError('not a builder')):
            runtime.check_bundle(self.root)
        self.assertEqual(before,{p:p.stat().st_mtime_ns for p in self.root.rglob('*')})
    def test_changed_added_missing_and_symlinked_resources_are_rejected(self):
        for change in ['changed','added','missing','symlink']:
            with self.subTest(change=change):
                import shutil
                shutil.rmtree(self.root);fixture.stage(self.root)
                path=self.root/'fonts.tsv'
                if change=='changed':path.write_bytes(b'changed')
                elif change=='added':(self.root/'user.tex').write_bytes(b'private')
                elif change=='missing':path.unlink()
                else:path.unlink();path.symlink_to(self.root/'latex.fmt')
                with self.assertRaises(RuntimeError):runtime.check_bundle(self.root)
    def test_foreign_source_identity_is_rejected(self):
        path=self.root/'manifest.json';value=json.loads(path.read_text());value['inputSHA256']='other';path.write_text(json.dumps(value))
        with self.assertRaisesRegex(RuntimeError,'identity'):runtime.check_bundle(self.root)
    def test_manifest_cannot_repin_distribution(self):
        path=self.root/'texlive.zip';path.write_bytes(b'foreign')
        manifest=self.root/'manifest.json';value=json.loads(manifest.read_text());value['files']['texlive.zip']=fixture.pin(b'foreign');manifest.write_text(json.dumps(value))
        with self.assertRaisesRegex(RuntimeError,'distribution pin'):runtime.check_bundle(self.root)
    def test_macho_signatures_cannot_hide_code_or_foreign_libraries(self):
        a=macho(macho_fixture.executable());b=macho(macho_fixture.executable(b'resigned larger signature'))
        self.assertEqual(a,b)
        code=bytearray(macho_fixture.executable());code[254]=1
        self.assertNotEqual(a['codeSHA256'],macho(bytes(code))['codeSHA256'])
        with self.assertRaisesRegex(RuntimeError,'Non-system'):macho(macho_fixture.executable(library='/tmp/foreign.dylib'))

"""Strict packaging contracts against synthetic CPU fixtures, not app acceptance."""
from pathlib import Path
import json
import os
import tempfile
import unittest
from unittest.mock import patch
import prepare_notebook_images as images
import image_fixture


class ImagePackagingTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name);self.source=image_fixture.source(self.root/'source')
        self.stage=image_fixture.stage(self.root/'stage',self.source)
        self.helper=self.stage/'Helpers/notebook-image-compiler'

    def check(self,**options):return images.check(self.stage,self.source,**options)

    def test_check_is_read_only_and_never_invokes_cargo_or_network(self):
        before={p:p.stat().st_mtime_ns for p in self.stage.rglob('*')}
        with patch.object(images.subprocess,'run',side_effect=AssertionError('must not build')), \
             patch.object(images.subprocess,'check_output',side_effect=AssertionError('must not discover')):
            self.check()
        self.assertEqual(before,{p:p.stat().st_mtime_ns for p in self.stage.rglob('*')})

    def test_signature_replacement_preserves_code_but_unsigned_stage_is_immutable(self):
        before=self.check()['binaryInspection']['codeSHA256']
        self.helper.write_bytes(image_fixture.executable(b'a-new-larger-development-signature'))
        self.assertEqual(self.check(signed=True)['binaryInspection']['codeSHA256'],before)
        with self.assertRaisesRegex(RuntimeError,'bytes changed'):self.check()

    def test_code_change_cannot_be_hidden_by_signature_normalization(self):
        data=bytearray(self.helper.read_bytes());data[254]=1;self.helper.write_bytes(data)
        with self.assertRaisesRegex(RuntimeError,'fingerprint changed'):self.check(signed=True)

    def test_added_untracked_resource_and_symlink_are_rejected(self):
        extra=self.stage/'user-document.txt';extra.write_text('not a runtime resource')
        with self.assertRaisesRegex(RuntimeError,'untracked'):self.check()
        extra.unlink();extra.symlink_to(self.source/'Cargo.lock')
        with self.assertRaisesRegex(RuntimeError,'symlink'):self.check()

    def test_different_source_lock_requires_a_new_stage(self):
        (self.source/'Cargo.lock').write_text('# changed lock\n')
        with self.assertRaisesRegex(RuntimeError,'pinned source'):self.check()

    def test_dependency_and_toolchain_pins_are_checked(self):
        manifest=self.source/'Cargo.toml';manifest.write_text(manifest.read_text().replace('=0.8.2','=0.8.3'))
        with self.assertRaisesRegex(RuntimeError,'dependency pins'):images.source_inputs(self.source)

    def test_source_copy_must_match_its_own_declared_fingerprint(self):
        path=self.stage/'Resources/NotebookImages/source/src/main.rs';path.write_text('// foreign source')
        manifest_path=self.stage/'Resources/NotebookImages/manifest.json';manifest=json.loads(manifest_path.read_text())
        manifest['resources'][str(path.relative_to(self.stage))]=images.file_pin(path);manifest_path.write_text(json.dumps(manifest))
        with self.assertRaisesRegex(RuntimeError,'source differs'):self.check()

    def test_third_party_dylib_is_rejected_even_before_signing(self):
        with self.assertRaisesRegex(RuntimeError,'Non-system'):images.macho(image_fixture.executable(library='/opt/local/lib/evil.dylib'))

    def test_wrong_architecture_and_deployment_target_are_rejected(self):
        for offset,value in [(4,(0x01000007).to_bytes(4,'little')),(32+72+12,(26<<16).to_bytes(4,'little'))]:
            data=bytearray(image_fixture.executable());data[offset:offset+4]=value
            with self.subTest(offset=offset),self.assertRaises(RuntimeError):images.macho(bytes(data))

    def test_bundle_container_mode_does_not_mix_tex_inventory_with_image_stage(self):
        (self.stage/'Resources/NotebookTeX').mkdir();(self.stage/'Resources/NotebookTeX/manifest.json').write_text('separate TeX resource')
        self.check(signed=True,container=True)
        with self.assertRaisesRegex(RuntimeError,'untracked'):self.check()

    def test_clean_build_outputs_cover_nested_resources_and_reject_stale_declarations(self):
        manifest=self.check();declared=self.root/'images.xcfilelist'
        declared.write_text(images.bundle_outputs(manifest))
        images.check_bundle_outputs(manifest,declared)
        entries=set(declared.read_text().splitlines())
        prefix='$(TARGET_BUILD_DIR)/$(CONTENTS_FOLDER_PATH)/'
        for path in (self.stage/'Resources/NotebookImages').rglob('*'):
            self.assertIn(prefix+str(path.relative_to(self.stage)),entries)
        self.assertIn(prefix+'Helpers/notebook-image-compiler',entries)
        self.assertNotIn(prefix+'Resources',entries)
        self.assertNotIn(prefix+'Helpers',entries)
        declared.write_text(declared.read_text().replace(prefix+'Resources/NotebookImages/source/src\n',''))
        with self.assertRaisesRegex(RuntimeError,'output.*inventory'):images.check_bundle_outputs(manifest,declared)

    def test_image_output_inventory_cannot_grant_unrelated_files(self):
        manifest=self.check()
        manifest['resources']['Resources/NotebookImages/../../unrelated']={}
        with self.assertRaisesRegex(RuntimeError,'escapes'):images.bundle_outputs(manifest)

if __name__=='__main__':unittest.main()

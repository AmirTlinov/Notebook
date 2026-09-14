"""Private configuration/evidence CPU contracts; no runner or capture starts."""
import json
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
import uuid
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'Applications'))
import notebook_interaction_acceptance as driver
import notebook_release as release


class DriverContracts(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup);self.root=Path(self.temp.name)
        self.run=self.root/'run';self.run.mkdir();self.session=str(uuid.uuid4());self.run_id=str(uuid.uuid4())
        self.control=self.run/'interaction'
        self.args=SimpleNamespace(test=driver.SUITE,platform='ipad',trace=None,pencil=False,run=self.run,
            interaction_session=self.session,interaction_control_directory=self.control)
        self.container=self.root/'container';self.store=self.container/'Documents'/self.run_id/'store';self.store.mkdir(parents=True)
        self.build=self.root/'build';snapshot=self.build/'source';self.sources={}
        for name in driver.NATIVE_FILES:
            p=snapshot/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_text('// NotebookInteractionDiagnostics synthetic source\n')
            self.sources[name]=release.file_digest(p)
        (self.build/'source.json').write_text(json.dumps({'sha256':'source-sha','files':[{'path':p,'sha256':sha} for p,sha in self.sources.items()]}))
        self.value={'build':str(self.build),'runID':self.run_id,'workspaceID':'workspace'}
        self.built={'sourceSHA256':'source-sha','simulator':{'udid':'simulator'}}
        self.manifest={'root':str(self.store),'runID':self.run_id,'workspaceID':'workspace','role':'iPad','bundleID':'com.amirtlinov.notebook.acceptance'}

    def prepare(self):return driver.prepare(self.value,self.built,self.manifest,self.container,driver.request(self.args))

    def test_only_exact_explicit_touch_scenario_is_enabled(self):
        self.assertEqual(driver.request(self.args)['sessionID'],self.session)
        for key,value in [('platform','mac'),('trace','Time Profiler'),('pencil',True),('interaction_session','bad'),
                          ('interaction_session',str(uuid.UUID(int=0))),('interaction_control_directory',Path('relative')),
                          ('test','NotebookAcceptanceUITests/testOther')]:
            before=getattr(self.args,key);setattr(self.args,key,value)
            with self.subTest(key=key),self.assertRaises(release.ReleaseError):driver.request(self.args)
            setattr(self.args,key,before)

    def test_control_cannot_escape_or_overwrite_evidence(self):
        for path in (self.root/'outside',self.run):
            self.args.interaction_control_directory=path
            with self.assertRaises(release.ReleaseError):driver.request(self.args)
        self.args.interaction_control_directory=self.control;self.control.mkdir()
        with self.assertRaises(release.ReleaseError):driver.request(self.args)
        self.control.rmdir();self.control.symlink_to(self.root/'outside')
        with self.assertRaises(release.ReleaseError):driver.request(self.args)

    def test_unrelated_scenario_without_flags_is_unchanged(self):
        self.args.test='NotebookAcceptanceUITests/testOther';self.args.interaction_session=None;self.args.interaction_control_directory=None
        self.assertIsNone(driver.request(self.args))

    def test_manifest_outside_current_private_container_fails_before_output(self):
        for key,value in [('root',str(self.root/'outside')),('bundleID','production'),('workspaceID','other'),('role','mac')]:
            original=self.manifest[key];self.manifest[key]=value
            with self.subTest(key=key),self.assertRaises(release.ReleaseError):self.prepare()
            self.assertFalse(self.control.exists());self.manifest[key]=original

    def test_old_or_modified_app_snapshot_cannot_be_fixed_by_ui_only_bundle(self):
        path=self.build/'source'/driver.NATIVE_FILES[0];path.unlink()
        with self.assertRaises(release.ReleaseError):self.prepare()
        self.assertFalse(self.control.exists())

    def test_output_tracks_source_manifest_container_and_has_no_pass(self):
        result=self.prepare();self.assertEqual(result['nativeSources'],self.sources)
        self.assertFalse(result['latencyMeasured']);self.assertEqual(result['environment']['NOTEBOOK_INTERACTION_SESSION_ID'],self.session)
        self.assertTrue((self.control/'configuration.json').exists())

    def test_cleanup_cancels_own_session_and_missing_native_remains_unmeasured(self):
        result=self.prepare();evidence=self.root/'evidence';evidence.mkdir()
        receipt=driver.stop_and_collect(result,evidence)
        self.assertEqual(receipt['status'],'unmeasured');self.assertFalse(receipt['latencyMeasured'])
        self.assertEqual(json.loads((self.control/'cancel.json').read_text()),{'sessionID':self.session,'status':'cancelled'})

    def test_cleanup_copies_native_bytes_without_deleting_or_claiming_display(self):
        result=self.prepare();journal=Path(result['nativeJournalDirectory']);journal.mkdir()
        native=journal/(self.session+'-launch.ndjson');data=(json.dumps({'kind':'identity','sessionID':self.session,'workspaceID':'workspace'})+'\n').encode();native.write_bytes(data)
        (self.control/'ui-ended.json').write_text('{}');evidence=self.root/'evidence';evidence.mkdir()
        receipt=driver.stop_and_collect(result,evidence)
        self.assertEqual(native.read_bytes(),data);self.assertEqual((evidence/native.name).read_bytes(),data)
        self.assertEqual(receipt['status'],'captured_unassessed');self.assertFalse(receipt['latencyMeasured'])
        self.assertFalse((self.control/'cancel.json').exists())

    def test_foreign_native_journal_is_rejected(self):
        result=self.prepare();journal=Path(result['nativeJournalDirectory']);journal.mkdir()
        (journal/(self.session+'-launch.ndjson')).write_text(json.dumps({'kind':'identity','sessionID':self.session,'workspaceID':'other'})+'\n')
        evidence=self.root/'evidence';evidence.mkdir()
        with self.assertRaises(release.ReleaseError):driver.stop_and_collect(result,evidence)

if __name__=='__main__':unittest.main()

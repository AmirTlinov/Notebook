"""Evidence admission/collection contracts; no simulator or UI is started."""
import json
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
import uuid
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Applications"))
import notebook_scene_observation as driver
import notebook_release as release
import notebook_acceptance as acceptance


class SceneObservationContracts(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(); self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.session = str(uuid.uuid4()); self.run = str(uuid.uuid4())
        self.args = SimpleNamespace(platform="ipad", scene_observation_session=self.session)
        self.container = self.root / "container"
        self.store = self.container / "Documents" / self.run / "store"
        self.store.mkdir(parents=True)
        self.build = self.root / "build"; self.sources = {}
        for name in driver.NATIVE_FILES:
            path = self.build / "source" / name; path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("// synthetic NotebookSceneObservation observedTileInstallation\n")
            self.sources[name] = release.file_digest(path)
        (self.build / "source.json").write_text(json.dumps({"sha256": "snapshot",
            "files": [{"path": name, "sha256": sha} for name, sha in self.sources.items()]}))
        self.value = {"build": str(self.build), "runID": self.run, "workspaceID": str(uuid.uuid4()).upper()}
        self.built = {"sourceSHA256": "snapshot", "sourceRevision": "1" * 40, "simulator": {"udid": "simulator"}}
        self.manifest = {"root": str(self.store), "runID": self.run, "workspaceID": self.value["workspaceID"],
                         "bundleID": "com.amirtlinov.notebook.acceptance", "role": "iPad",
                         "sourceRevision": "2" * 40}
        self.launch_manifest = self.store.parent / "launch.json"
        self.evidence = self.root / "evidence"; self.evidence.mkdir()

    def prepare(self):
        self.launch_manifest.write_text(json.dumps(self.manifest))
        return driver.prepare(self.value, self.built, self.manifest, self.container, driver.request(self.args))

    def journal(self, value, **overrides):
        directory = Path(value["nativeJournalDirectory"]); directory.mkdir(exist_ok=True)
        path = directory / (self.session + "-" + str(uuid.uuid4()) + ".ndjson")
        first = {"kind": "identity", "format": 1, "sessionID": self.session,
                 "acceptanceRunID": self.run.upper(), "workspaceID": self.value["workspaceID"],
                 "sourceRevision": self.manifest["sourceRevision"], "simulatorUDID": "simulator",
                 "bundleID": self.manifest["bundleID"], "elementID": driver.TARGET,
                 "textRecorded": False, "displayMeasured": False, **overrides}
        path.write_text(json.dumps(first) + "\n")
        return path

    def test_opt_in_is_only_nonzero_uuid_on_ipad(self):
        self.assertEqual(driver.request(self.args)["sessionID"], self.session)
        for value in ("", "invalid", str(uuid.UUID(int=0))):
            self.args.scene_observation_session = value
            with self.subTest(value=value), self.assertRaises(release.ReleaseError): driver.request(self.args)
        self.args.scene_observation_session = None
        self.assertIsNone(driver.request(self.args))
        self.args.scene_observation_session = self.session; self.args.platform = "mac"
        with self.assertRaises(release.ReleaseError): driver.request(self.args)

    def test_container_role_run_and_workspace_cannot_be_substituted(self):
        for key, value in (("root", str(self.root / self.run)), ("role", "mac"),
                           ("runID", str(uuid.uuid4())), ("workspaceID", "other"), ("bundleID", "production")):
            previous = self.manifest[key]; self.manifest[key] = value
            with self.subTest(key=key), self.assertRaises(release.ReleaseError): self.prepare()
            self.manifest[key] = previous

    def test_native_snapshot_is_required_even_with_new_ui_driver(self):
        path = self.build / "source" / driver.NATIVE_FILES[0]
        original = path.read_bytes(); path.write_bytes(original + b"changed")
        with self.assertRaises(release.ReleaseError): self.prepare()
        path.unlink()
        with self.assertRaises(release.ReleaseError): self.prepare()

    def test_prepare_is_read_only_and_records_owner_hashes(self):
        value = self.prepare()
        self.assertEqual(value["nativeSources"], self.sources)
        self.assertFalse(Path(value["nativeJournalDirectory"]).exists())
        self.assertFalse(value["displayMeasured"])
        self.assertEqual(value["environment"], {"NOTEBOOK_SCENE_OBSERVATION_SESSION_ID": self.session})

    def test_missing_journal_is_unobserved_not_pass(self):
        receipt = driver.collect(self.prepare(), self.evidence, launch_manifest=self.launch_manifest)
        self.assertEqual(receipt["status"], "unobserved")
        self.assertFalse(receipt["displayMeasured"])

    def test_bytes_are_preserved_and_existing_evidence_is_never_overwritten(self):
        value = self.prepare(); path = self.journal(value); original = path.read_bytes()
        result = driver.collect(value, self.evidence, launch_manifest=self.launch_manifest)
        self.assertEqual(result["status"], "observed_unassessed")
        self.assertEqual(path.read_bytes(), original)
        self.assertEqual((self.evidence / path.name).read_bytes(), original)
        with self.assertRaises(release.ReleaseError): driver.collect(value, self.evidence, launch_manifest=self.launch_manifest)
        with self.assertRaises(release.ReleaseError): self.prepare()

    def test_upgrade_keeps_configuration_and_native_build_provenance_separate(self):
        value = self.prepare(); self.journal(value)
        result = driver.collect(value, self.evidence, launch_manifest=self.launch_manifest)
        self.assertNotEqual(self.manifest["sourceRevision"], self.built["sourceRevision"])
        self.assertEqual(result["launchConfiguration"]["sourceRevision"], self.manifest["sourceRevision"])
        self.assertEqual(result["launchConfiguration"]["fileSHA256"], release.file_digest(self.launch_manifest))
        self.assertEqual(result["nativeBuild"]["sourceRevision"], self.built["sourceRevision"])
        self.assertEqual(result["nativeBuild"]["nativeSources"], self.sources)

    def test_header_cannot_substitute_native_revision_for_configuration_revision(self):
        value = self.prepare(); self.journal(value, sourceRevision=self.built["sourceRevision"])
        with self.assertRaises(release.ReleaseError):
            driver.collect(value, self.evidence, launch_manifest=self.launch_manifest)
        self.assertEqual(list(self.evidence.iterdir()), [])

    def test_actual_launch_manifest_cannot_change_or_escape_after_preparation(self):
        value = self.prepare(); self.journal(value)
        for changed in ({**self.manifest, "sourceRevision": "3" * 40},
                        {**self.manifest, "workspaceID": str(uuid.uuid4()).upper()},
                        {**self.manifest, "root": str(self.container / "different")},
                        {**self.manifest, "simulatorContact": "pencil"}):
            self.launch_manifest.write_text(json.dumps(changed))
            with self.subTest(changed=changed), self.assertRaises(release.ReleaseError):
                driver.collect(value, self.evidence, launch_manifest=self.launch_manifest)
        self.launch_manifest.write_text(json.dumps(self.manifest))
        outside = self.root / "outside.json"; outside.write_bytes(self.launch_manifest.read_bytes())
        with self.assertRaises(release.ReleaseError):
            driver.collect(value, self.evidence, launch_manifest=outside)
        self.launch_manifest.unlink(); self.launch_manifest.symlink_to(outside)
        with self.assertRaises(release.ReleaseError):
            driver.collect(value, self.evidence, launch_manifest=self.launch_manifest)
        self.assertEqual(list(self.evidence.iterdir()), [])

    def test_foreign_build_or_display_claim_is_rejected(self):
        value = self.prepare()
        for key, wrong in (("sourceRevision", "other"), ("workspaceID", "other"),
                           ("acceptanceRunID", str(uuid.uuid4())), ("simulatorUDID", "other"),
                           ("displayMeasured", True), ("textRecorded", True), ("elementID", "foreign")):
            path = self.journal(value, **{key: wrong})
            with self.subTest(key=key), self.assertRaises(release.ReleaseError): driver.collect(value, self.evidence, launch_manifest=self.launch_manifest)
            path.unlink()

    def test_symlink_and_oversized_journal_are_rejected(self):
        value = self.prepare(); path = self.journal(value)
        path.unlink(); outside = self.root / "outside"; outside.write_text("private")
        path.symlink_to(outside)
        with self.assertRaises(release.ReleaseError): driver.collect(value, self.evidence, launch_manifest=self.launch_manifest)
        path.unlink()
        with path.open("wb") as handle: handle.truncate(driver.MAX_BYTES + 1)
        with self.assertRaises(release.ReleaseError): driver.collect(value, self.evidence, launch_manifest=self.launch_manifest)

    def test_failed_collection_preserves_primary_failure_and_remaining_cleanup(self):
        primary = RuntimeError("original UI failure")
        recording = Mock()
        with patch.object(driver, "collect", side_effect=release.ReleaseError("invalid journal")):
            acceptance.finalize_ui_attempt(evidence=self.evidence, scenario={"scenario": "synthetic failure", "launchManifest": str(self.launch_manifest)},
                primary_error=primary, trace=None, trace_finished=False, recording=recording,
                installed_before=None, simulator="unused", scene={"sessionID": self.session})
        recording.stop.assert_called_once()
        result = json.loads((self.evidence / "scenario.json").read_text())
        self.assertEqual(result["primaryError"]["message"], "original UI failure")
        self.assertEqual(result["cleanupErrors"][0]["stage"], "scene-observation.collect")


if __name__ == "__main__": unittest.main()

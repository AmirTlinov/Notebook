"""Portable NB30 bytes/structure/admission tests. Apple codesign is mocked."""
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "Applications"))
import prepare_notebook_codex as codex
import codex_fixture


class CodexPackagingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="notebook-codex-contract-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.source = self.root / "source"
        self.runtime, self.archives, self.files = codex_fixture.source(self.source)
        self.cache = self.root / "notebook-codex-runtimes"
        signer = patch.object(codex, "signature")
        self.signer = signer.start(); self.addCleanup(signer.stop)
        download = patch.object(codex.urllib.request, "urlopen", side_effect=self.open_archive)
        self.download = download.start(); self.addCleanup(download.stop)

    def open_archive(self, url, timeout):
        self.assertEqual(timeout, 60)
        role = next(name for name, value in self.runtime["archives"].items() if value["url"] == url)
        return io.BytesIO(self.archives[role])

    def prepare(self):
        return codex.prepare(self.cache, self.runtime)

    def admitted(self):
        report = self.prepare()
        return Path(report["stage"]), report

    def test_fresh_and_reuse_share_one_pinned_receipt_without_download_copy_or_rewrite(self):
        stage, first = self.admitted()
        original = {str(p.relative_to(stage)): (p.stat().st_ino, p.stat().st_mtime_ns) for p in stage.rglob("*")}
        self.assertEqual(stage.name, codex.identity(self.runtime)["manifestSHA256"])
        with patch.object(codex, "payload_digest", wraps=codex.payload_digest) as hashed:
            self.assertEqual(self.prepare(), first)
        self.assertEqual(hashed.call_count, sum(row["type"] == "file" for row in self.runtime["entries"]) + 1)
        self.assertEqual(self.download.call_count, 2)
        self.assertEqual(original, {str(p.relative_to(stage)): (p.stat().st_ino, p.stat().st_mtime_ns) for p in stage.rglob("*")})
        self.assertEqual(len(self.signer.call_args_list), 4)
        codex.validate_report(first, lock_path=self.source / "Applications/NotebookCodexRuntime.lock.json", stage_root=self.cache)

    def test_tampered_bytes_in_main_node_or_helper_are_rejected_before_native_execution(self):
        stage, _ = self.admitted()
        for name in ("codex/bin/codex", "node", "codex/codex-resources/helper.dat"):
            with self.subTest(name=name):
                path = stage / name; original = path.read_bytes(); path.write_bytes(b"x" + original[1:])
                with patch.object(codex, "executable_version") as executable:
                    self.signer.reset_mock()
                    with self.assertRaisesRegex(RuntimeError, "bytes differ"): self.prepare()
                    self.signer.assert_not_called(); executable.assert_not_called()
                path.write_bytes(original)

    def test_missing_truncated_extra_and_mode_changed_entries_are_rejected(self):
        stage, _ = self.admitted(); path = stage / "codex/codex-resources/helper.dat"; original = path.read_bytes()
        cases = [(lambda: path.unlink(), "incomplete"), (lambda: path.write_bytes(original[:-1]), "length or link count differs"),
                 (lambda: path.chmod(0o755), "type/mode differs")]
        for mutate, error in cases:
            with self.subTest(error=error):
                mutate()
                with self.assertRaisesRegex(RuntimeError, error): self.prepare()
                path.write_bytes(original); path.chmod(0o644)
        extra = stage / "unexpected"; extra.write_text("extra")
        with self.assertRaisesRegex(RuntimeError, "Unexpected runtime entry"): self.prepare()

    def test_links_directories_and_special_files_cannot_replace_expected_regular_files(self):
        stage, _ = self.admitted(); path = stage / "codex/codex-resources/helper.dat"; original = path.read_bytes()
        for kind in ("link", "directory", "fifo"):
            with self.subTest(kind=kind):
                path.unlink()
                if kind == "link": path.symlink_to(stage / "Node-LICENSE")
                elif kind == "directory": path.mkdir()
                else: os.mkfifo(path)
                with self.assertRaisesRegex(RuntimeError, "type/mode differs"): self.prepare()
                if kind == "directory": path.rmdir()
                else: path.unlink()
                path.write_bytes(original); path.chmod(0o644)

    def test_stage_and_parent_directories_cannot_be_symlinks(self):
        stage, _ = self.admitted(); saved = stage.with_name("saved"); stage.rename(saved); stage.symlink_to(saved, target_is_directory=True)
        with self.assertRaises(OSError): self.prepare()
        stage.unlink(); saved.rename(stage)
        path = stage / "codex/codex-resources"; saved = stage / "resources-saved"; path.rename(saved); path.symlink_to(saved, target_is_directory=True)
        with self.assertRaises(RuntimeError): self.prepare()

    def test_forged_cache_manifest_is_not_a_trust_anchor(self):
        stage, _ = self.admitted(); marker = stage / "runtime.json"; original = marker.read_bytes()
        for value in (b"{", original.replace(codex.identity(self.runtime)["manifestSHA256"].encode(), b"0" * 64)):
            with self.subTest(value=value[:20]):
                marker.write_bytes(value)
                with self.assertRaises(RuntimeError): self.prepare()
        marker.write_bytes(original)
        (stage / "NotebookCodexRuntime.lock.json").write_text(json.dumps({"entries": []}))
        with self.assertRaisesRegex(RuntimeError, "Unexpected runtime entry"): self.prepare()

    def test_actual_codex_and_node_version_outputs_are_both_required(self):
        stage, _ = self.admitted()
        for name in ("codex", "node"):
            def version(path):
                if path.name == name: return "wrong-version"
                return codex.expected_versions(self.runtime)["node" if path.name == "node" else "codex"]
            with self.subTest(name=name), patch.object(codex, "executable_version", side_effect=version):
                with self.assertRaisesRegex(RuntimeError, "executable version"): codex.check_stage(stage, self.runtime)

    def test_corrupt_official_archive_never_publishes_a_stage(self):
        self.archives["codex"] = b"x" + self.archives["codex"][1:]
        with self.assertRaisesRegex(RuntimeError, "archive checksum"): self.prepare()
        self.assertFalse((self.cache / codex.identity(self.runtime)["manifestSHA256"]).exists())
        self.assertFalse(any(self.cache.glob(".prepare-*")))

    def test_incomplete_final_stage_is_refused_without_overwriting_or_downloading(self):
        stage = self.cache / codex.identity(self.runtime)["manifestSHA256"]; stage.mkdir(parents=True); stage.chmod(0o755)
        (stage / "runtime.json").write_text("unfinished")
        with self.assertRaises(RuntimeError): self.prepare()
        self.assertEqual((stage / "runtime.json").read_text(), "unfinished"); self.download.assert_not_called()

    def test_old_flat_cache_and_abandoned_temporary_stages_are_untouched_and_never_admitted(self):
        old = self.root / "notebook-codex-runtime"; old.mkdir(); (old / "runtime.json").write_text("old consumer")
        abandoned = self.cache / ".prepare-abandoned"; abandoned.mkdir(parents=True); (abandoned / "partial").write_text("partial")
        stage, _ = self.admitted()
        self.assertNotEqual(stage, old); self.assertEqual((old / "runtime.json").read_text(), "old consumer")
        self.assertEqual((abandoned / "partial").read_text(), "partial"); self.assertEqual(self.download.call_count, 2)

    def test_another_manifest_does_not_replace_or_delete_an_active_consumer_stage(self):
        old, report = self.admitted(); contents = (old / "codex/bin/codex").read_bytes()
        self.runtime, self.archives, self.files = codex_fixture.source(self.root / "new-source", "0.155.1")
        new, _ = self.admitted()
        self.assertNotEqual(old, new); self.assertTrue(old.is_dir()); self.assertEqual((old / "codex/bin/codex").read_bytes(), contents)
        self.assertEqual(json.loads((old / "runtime.json").read_text()), report["identity"])

    def test_bundle_rechecks_exact_copied_bytes_and_preserves_the_same_manifest(self):
        stage, report = self.admitted(); destination = self.root / "product/CodexRuntime"
        result = codex.bundle(stage, destination, self.runtime, self.source / "Applications/NotebookCodexResources.xcfilelist")
        self.assertEqual(result["identity"], report["identity"]); self.assertEqual(result["versions"], report["versions"])
        self.assertEqual(codex.check_payload(stage, self.runtime), codex.check_payload(destination, self.runtime))

    def test_copy_time_tamper_is_rejected_before_bundle_admission(self):
        stage, _ = self.admitted(); original = codex.copy_exact
        def mutate(source, output, size):
            original(source, output, size)
            if str(output.name).endswith("helper.dat"): output.seek(0); output.write(b"x" * size)
        with patch.object(codex, "copy_exact", side_effect=mutate):
            with self.assertRaisesRegex(RuntimeError, "bytes differ"):
                codex.bundle(stage, self.root / "product/CodexRuntime", self.runtime, self.source / "Applications/NotebookCodexResources.xcfilelist")
        codex.check_payload(stage, self.runtime)

    def test_bundle_cannot_mutate_its_source_stage(self):
        stage, _ = self.admitted()
        with self.assertRaisesRegex(RuntimeError, "Unsafe"):
            codex.bundle(stage, stage / "CodexRuntime", self.runtime, self.source / "Applications/NotebookCodexResources.xcfilelist")
        codex.check_payload(stage, self.runtime)

    def test_pinned_stdout_version_survives_codex_startup_diagnostics(self):
        original = codex_fixture.payload
        def diagnostic_payload(*args, **kwargs):
            files = original(*args, **kwargs)
            data, mode = files["codex/bin/codex"]
            warning = "WARNING: proceeding, even though we could not update PATH: Operation not permitted (os error 1)"
            data = data.replace(b"\n", ("\nimport sys\nprint(" + repr(warning) + ", file=sys.stderr)\n").encode(), 1)
            files["codex/bin/codex"] = (data, mode)
            return files
        with patch.object(codex_fixture, "payload", side_effect=diagnostic_payload):
            self.runtime, self.archives, self.files = codex_fixture.source(self.root / "diagnostic-source")
        stage, receipt = self.admitted()
        self.assertEqual(receipt["versions"], codex.expected_versions(self.runtime))
        self.assertEqual(self.prepare(), receipt)
        bundled = codex.bundle(stage, self.root / "product/CodexRuntime", self.runtime,
                              self.root / "diagnostic-source/Applications/NotebookCodexResources.xcfilelist")
        self.assertEqual(bundled["versions"], receipt["versions"])

    def test_stderr_cannot_supply_or_disguise_the_pinned_stdout_version(self):
        script = self.root / "version-probe"
        for stdout in ("", "wrong-version", "codex-cli 0.155.0\nextra output"):
            with self.subTest(stdout=stdout):
                script.write_text("#!" + sys.executable + "\nimport sys\n"
                                  "sys.stdout.write(" + repr(stdout) + ")\n"
                                  "print('codex-cli 0.155.0', file=sys.stderr)\n")
                script.chmod(0o755)
                self.assertEqual(codex.executable_version(script), stdout)
                self.assertNotEqual(codex.executable_version(script), "codex-cli 0.155.0")
        script.write_text("#!" + sys.executable + "\nprint('codex-cli 0.155.0')\nraise SystemExit(1)\n")
        with self.assertRaisesRegex(RuntimeError, "probe failed"):
            codex.executable_version(script)

    def test_version_probe_bounds_both_streams_and_waits_for_stderr(self):
        script = self.root / "version-probe"
        for statements in ("sys.stderr.write('x'*5000)",
                           "sys.stdout.write('x'*2500); sys.stderr.write('y'*2500)"):
            with self.subTest(statements=statements):
                script.write_text("#!" + sys.executable + "\nimport sys\n" + statements + "\n")
                script.chmod(0o755)
                with self.assertRaisesRegex(RuntimeError, "exceeds"):
                    codex.executable_version(script)
        script.write_text("#!" + sys.executable + "\nimport os,time\nos.close(1)\ntime.sleep(10)\n")
        with patch.object(codex, "VERSION_TIMEOUT", 0.05):
            with self.assertRaisesRegex(RuntimeError, "timed out"):
                codex.executable_version(script)

    def test_version_probe_rejects_excess_output_and_timeout(self):
        script = self.root / "version-probe"
        script.write_text("#!" + sys.executable + "\nprint('x'*5000)\n"); script.chmod(0o755)
        with self.assertRaisesRegex(RuntimeError, "exceeds"): codex.executable_version(script)
        script.write_text("#!" + sys.executable + "\nimport time\ntime.sleep(10)\n")
        with patch.object(codex, "VERSION_TIMEOUT", 0.05):
            with self.assertRaisesRegex(RuntimeError, "timed out"): codex.executable_version(script)

    def test_cancelled_preparation_cleans_its_temporary_and_releases_the_lease(self):
        original = codex.prepare_payload
        def cancel(stage, work, runtime):
            original(stage, work, runtime)
            raise KeyboardInterrupt("fixture cancellation")
        with patch.object(codex, "prepare_payload", side_effect=cancel):
            with self.assertRaises(KeyboardInterrupt): self.prepare()
        self.assertFalse(any(self.cache.glob(".prepare-*")))
        self.assertFalse((self.cache / codex.identity(self.runtime)["manifestSHA256"]).exists())
        self.admitted()

    def test_lease_wait_is_bounded_and_process_death_does_not_deadlock_next_writer(self):
        self.cache.mkdir(); key = codex.identity(self.runtime)["manifestSHA256"]
        lock = self.cache / (key + ".lock")
        code = "import fcntl,sys,time; f=open(sys.argv[1],'a+b'); fcntl.flock(f,fcntl.LOCK_EX); print('locked',flush=True); time.sleep(30)"
        process = subprocess.Popen([sys.executable, "-c", code, str(lock)], stdout=subprocess.PIPE)
        self.addCleanup(lambda: process.kill() if process.poll() is None else None)
        self.assertEqual(process.stdout.readline(), b"locked\n")
        with patch.object(codex, "LEASE_TIMEOUT", .05):
            started = time.monotonic()
            with self.assertRaisesRegex(RuntimeError, "lease timed out"): self.prepare()
            self.assertLess(time.monotonic() - started, 1)
        self.download.assert_not_called()
        process.kill(); process.wait(timeout=5); process.stdout.close()
        self.admitted()

    def test_failed_atomic_publication_never_deletes_an_existing_consumer(self):
        stage, first = self.admitted()
        original = (stage / "node").read_bytes()
        self.runtime, self.archives, self.files = codex_fixture.source(self.root / "next-source", "0.155.1")
        with patch.object(Path, "rename", side_effect=OSError("fixture rename failure")):
            with self.assertRaisesRegex(OSError, "rename failure"): self.prepare()
        self.assertFalse(any(self.cache.glob(".prepare-*")))
        self.assertEqual((stage / "node").read_bytes(), original)
        self.assertEqual(json.loads((stage / "runtime.json").read_text()), first["identity"])
        self.admitted()

    def test_external_hardlink_is_rejected_even_when_its_bytes_match(self):
        stage, _ = self.admitted()
        helper = stage / "codex/codex-resources/helper.dat"
        alias = self.root / "external-helper"; os.link(helper, alias)
        self.assertEqual(helper.stat().st_nlink, 2)
        with self.assertRaisesRegex(RuntimeError, "link count"):
            codex.check_payload(stage, self.runtime)

    def test_directory_swap_during_hashing_cannot_admit_a_symlink_parent(self):
        stage, _ = self.admitted(); original = codex.payload_digest; swapped = False
        def digest(stream):
            nonlocal swapped
            if not swapped:
                swapped = True
                external = self.root / "detached-codex"
                (stage / "codex").rename(external)
                (stage / "codex").symlink_to(external, target_is_directory=True)
            return original(stream)
        with patch.object(codex, "payload_digest", side_effect=digest):
            with self.assertRaisesRegex(RuntimeError, "changed during admission"):
                codex.check_payload(stage, self.runtime)

    def test_original_root_name_must_still_address_the_held_tree(self):
        stage, _ = self.admitted(); original = codex.payload_digest; swapped = False
        def digest(stream):
            nonlocal swapped
            if not swapped:
                swapped = True
                stage.rename(self.root / "detached-stage"); stage.mkdir(mode=0o755)
            return original(stream)
        with patch.object(codex, "payload_digest", side_effect=digest):
            with self.assertRaisesRegex(RuntimeError, "root changed"):
                codex.check_payload(stage, self.runtime)

    def test_later_hash_cannot_hide_mutation_of_an_already_hashed_file(self):
        stage, _ = self.admitted(); original = codex.payload_digest
        helper = stage / "codex/codex-resources/helper.dat"
        # fdopen streams have integer names; trigger at the deterministic final
        # Node file instead using the manifest-ordered hash call count.
        calls = 0; final = sum(row["type"] == "file" for row in self.runtime["entries"]) + 1
        def ordered_digest(stream):
            nonlocal calls
            calls += 1
            if calls == final: helper.write_bytes(b"x" + helper.read_bytes()[1:])
            return original(stream)
        with patch.object(codex, "payload_digest", side_effect=ordered_digest):
            with self.assertRaisesRegex(RuntimeError, "tree changed"):
                codex.check_payload(stage, self.runtime)

    def test_version_probe_cannot_mutate_an_already_checked_helper(self):
        stage, _ = self.admitted(); helper = stage / "codex/codex-resources/helper.dat"
        def version(path):
            if path.name == "node": helper.write_bytes(b"x" + helper.read_bytes()[1:])
            return codex.expected_versions(self.runtime)["node" if path.name == "node" else "codex"]
        with patch.object(codex, "executable_version", side_effect=version):
            with self.assertRaisesRegex(RuntimeError, "tree changed"):
                codex.check_stage(stage, self.runtime)

    def test_parent_descriptors_close_on_success_failure_and_cancellation(self):
        stage, _ = self.admitted(); original = os.open
        for failure in (None, RuntimeError("fixture failure"), KeyboardInterrupt("fixture cancellation")):
            descriptors = []
            def opened(path, flags, *args, **kwargs):
                descriptor = original(path, flags, *args, **kwargs)
                if flags & os.O_DIRECTORY: descriptors.append(descriptor)
                return descriptor
            with self.subTest(failure=failure), patch.object(codex.os, "open", side_effect=opened):
                if failure:
                    with patch.object(codex, "payload_digest", side_effect=failure), self.assertRaises(type(failure)):
                        codex.check_payload(stage, self.runtime)
                else: codex.check_payload(stage, self.runtime)
            self.assertTrue(descriptors)
            for descriptor in descriptors:
                with self.assertRaises(OSError): os.fstat(descriptor)

    def test_hash_admission_does_not_require_python_311_file_digest(self):
        stage, _ = self.admitted()
        with patch.object(hashlib, "file_digest", None, create=True):
            self.assertEqual(codex.check_payload(stage, self.runtime), codex.identity(self.runtime))

    def test_same_hash_concurrent_processes_publish_once_and_share_the_complete_stage(self):
        archives = self.root / "archives"; archives.mkdir()
        for name, value in self.archives.items(): (archives / (name + ".tar.gz")).write_bytes(value)
        log = self.root / "downloads"
        code = '''
import io,json,pathlib,shutil,sys,time
sys.path.insert(0,sys.argv[1]);import prepare_notebook_codex as c
source,cache,archives,log=map(pathlib.Path,sys.argv[2:])
r=c.admitted_runtime('arm64',source/'Applications/NotebookCodexRuntime.lock.json')
c.signature=lambda *args:None
urls={v['url']:name for name,v in r['archives'].items()}
def read(url,timeout):
 with log.open('a') as output:output.write(url+'\\n')
 time.sleep(.15)
 return (archives/(urls[url]+'.tar.gz')).open('rb')
c.urllib.request.urlopen=read
print(json.dumps(c.prepare(cache,r)))
'''
        argv = [sys.executable, "-c", code, str(codex.LOCK.parent), str(self.source), str(self.cache), str(archives), str(log)]
        first = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.addCleanup(lambda: first.kill() if first.poll() is None else None)
        deadline = time.monotonic() + 5
        while not log.exists() and time.monotonic() < deadline: time.sleep(.01)
        self.assertTrue(log.exists()); self.assertIsNone(first.poll())
        second = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.addCleanup(lambda: second.kill() if second.poll() is None else None)
        results = []
        for process in (first, second):
            output, error = process.communicate(timeout=15); self.assertEqual(process.returncode, 0, error.decode()); results.append(json.loads(output))
        self.assertEqual(results[0], results[1]); self.assertEqual(len(log.read_text().splitlines()), 2)
        self.assertFalse(any(self.cache.glob(".prepare-*")))
        codex.check_payload(Path(results[0]["stage"]), self.runtime)


if __name__ == "__main__": unittest.main()

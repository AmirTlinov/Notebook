"""Run the production AppKit quit path with an isolated saved-work fixture."""
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]


class RuntimeLifecycleTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="notebook-termination-")
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.root = Path(cls.temporary.name).resolve()
        bundle = cls.root / "LifecycleProbe.app"
        cls.executable = bundle / "Contents/MacOS/LifecycleProbe"
        cls.executable.parent.mkdir(parents=True)
        (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "local.notebook.runtime-lifecycle-test", "CFBundleExecutable": "LifecycleProbe",
            "CFBundlePackageType": "APPL", "LSUIElement": True}))
        compiled = subprocess.run(["/usr/bin/swiftc", "-parse-as-library", "-swift-version", "6",
            str(ROOT / "Applications/Mac/NotebookRuntime.swift"),
            str(ROOT / "Tests/NotebookRelease/runtime_lifecycle_fixture.swift"),
            "-o", str(cls.executable)], capture_output=True, text=True, timeout=60)
        if compiled.returncode:
            raise AssertionError(compiled.stdout + compiled.stderr)

    def quit_and_wait(self, mode, number=None):
        events = self.root / (mode + ".events")
        events.touch()
        environment = dict(os.environ)
        environment.pop("XCTestConfigurationFilePath", None)
        child = subprocess.Popen([str(self.executable), mode, str(events)], env=environment,
            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
        try:
            if number is not None:
                deadline = time.monotonic() + 5
                while "ready\n" not in events.read_text() and child.poll() is None and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertIn("ready\n", events.read_text())
                child.send_signal(number)
            _, error = child.communicate(timeout=5)
            self.assertEqual(child.returncode, 0, error)
            trace = events.read_text().splitlines()
            self.assertEqual(trace.count("saving"), 1, trace)
            self.assertEqual(trace.count("saved"), 1, trace)
            self.assertEqual(trace[-2:], ["saving", "saved"], trace)
        finally:
            if child.poll() is None:
                # Only this test-owned, data-free child can be forced to stop.
                child.kill()
            child.communicate(timeout=5)

    def test_sigterm_and_sigint_finish_saved_work_from_the_real_appkit_run_loop(self):
        self.quit_and_wait("sigterm", signal.SIGTERM)
        self.quit_and_wait("sigint", signal.SIGINT)

    def test_existing_owner_auto_quit_finishes_its_launch_task_before_saving(self):
        self.quit_and_wait("existing-owner")

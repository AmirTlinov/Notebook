#!/usr/bin/env python3
"""Broad distribution contracts; selected portable routes do not load these."""
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class DistributionContracts(unittest.TestCase):
    def test_app_icons_match_their_authoritative_svg(self):
        with tempfile.TemporaryDirectory(prefix="notebook-icon-proof-") as temporary:
            output = Path(temporary)
            subprocess.run([str(ROOT / "Applications/render-app-icon.sh"), str(output / "AppIcon.appiconset")], check=True)
            stored = ROOT / "Applications/Assets.xcassets/AppIcon.appiconset"
            expected = sorted(stored.glob("*.png"))
            self.assertTrue(expected)
            self.assertEqual({path.name for path in expected}, {path.name for path in (output / "AppIcon.appiconset").glob("*.png")})
            for path in expected:
                self.assertEqual(path.read_bytes(), (output / "AppIcon.appiconset" / path.name).read_bytes(), str(path))

    def test_webkit_resources_match_the_locked_distribution(self):
        modules = ROOT / "MCP/node_modules"
        resources = ROOT / "Applications/WebResources"
        pairs = (
            ("@xterm/xterm/lib/xterm.js", "xterm.js"),
            ("@xterm/xterm/css/xterm.css", "xterm.css"),
            ("@xterm/xterm/LICENSE", "Licenses/xterm-LICENSE"),
            ("@xterm/addon-fit/lib/addon-fit.js", "xterm-fit.js"),
            ("@xterm/addon-fit/LICENSE", "Licenses/xterm-fit-LICENSE"),
            ("marked/lib/marked.umd.js", "marked.umd.js"),
            ("marked/LICENSE", "Licenses/marked-LICENSE"),
            ("dompurify/dist/purify.min.js", "purify.min.js"),
            ("dompurify/LICENSE", "Licenses/dompurify-LICENSE"),
            ("dompurify/LICENSE-MPL", "Licenses/dompurify-LICENSE-MPL"),
            ("mathjax/a11y/assistive-mml.js", "a11y/assistive-mml.js"),
            ("mathjax/tex-svg-nofont.js", "tex-svg-nofont.js"),
            ("mathjax/LICENSE", "Licenses/mathjax-LICENSE"),
            ("@mathjax/mathjax-newcm-font/svg.js", "fonts/mathjax-newcm-font/svg.js"),
        )
        for source, bundled in pairs:
            self.assertEqual((modules / source).read_bytes(), (resources / bundled).read_bytes(), bundled)
        source = modules / "@mathjax/mathjax-newcm-font/svg"
        bundled = resources / "fonts/mathjax-newcm-font/svg"
        expected = {path.relative_to(source) for path in source.rglob("*") if path.is_file()}
        self.assertTrue(expected)
        self.assertEqual(expected, {path.relative_to(bundled) for path in bundled.rglob("*") if path.is_file()})
        for path in expected:
            self.assertEqual((source / path).read_bytes(), (bundled / path).read_bytes(), str(path))

    def test_pencilkit_eraser_preserves_the_measured_native_path(self):
        with tempfile.TemporaryDirectory(prefix="notebook-eraser-proof-") as temporary:
            app = Path(temporary) / "NotebookEraserProof.app"
            executable = app / "Contents/MacOS/NotebookEraserProof"
            executable.parent.mkdir(parents=True)
            subprocess.run(["xcrun", "swiftc", str(ROOT / "Tests/PencilKitIntegration/EraserPathProof.swift"),
                            "-o", str(executable)], check=True)
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": "com.amirtlinov.notebook.eraser-proof", "CFBundleExecutable": executable.name,
                "CFBundlePackageType": "APPL"}))
            subprocess.run([str(executable)], check=True)


if __name__ == "__main__":
    unittest.main(verbosity=2)

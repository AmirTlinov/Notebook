"""Fabricated Apple CLI data for release and in-place pair installation checks."""
import datetime
import json
from pathlib import Path
import plistlib
import subprocess

import notebook_release as release
import typesetter_fixture


def device_result():
    return {"identifier": release.DEVICE, "properties": {
        "hardware": {"udid": release.UDID, "reality": "physical", "platform": "iOS", "deviceType": "iPad", "productType": "iPad13,4"},
        "connection": {"state": "connected", "pairingState": "paired"},
        "state": {"bootState": "booted", "developerModeStatus": {"enabled": {"mode": 1}}},
        "software": {"osVersionNumber": {"stringValue": "27.0"}, "osBuildVersions": {"buildVersion": {"name": "24A5430a"}}}}}


def app_info():
    return {"CFBundleIdentifier": release.BUNDLE, "CFBundleDisplayName": release.DISPLAY_NAME,
        "CFBundlePackageType": "APPL", "CFBundleSupportedPlatforms": ["iPhoneOS"], "DTPlatformName": "iphoneos",
        "DTSDKName": "iphoneos27.0", "UIDeviceFamily": [2], "MinimumOSVersion": "27.0", "CFBundleExecutable": "Notebook",
        "CFBundleShortVersionString": "0.3.14", "CFBundleVersion": "17", "NotebookCloudContainer": release.CLOUD_CONTAINER}


def entitlement_values():
    return {"application-identifier": release.APP_ID, "com.apple.developer.team-identifier": release.TEAM,
            "keychain-access-groups": [release.APP_ID], "get-task-allow": True, **release.cloud_entitlements()}


class FakeCLI:
    """Writes the observed CLI JSON shapes and fake signed bundle into one temp root."""
    def __init__(self, source):
        self.source = source
        self.calls = []
        self.installed = False
        self.device = device_result()
        self.info = app_info()
        self.entitlements = entitlement_values()
        self.certificate = b"fixture Apple Development certificate"
        self.profile = {"TeamIdentifier": [release.TEAM], "ApplicationIdentifierPrefix": [release.TEAM],
            "ProvisionedDevices": [release.UDID], "Entitlements": {**entitlement_values(), "application-identifier": release.APP_ID},
            "ExpirationDate": datetime.datetime.now() + datetime.timedelta(days=10), "UUID": "fixture-profile",
            "DeveloperCertificates": [self.certificate]}
        self.canonical = {"bundleIdentifier": release.CANONICAL, "name": "Notebook", "version": "0.3.14", "bundleVersion": "17",
            "url": "file:///private/var/containers/Bundle/Application/CANONICAL/Notebook.app/"}
        self.preview = {"bundleIdentifier": release.BUNDLE, "name": release.DISPLAY_NAME, "version": "0.3.14", "bundleVersion": "17",
            "url": "file:///private/var/containers/Bundle/Application/PREVIEW/Notebook.app/"}
        self.existing_preview = False
        self.change_source = False
        self.fail_signature = False
        self.missing_installation_url = False
        self.platform = "IOS"
        self.architectures = "arm64"
        self.app = None

    def __call__(self, argv, cwd=None, stdout=None, stderr=None, timeout=None):
        self.calls.append(list(argv))
        output = b""
        error = b""
        exit_code = 0
        def after(flag): return argv[argv.index(flag) + 1]
        def emit(command, result):
            target = Path(after("--json-output"))
            target.write_text(json.dumps({"info": {"outcome": "success", "commandType": command}, "result": result}))
        if "prepare_notebook_typesetter.py" in str(argv):
            assert "--prepare" in argv and "--platform" in argv
        elif argv[0] == "/usr/bin/xcrun" and argv[1:5] == ["devicectl", "device", "info", "details"]:
            emit("devicectl.device.info.details", self.device)
        elif argv[0] == "/usr/bin/xcrun" and argv[1:5] == ["devicectl", "device", "info", "apps"]:
            bundle = after("--bundle-id")
            rows = [self.canonical] if bundle == release.CANONICAL else [self.preview] if (self.installed or self.existing_preview) else []
            emit("devicectl.device.info.apps", {"deviceIdentifier": release.DEVICE, "matchingBundleIdentifier": bundle, "apps": rows})
        elif argv[0] == "/usr/bin/xcrun" and argv[1:5] == ["devicectl", "device", "install", "app"]:
            self.installed = True
            self.preview.update(version=self.info["CFBundleShortVersionString"], bundleVersion=self.info["CFBundleVersion"])
            application = {"bundleID": release.BUNDLE, "installationURL": self.preview["url"]}
            if self.missing_installation_url:
                application.pop("installationURL")
                application["bundleURL"] = self.preview["url"]
            emit("devicectl.device.install.app", {"installedApplications": [application]})
        elif argv[0] == "/usr/bin/xcrun" and argv[1] == "xcodebuild" and argv[-1] == "build":
            self.app = Path(after("-derivedDataPath")) / ("Build/Products/" + after("-configuration") + "-iphoneos/Notebook.app")
            self.app.mkdir(parents=True)
            (self.app / "Info.plist").write_bytes(plistlib.dumps(self.info))
            typesetter_fixture.stage(self.app / "NotebookTypesetter")
            (self.app / "Notebook").write_bytes(b"fixture arm64 iOS binary")
            (self.app / "Notebook").chmod(0o755)
            (self.app / "embedded.mobileprovision").write_bytes(b"fixture signed profile")
            if self.change_source:
                (self.source / "Sources/NotebookCore/Test.swift").write_text("let changed = true\n")
        elif argv[0] == "/usr/bin/codesign":
            if "--verify" in argv:
                exit_code = 1 if self.fail_signature else 0
            elif "--entitlements" in argv:
                output = plistlib.dumps(self.entitlements)
            elif any(value.startswith("--extract-certificates=") for value in argv):
                prefix = next(value.split("=", 1)[1] for value in argv if value.startswith("--extract-certificates="))
                Path(prefix + "0").write_bytes(self.certificate)
            else:
                error = ("Identifier=" + release.BUNDLE + "\nTeamIdentifier=" + release.TEAM + "\nAuthority=Apple Development: Fixture\nCDHash=" + "a" * 40 + "\n").encode()
        elif argv[0] == "/usr/bin/security":
            output = plistlib.dumps(self.profile)
        elif argv[0] == "/usr/bin/xcrun" and argv[1] == "lipo":
            output = (self.architectures + "\n").encode()
        elif argv[0] == "/usr/bin/xcrun" and argv[1] == "vtool":
            output = ("Load command 1\n platform " + self.platform + "\n minos 27.0\n").encode()
        elif argv[0] == "/usr/bin/xcrun" and argv[1] == "dwarfdump":
            output = b"UUID: 11111111-2222-3333-4444-555555555555 (arm64) fixture\n"
        elif argv[0] == "/fixture/xcodegen" or argv[:3] == ["/usr/bin/xcrun", "xcodebuild", "-version"]:
            output = b"fixture tool version\n"
        else:
            raise AssertionError("Unexpected CLI command: " + repr(argv))
        stdout.write(output)
        stderr.write(error)
        return subprocess.CompletedProcess(argv, exit_code)

    @property
    def install_calls(self):
        return [call for call in self.calls if call[1:5] == ["devicectl", "device", "install", "app"]]

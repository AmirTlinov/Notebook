#!/usr/bin/env python3
"""Build and record the same camera fixture against an immutable baseline/current source."""
import argparse
import difflib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import sys
import tarfile
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'Applications'))
import notebook_release as release
from notebook_acceptance import SimulatorRecording
from lossless import SimulatorPixelSamples

BUNDLE = 'com.amirtlinov.notebook.cameraaudit'
TARGET = 'NotebookCameraAcceptanceUITests'
SCHEME = 'NotebookCameraAudit'
HERE = Path(__file__).resolve().parent
INJECTION = '''    #if targetEnvironment(simulator)
    if Bundle.main.bundleIdentifier == NotebookCameraAcceptanceFixture.bundleID {
      _launch = State(initialValue: NotebookCameraAcceptanceFixture.makeLaunch())
      return
    }
    #endif
'''
TRACE_PATCHES = [
    ('iPad/TwoFingerWorkspaceGestureRecognizer.swift',
        '  private func beginTrackingPair() {\n',
        '    NotebookCameraAcceptanceFixture.recordContacts(self)\n'),
    ('iPad/WorkspaceGestureLayer.swift',
        '    private func updateCamera(_ recognizer: TwoFingerPaperGestureRecognizer) {\n',
        '      NotebookCameraAcceptanceFixture.recordContacts(recognizer)\n'),
    ('iPad/SpatialWorkspaceView.swift',
        '  private func handleBoardMagnification(_ phase: WorkspaceMagnificationPhase) {\n',
        '    let auditBefore = model.presence\n'
        '    defer { NotebookCameraAcceptanceFixture.recordCamera(phase, before: auditBefore, after: model.presence) }\n'),
    ('iPad/SpatialWorkspaceView.swift',
        '  private func updateBoardPan(\n    _ translation: CGPoint,\n    viewport: SpatialPoint\n  ) {\n',
        '    let auditBefore = model.presence\n'
        '    defer { NotebookCameraAcceptanceFixture.recordPan(translation, before: auditBefore, after: model.presence) }\n'),
]


def execute(argv, *, cwd=ROOT, log=None, timeout=1800):
    argv = list(map(str, argv))
    if log:
        with Path(log).open('wb') as stream:
            completed = subprocess.run(argv, cwd=cwd, stdout=stream, stderr=subprocess.STDOUT, timeout=timeout)
        release.require(completed.returncode == 0, 'Command failed; see ' + str(log))
        return b''
    return subprocess.check_output(argv, cwd=cwd, timeout=timeout)


def write(path, value):
    release.write_json(path, value)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def build(args):
    evidence = args.evidence.resolve()
    release.require(not evidence.exists(), 'Use a fresh evidence directory')
    evidence.mkdir(parents=True, mode=0o700)
    snapshot = evidence / 'source'
    inventory = json.loads(execute(['xcrun', 'simctl', 'list', 'devices', 'available', '--json']))
    devices = [v for values in inventory['devices'].values() for v in values if v['udid'] == args.simulator]
    release.require(len(devices) == 1 and '.iPad-' in devices[0].get('deviceTypeIdentifier', ''), 'An exact iPad Simulator is required')
    if args.revision == 'working-tree':
        source = release.source_inputs(ROOT)
        release.copy_source(ROOT, snapshot, source)
        revision = execute(['git', 'rev-parse', 'HEAD']).decode().strip()
    else:
        revision = execute(['git', 'rev-parse', '--verify', '--end-of-options', args.revision + '^{commit}']).decode().strip()
        archive = evidence / 'source.tar'
        with archive.open('wb') as stream:
            subprocess.run(['git', 'archive', '--format=tar', revision], cwd=ROOT, stdout=stream, check=True)
        snapshot.mkdir()
        with tarfile.open(archive) as bundle:
            bundle.extractall(snapshot, filter='data')
        source = release.source_inputs(snapshot)
    write(evidence / 'production-source.json', source)
    fixture = (HERE / 'NotebookCameraAcceptanceFixture.swift').read_bytes()
    ui = (ROOT / 'Applications/AcceptanceUITests/NotebookCameraAcceptanceUITests.swift').read_bytes()
    (snapshot / 'Applications/iPad/NotebookCameraAcceptanceFixture.swift').write_bytes(fixture)
    ui_path = snapshot / 'Applications/CameraAuditUITests/NotebookCameraAcceptanceUITests.swift'
    ui_path.parent.mkdir(parents=True)
    ui_path.write_bytes(ui)
    app = snapshot / 'Applications/iPad/NotebookApp.swift'
    original = app.read_text()
    release.require(original.count('  init() {\n') == 1, 'NotebookApp bootstrap is not the reviewed injection point')
    patched = original.replace('  init() {\n', '  init() {\n' + INJECTION, 1)
    release.require(patched.count('      .environment(model)') == 1, 'Camera witness mount owner changed')
    patched = patched.replace('      .environment(model)',
        '      .environment(model)\n      .background { NotebookCameraWitnessMount().frame(width: 0, height: 0).allowsHitTesting(false) }', 1)
    app.write_text(patched)
    patch = ''.join(difflib.unified_diff(original.splitlines(True), patched.splitlines(True),
                                       fromfile='NotebookApp.swift', tofile='NotebookApp.swift')).encode()
    (evidence / 'bootstrap.patch').write_bytes(patch)
    trace_patch = b''
    for relative, anchor, observation in TRACE_PATCHES:
        path = snapshot / 'Applications' / relative
        before = path.read_text()
        release.require(before.count(anchor) == 1, 'Camera trace owner changed: ' + relative)
        after = before.replace(anchor, anchor + observation, 1)
        path.write_text(after)
        trace_patch += ''.join(difflib.unified_diff(before.splitlines(True), after.splitlines(True),
                              fromfile=relative, tofile=relative)).encode()
    (evidence / 'input-trace.patch').write_bytes(trace_patch)
    spec = json.loads(execute(['xcodegen', 'dump', '--type', 'json', '--spec', 'project.yml'], cwd=snapshot / 'Applications'))
    target = spec['targets']['Notebook']
    target['settings']['base']['PRODUCT_BUNDLE_IDENTIFIER'] = BUNDLE
    target['info']['properties']['CFBundleDisplayName'] = 'Notebook Camera Audit'
    target.pop('scheme', None)
    spec['targets'][TARGET] = {
        'type': 'bundle.ui-testing', 'platform': 'iOS', 'deploymentTarget': '27.0',
        'sources': [{'path': 'CameraAuditUITests'}], 'dependencies': [{'target': 'Notebook'}],
        'settings': {'base': {'PRODUCT_BUNDLE_IDENTIFIER': BUNDLE + '.uitests',
                              'GENERATE_INFOPLIST_FILE': True, 'TEST_TARGET_NAME': 'Notebook',
                              'TARGETED_DEVICE_FAMILY': 2, 'SWIFT_ACTIVE_COMPILATION_CONDITIONS': 'NOTEBOOK_CAMERA_ACCEPTANCE'}}}
    spec.setdefault('schemes', {})[SCHEME] = {
        'build': {'targets': {'Notebook': 'all'}},
        'test': {'gatherCoverageData': False, 'targets': [TARGET]}}
    write(snapshot / 'Applications/camera-audit-project.json', spec)
    execute(['xcodegen', 'generate', '--spec', 'camera-audit-project.json'], cwd=snapshot / 'Applications', log=evidence / 'project.log')
    prepared = release.source_inputs(snapshot)
    write(evidence / 'audit-source.json', prepared)
    execute(['xcrun', 'xcodebuild', '-quiet', '-project', snapshot / 'Applications/Notebook.xcodeproj',
             '-scheme', SCHEME, '-configuration', 'Release', '-destination', 'platform=iOS Simulator,id=' + args.simulator,
             '-derivedDataPath', evidence / 'derived', '-parallel-testing-enabled', 'NO', 'CODE_SIGNING_ALLOWED=NO',
             'ARCHS=arm64', 'ONLY_ACTIVE_ARCH=YES', 'build-for-testing'], log=evidence / 'build.log')
    release.require(prepared == release.source_inputs(snapshot), 'Audit source changed during build')
    application = evidence / 'derived/Build/Products/Release-iphonesimulator/Notebook.app'
    info = plistlib.loads((application / 'Info.plist').read_bytes())
    release.require(info['CFBundleIdentifier'] == BUNDLE, 'Refusing a production bundle')
    result = {'format': 1, 'revision': revision, 'workingTree': args.revision == 'working-tree', 'supportsTemporalWitness': True,
              'productionSourceSHA256': source['sha256'], 'auditSourceSHA256': prepared['sha256'],
              'harnessSHA256': sha(fixture + ui + INJECTION.encode()), 'bootstrapPatchSHA256': sha(patch),
              'inputTracePatchSHA256': sha(trace_patch),
              'inputTraceRecipeSHA256': sha(json.dumps([(path, observation) for path, _, observation in TRACE_PATCHES],
                ensure_ascii=False, separators=(',', ':')).encode()),
              'fixtureSHA256': sha(fixture), 'uiSHA256': sha(ui), 'app': str(application),
              'simulator': devices[0], 'xcode': execute(['xcodebuild', '-version']).decode().strip()}
    write(evidence / 'build.json', result)
    print(json.dumps(result, ensure_ascii=False))


def record(args):
    build_dir = args.build.resolve()
    built = json.loads((build_dir / 'build.json').read_text())
    release.require(not args.temporal_witness or (args.lossless and built.get('supportsTemporalWitness')),
                    'Temporal witness requires a newly built witness-capable fixture and original PNG capture')
    app = Path(built['app'])
    release.require(plistlib.loads((app / 'Info.plist').read_bytes())['CFBundleIdentifier'] == BUNDLE, 'Refusing a production bundle')
    device = built['simulator']['udid']
    execute(['xcrun', 'simctl', 'install', device, app])
    container = execute(['xcrun', 'simctl', 'get_app_container', device, BUNDLE, 'data']).decode().strip()
    release.require('/CoreSimulator/Devices/' in container, 'Only a Simulator container is permitted')
    run_id = str(uuid.uuid4())
    evidence = build_dir / ('camera-' + args.variant + '-' + run_id)
    evidence.mkdir(mode=0o700)
    products = build_dir / 'derived/Build/Products'
    originals = [p for p in products.glob('*.xctestrun') if not p.name.startswith('camera-')]
    release.require(len(originals) == 1, 'Expected one original test specification')
    spec = plistlib.loads(originals[0].read_bytes())
    targets = [t for c in spec.get('TestConfigurations', []) for t in c.get('TestTargets', [])]
    if not targets:
        targets = [t for k, t in spec.items() if k != '__xctestrun_metadata__' and isinstance(t, dict)]
    chosen = [t for t in targets if t.get('BlueprintName') == TARGET or t.get('TestBundlePath', '').endswith(TARGET + '.xctest')]
    release.require(len(chosen) == 1, 'Expected one isolated camera UI target')
    env = {'NOTEBOOK_CAMERA_AUDIT_RUN': run_id, 'NOTEBOOK_CAMERA_AUDIT_VARIANT': args.variant}
    if args.temporal_witness:
        env['NOTEBOOK_CAMERA_TEMPORAL_WITNESS'] = '1'
    chosen[0].setdefault('EnvironmentVariables', {}).update(env)
    chosen[0].setdefault('UITargetAppEnvironmentVariables', {}).update(env)
    configured = products / ('camera-' + run_id + '.xctestrun')
    configured.write_bytes(plistlib.dumps(spec))
    recording = SimulatorRecording(device, evidence)
    pixels = SimulatorPixelSamples(device, evidence / 'lossless') if args.lossless else None
    started = time.time()
    failure = None
    summary = {}
    try:
        recording.start()
        if pixels:
            pixels.start()
        execute(['xcrun', 'xcodebuild', '-quiet', '-xctestrun', configured,
                 '-destination', 'platform=iOS Simulator,id=' + device, '-parallel-testing-enabled', 'NO',
                 '-resultBundlePath', evidence / 'result.xcresult', '-collect-test-diagnostics', 'never',
                 '-only-testing:' + TARGET + '/NotebookCameraAcceptanceUITests/testCameraKeepsVectorAndLiveControlAttachedToNativeInk',
                 'test-without-building'], log=evidence / 'test.log', timeout=600)
    except Exception as error:
        failure = str(error)
    finally:
        if pixels:
            try:
                pixels.stop()
            except Exception as error:
                failure = failure or str(error)
        recording.stop()
        # test-without-building may replace the audit app's container while
        # installing. Resolve the actual post-run container, never the preflight
        # install's now-orphaned path, and retain the observed input trace.
        container = execute(['xcrun', 'simctl', 'get_app_container', device, BUNDLE, 'data']).decode().strip()
        release.require('/CoreSimulator/Devices/' in container, 'Only a Simulator container is permitted')
        trace = Path(container) / 'tmp/NotebookCameraAudit' / run_id.upper() / 'camera-input-trace.json'
        if trace.exists():
            (evidence / 'camera-input-trace.json').write_bytes(trace.read_bytes())
        write(evidence / 'recording.json', {**built, 'runID': run_id, 'variant': args.variant,
              'startedAt': started, 'endedAt': time.time(), 'failure': failure,
              'evidenceKind': 'Simulator display video, actual XCUITest drag/pinch',
              'losslessDisplaySamples': 'lossless/manifest.json' if pixels else None,
              'temporalWitness': {'enabled': args.temporal_witness, 'format': 1,
                                  'clock': 'mach_absolute_ns', 'meaning': 'Monotonic visual cohort, not a GPU frame'},
              'container': container, 'input': 'native finger; seeded ink is an immutable visual reference'})
        result = evidence / 'result.xcresult'
        if (result / 'Info.plist').exists():
            summary = json.loads(execute(['xcrun', 'xcresulttool', 'get', 'test-results', 'summary', '--path', result, '--compact']))
            write(evidence / 'summary.json', summary)
            execute(['xcrun', 'xcresulttool', 'export', 'attachments', '--path', result,
                     '--output-path', evidence / 'attachments'], log=evidence / 'attachments.log')
    release.require(failure is None, failure or '')
    release.require(summary.get('passedTests') == 1 and summary.get('failedTests') == 0 and summary.get('skippedTests') == 0,
                    'The real camera gesture scenario did not complete')
    print(evidence)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    p = sub.add_parser('build'); p.add_argument('--revision', required=True, help='Exact commit/ref or working-tree')
    p.add_argument('--simulator', required=True); p.add_argument('--evidence', required=True, type=Path)
    p = sub.add_parser('record'); p.add_argument('--build', required=True, type=Path)
    p.add_argument('--variant', required=True, choices=['static', 'live'])
    p.add_argument('--lossless', action='store_true', help='Also retain bounded original Simulator PNG samples during gestures')
    p.add_argument('--temporal-witness', action='store_true', help='Publish a passive visual cohort strip for bounded capture-time alignment')
    args = parser.parse_args()
    with (Path(tempfile.gettempdir()) / 'notebook-verification.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        release.require(subprocess.run(['pgrep', '-x', 'xcodebuild'], capture_output=True).returncode != 0,
                        'The native runner is already occupied')
        {'build': build, 'record': record}[args.command](args)


if __name__ == '__main__':
    main()

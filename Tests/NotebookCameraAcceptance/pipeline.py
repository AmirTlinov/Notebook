#!/usr/bin/env python3
"""Prepare an immutable camera experiment; execute one explicitly scheduled phase."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT/'Applications'))
import notebook_release as release


def prepare(args):
    directory = args.evidence.resolve()
    release.require(not directory.exists(), 'A camera pipeline needs a new evidence directory')
    directory.mkdir(parents=True, mode=0o700)
    source = release.source_inputs(ROOT)
    snapshot = directory/'source'
    release.copy_source(ROOT, snapshot, source)
    release.write_json(directory/'production-source.json', source)
    developer = args.developer_dir or os.environ.get('DEVELOPER_DIR') or subprocess.check_output(
        ['xcode-select', '-p'], text=True).strip()
    release.require(Path(developer).is_dir(), 'The selected Xcode Developer directory is unavailable')
    base = [str(args.python.resolve()), str(snapshot/'Tests/NotebookCameraAcceptance/run.py')]
    build = directory/'build'
    plan = {'format': 1, 'sourceSHA256': source['sha256'], 'source': str(snapshot), 'build': str(build),
        'revision': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
        'python': str(args.python.resolve()), 'simulator': args.simulator,
        'developerDir': str(Path(developer).resolve()),
        'commands': {'build': base+['build', '--revision', 'working-tree', '--simulator', args.simulator, '--evidence', str(build)],
                     'static': base+['record', '--build', str(build), '--variant', 'static', '--lossless'],
                     'live': base+['record', '--build', str(build), '--variant', 'live', '--lossless']},
        'measurement': ['measure_lossless.py', 'measure_joint.py'],
        'scope': 'Separate Simulator fixture, ordinary production rendering/input, no private paired or physical install',
        'state': 'prepared_not_run'}
    if args.temporal_witness:
        for phase in ('static', 'live'):
            plan['commands'][phase].append('--temporal-witness')
    plan['temporalWitness'] = args.temporal_witness
    release.write_json(directory/'pipeline.json', plan)
    print(json.dumps(plan, indent=2))


def run(args):
    directory = args.prepared.resolve()
    plan = release.read_json(directory/'pipeline.json')
    source = Path(plan['source'])
    release.require(release.source_inputs(source) == release.read_json(directory/'production-source.json'),
                    'The prepared source changed; create another immutable experiment')
    env = dict(os.environ)
    env['NOTEBOOK_SIMULATOR_ID'] = plan['simulator']
    env['DEVELOPER_DIR'] = plan['developerDir']
    if args.phase in plan['commands']:
        command = plan['commands'][args.phase]
        with (directory/(args.phase+'-driver.log')).open('xb') as log:
            subprocess.run(command, cwd=source, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
    else:
        variant = args.phase.removeprefix('measure-')
        runs = list(Path(plan['build']).glob('camera-'+variant+'-*'))
        release.require(len(runs) == 1, 'Exactly one completed camera run is required for this phase')
        for script in plan['measurement']:
            output = runs[0]/script.removesuffix('.py')
            command = [plan['python'], str(source/'Tests/NotebookCameraAcceptance'/script), '--run', str(runs[0]), '--output', str(output)]
            with (directory/(variant+'-'+script+'.log')).open('xb') as log:
                result = subprocess.run(command, cwd=source, env=env, stdout=log, stderr=subprocess.STDOUT)
            # A measured FAIL is an experiment result. Decoder or integrity
            # errors have no summary and must stop rather than look measured.
            release.require((output/'summary.json').exists(), 'Measurement did not complete: '+script)
            release.require(result.returncode in (0, 1), 'Measurement process failed: '+script)
    print(str(directory))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    p = commands.add_parser('prepare')
    p.add_argument('--evidence', required=True, type=Path)
    p.add_argument('--simulator', required=True)
    p.add_argument('--python', required=True, type=Path)
    p.add_argument('--developer-dir')
    p.add_argument('--temporal-witness', action='store_true')
    p = commands.add_parser('run')
    p.add_argument('--prepared', required=True, type=Path)
    p.add_argument('--phase', required=True, choices=['build', 'static', 'live', 'measure-static', 'measure-live'])
    args = parser.parse_args()
    prepare(args) if args.command == 'prepare' else run(args)

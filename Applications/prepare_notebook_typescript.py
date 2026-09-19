#!/usr/bin/env python3
"""Pinned build input. No package manager, paths or network reach the runtime.

The upstream CLI realpaths its executable and requires sibling lib.d.ts even
with noLib. Apple requires real data in Resources, not Helpers. One exact,
bundle-internal relative symlink provides discovery; it grants no extra path.
"""
import argparse, hashlib, json, os, shutil
from pathlib import Path
from notebook_macho import macho

ROOT = Path(__file__).resolve().parents[1]
LOCK = ROOT / 'Sources/NotebookMarkupService/TypeScriptResources.lock.json'
SDK = ROOT / 'Sources/NotebookScriptHost/Resources/notebook-sdk.d.ts'
PACKAGE = ROOT / 'MCP/node_modules/@typescript/typescript-darwin-arm64'
BINARY = 'Helpers/notebook-typescript'
RESOURCES = 'Resources/NotebookTypeScript'
DISCOVERY = 'Helpers/lib.d.ts'
DISCOVERY_TARGET = '../Resources/NotebookTypeScript/lib.d.ts'

def sha(data): return hashlib.sha256(data).hexdigest()
def pin(path):
    if path.is_symlink() or not path.is_file(): raise RuntimeError('Expected a regular TypeScript build input: '+str(path))
    data=path.read_bytes();return {'bytes':len(data),'sha256':sha(data)}
def identity(lock):
    return {'format':2,'compilerVersion':lock['version'],'sdkVersion':pin(SDK)['sha256'],
            'sourceLockSHA256':sha(LOCK.read_bytes())}
def outputs(lock):
    paths={BINARY,DISCOVERY,RESOURCES,RESOURCES+'/manifest.json',RESOURCES+'/notebook-sdk.d.ts'}
    paths.update(RESOURCES+'/'+name for name in lock['resources'])
    for name in tuple(paths):
        paths.update(str(p) for p in Path(name).parents if str(p) not in ('.','Resources'))
    return ''.join('$(TARGET_BUILD_DIR)/$(CONTENTS_FOLDER_PATH)/'+p+'\n' for p in sorted(paths))
def check(stage, *, signed=False):
    stage=Path(stage);lock=json.loads(LOCK.read_text());expected=identity(lock)
    if stage.is_symlink() or any((stage/name).is_symlink() for name in ('Helpers','Resources')):
        raise RuntimeError('TypeScript stage must not traverse symlink directories')
    resources=stage/RESOURCES
    if resources.is_symlink():raise RuntimeError('TypeScript resources must not be a symlink')
    manifest=json.loads((resources/'manifest.json').read_text())
    if any(manifest.get(k)!=v for k,v in expected.items()):raise RuntimeError('TypeScript compiler/SDK identity changed')
    pins={**lock['resources'],'notebook-sdk.d.ts':pin(SDK)}
    members=list(resources.rglob('*'))
    if any(p.is_symlink() for p in members) or {p.relative_to(resources).as_posix() for p in members if p.is_file()} != set(pins)|{'manifest.json'}:
        raise RuntimeError('TypeScript bundle has missing or unexpected resources')
    if any(pin(resources/name)!=value for name,value in pins.items()):raise RuntimeError('TypeScript resource hash mismatch')
    if manifest.get('libraries')!=sorted(name for name in pins if (name.startswith('lib.es') or name.startswith('lib.decorators'))):raise RuntimeError('Standard declarations changed')
    discovery=stage/DISCOVERY
    if not discovery.is_symlink() or os.readlink(discovery)!=DISCOVERY_TARGET or discovery.resolve()!=(resources/'lib.d.ts').resolve():
        raise RuntimeError('TypeScript discovery link must target its own sealed resource')
    binary=stage/BINARY
    if binary.is_symlink() or not os.access(binary,os.X_OK):raise RuntimeError('TypeScript compiler is not executable')
    if macho(binary.read_bytes(),minimum_os='12.0')!=lock['compiler']['macho']:raise RuntimeError('Pinned TypeScript executable changed')
    if not signed and pin(binary)!=lock['compiler']['file']:raise RuntimeError('Unsigned TypeScript input changed')
    return manifest

def prepare(stage):
    lock=json.loads(LOCK.read_text())
    if json.loads((PACKAGE/'package.json').read_text())['version']!=lock['version']:raise RuntimeError('Wrong installed TypeScript build dependency')
    if pin(PACKAGE/'lib/tsc')!=lock['compiler']['file']:raise RuntimeError('TypeScript executable pin mismatch')
    expected=identity(lock)
    if stage.exists():check(stage);return
    stage.mkdir(parents=True)
    try:
        (stage/BINARY).parent.mkdir(parents=True);shutil.copyfile(PACKAGE/'lib/tsc',stage/BINARY);(stage/BINARY).chmod(0o755)
        target=stage/RESOURCES;target.mkdir(parents=True,exist_ok=True)
        for name,value in lock['resources'].items():
            source=PACKAGE/('lib/'+name if name.startswith('lib.') else name)
            if pin(source)!=value:raise RuntimeError('TypeScript dependency pin mismatch: '+name)
            shutil.copyfile(source,target/name)
        (stage/DISCOVERY).symlink_to(DISCOVERY_TARGET)
        shutil.copyfile(SDK,target/'notebook-sdk.d.ts')
        expected['libraries']=sorted(name for name in lock['resources'] if (name.startswith('lib.es') or name.startswith('lib.decorators')))
        (target/'manifest.json').write_text(json.dumps(expected,sort_keys=True,indent=2)+'\n')
        check(stage)
    except BaseException:
        shutil.rmtree(stage);raise

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--prepare',action='store_true');parser.add_argument('--check',action='store_true')
    parser.add_argument('--stage',type=Path);parser.add_argument('--stage-root',type=Path,default=ROOT/'.build/notebook-typescript-runtime')
    parser.add_argument('--output-list',type=Path);args=parser.parse_args();lock=json.loads(LOCK.read_text())
    if args.output_list and args.output_list.read_text()!=outputs(lock):raise RuntimeError('TypeScript Xcode inventory is stale')
    key=sha(json.dumps(identity(lock),sort_keys=True).encode())
    stage=(args.stage or args.stage_root/key).resolve()
    if args.prepare:prepare(stage)
    manifest=check(stage)
    print(json.dumps({'status':'ready','stage':str(stage),**manifest}))

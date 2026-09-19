#!/usr/bin/env python3
"""Pinned wasm2c kernels + bounded host runtime. --check never builds/downloads."""
from pathlib import Path
import argparse, concurrent.futures, gzip, hashlib, json, os, shutil, subprocess
from prepare_notebook_distribution import obtain, create_distribution, verify
ROOT=Path(__file__).resolve().parent.parent
SOURCE=ROOT/'Sources/NotebookTypesetterRuntime'
LOCK=json.loads((SOURCE/'Runtime.lock.json').read_text())
def digest(path):
 h=hashlib.sha256()
 with path.open('rb') as f:
  for data in iter(lambda:f.read(1024*1024),b''):h.update(data)
 return h.hexdigest()
def run(args,**kwargs): subprocess.run(list(map(str,args)),check=True,**kwargs)
def input_digest():
 for name,expected in LOCK['imageSource']['files'].items():
  if digest(ROOT/LOCK['imageSource']['directory']/name)!=expected:raise RuntimeError('Image kernel source differs from its pinned build: '+name)
 h=hashlib.sha256()
 files=[Path(__file__),ROOT/'Applications/prepare_notebook_distribution.py',ROOT/'Sources/NotebookMarkupService/Resources/notebook-markup.js']
 files+=sorted(p for p in SOURCE.rglob('*') if p.is_file() and 'target' not in p.parts)
 for p in files: h.update(str(p.relative_to(ROOT)).encode());h.update(bytes.fromhex(digest(p)))
 return h.hexdigest()
def check(stage,platform,identity):
 manifest=json.loads((stage/'manifest.json').read_text())
 if manifest['inputSHA256']!=identity:raise RuntimeError('Typesetter inputs changed; prepare exact runtime before freezing source')
 for path,value in manifest['files'].items():
  if path.startswith(('Resources/',platform+'/')):
   p=stage/path
   if not p.is_file() or p.is_symlink() or p.stat().st_size!=value['bytes'] or digest(p)!=value['sha256']:raise RuntimeError(f'Typesetter resource differs: {p}')
 if platform not in manifest.get('platforms',[]) or platform+'/libnotebook_typesetter_runtime.a' not in manifest['files']:raise RuntimeError('Platform was not prepared')
def check_bundle(resources):
 manifest=json.loads((resources/'manifest.json').read_text())
 if manifest.get('format')!=1 or manifest.get('inputSHA256')!=input_digest():raise RuntimeError('Typesetter bundle source identity differs')
 expected=manifest['files']
 actual={str(p.relative_to(resources)) for p in resources.rglob('*') if p.is_file()}
 if actual!=set(expected)|{'manifest.json'}:raise RuntimeError('Typesetter bundle inventory differs')
 for name,value in expected.items():
  p=resources/name
  if Path(name).is_absolute() or '..' in Path(name).parts or p.is_symlink() or p.stat().st_size!=value['bytes'] or digest(p)!=value['sha256']:raise RuntimeError('Typesetter bundle resource differs: '+name)
 if expected.get('texlive.zip')!=LOCK['distribution']:raise RuntimeError('Typesetter distribution pin differs')
 for name in ['latex.fmt','fonts.tsv']:
  if expected.get(name)!={k:LOCK['kernels'][name][k] for k in ['bytes','sha256']}:raise RuntimeError('Typesetter kernel data differs: '+name)
 return manifest
def prepare(stage,platform,identity,distribution):
 try: check(stage,platform,identity); return
 except (OSError,KeyError,RuntimeError): pass
 previous=json.loads((stage/'manifest.json').read_text()) if (stage/'manifest.json').exists() else {}
 verified=previous.get('platforms',[]) if previous.get('inputSHA256')==identity else []
 build=ROOT/'.build/typesetter-build'; build.mkdir(parents=True,exist_ok=True)
 for name,value in LOCK['kernels'].items():
  packed=SOURCE/'kernels'/(name+'.gz')
  if digest(packed)!=value['packedSHA256']:raise RuntimeError('Packed kernel differs: '+name)
  data=gzip.decompress(packed.read_bytes())
  if len(data)!=value['bytes'] or hashlib.sha256(data).hexdigest()!=value['sha256']:raise RuntimeError('Kernel differs: '+name)
  (build/name).write_bytes(data)
 wabt=build/'wabt'
 if not wabt.exists(): run(['git','clone','--filter=blob:none','--no-checkout',LOCK['wabt']['url'],wabt]); run(['git','-C',wabt,'checkout','--detach',LOCK['wabt']['revision']])
 if subprocess.check_output(['git','-C',wabt,'rev-parse','HEAD'],text=True).strip()!=LOCK['wabt']['revision']:raise RuntimeError('Wrong WABT revision')
 if subprocess.check_output(['git','-C',wabt,'status','--porcelain'],text=True).strip():raise RuntimeError('WABT source has local changes')
 run(['cmake','-S',wabt,'-B',build/'wabt-build','-DBUILD_TESTS=OFF','-DBUILD_TOOLS=ON','-DCMAKE_BUILD_TYPE=Release'])
 run(['cmake','--build',build/'wabt-build','--target','wasm2c','-j','6'])
 run(['python3','-B',SOURCE/'build/generate.py',build])
 out=build/'aot';rt=wabt/'wasm2c';native=SOURCE/'native';objects=build/('native-'+platform);objects.mkdir(exist_ok=True)
 sdk=subprocess.check_output(['xcrun','--sdk',platform,'--show-sdk-path'],text=True).strip()
 triple={'iphoneos':'arm64-apple-ios27.0','iphonesimulator':'arm64-apple-ios27.0-simulator','macosx':'arm64-apple-macos27.0'}[platform]
 files=sorted(out.glob('*_*.c'))+[out/'wasi.c',rt/'wasm-rt-impl.c',rt/'wasm-rt-exceptions-impl.c',native/'supervisor.c']
 def compile(p):
  obj=objects/(p.stem+'.o')
  with (objects/(p.stem+'.log')).open('w') as log:
   run(['clang','-target',triple,'-isysroot',sdk,'-c','-O2','-fno-optimize-sibling-calls','-frounding-math','-DWASM_RT_MEMCHECK_BOUNDS_CHECK=1','-DWASM_RT_USE_MMAP=0','-DWASM_RT_MAX_CALL_STACK_DEPTH=2048','-I'+str(rt),'-I'+str(native),'-I'+str(out),p,'-o',obj],stdout=log,stderr=subprocess.STDOUT)
  return obj
 with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool: compiled=list(pool.map(compile,files))
 run(['ar','rcs',objects/'libnotebook_engine.a',*compiled])
 target={'iphoneos':'aarch64-apple-ios','iphonesimulator':'aarch64-apple-ios-sim','macosx':'aarch64-apple-darwin'}[platform]
 env=dict(os.environ,NOTEBOOK_TYPESETTER_NATIVE=str(objects),CARGO_TARGET_DIR=str(build/'rust'))
 run(['cargo','+'+LOCK['rustToolchain'],'build','--release','--locked','--lib','--target',target,'--manifest-path',SOURCE/'Cargo.toml'],env=env)
 dest=stage/platform;dest.mkdir(parents=True,exist_ok=True)
 shutil.copy2(build/'rust'/target/'release/libnotebook_typesetter_runtime.a',dest/'libnotebook_typesetter_runtime.a')
 resources=stage/'Resources';resources.mkdir(exist_ok=True)
 expected=LOCK['distribution']
 if not distribution.exists():
  cache=ROOT/'.build/notebook-typesetter-downloads';cache.mkdir(parents=True,exist_ok=True)
  distribution=cache/'texlive.zip'
  if not distribution.exists():
   archive=obtain(LOCK['distributionSource'],cache)
   partial=distribution.with_suffix('.pending')
   try:
    create_distribution(archive,partial,LOCK['distributionSource']);verify(partial,expected);partial.replace(distribution)
   finally:partial.unlink(missing_ok=True)
 if distribution.stat().st_size!=expected['bytes'] or digest(distribution)!=expected['sha256']:raise RuntimeError('Wrong TeX distribution')
 targetzip=resources/'texlive.zip'
 if not targetzip.exists() or digest(targetzip)!=expected['sha256']:shutil.copy2(distribution,targetzip)
 for name in ['latex.fmt','fonts.tsv']:shutil.copy2(build/name,resources/name)
 shutil.copy2(ROOT/'Sources/NotebookMarkupService/Resources/notebook-markup.js',resources/'notebook-markup.js')
 shutil.copytree(SOURCE/'licenses',resources/'licenses',dirs_exist_ok=True)
 (resources/'revision.txt').write_text(identity+'\n')
 platforms=sorted(set(verified+[platform]))
 manifest={'format':1,'inputSHA256':identity,'platforms':platforms,'files':{}}
 for p in sorted(stage.rglob('*')):
  if p.is_file() and str(p.relative_to(stage)).split('/')[0] in ['Resources']+platforms:manifest['files'][str(p.relative_to(stage))]={'bytes':p.stat().st_size,'sha256':digest(p)}
 (stage/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
 check(stage,platform,identity)
def main():
 p=argparse.ArgumentParser();p.add_argument('--prepare',action='store_true');p.add_argument('--check',action='store_true');p.add_argument('--platform',choices=['macosx','iphoneos','iphonesimulator'],required=True)
 p.add_argument('--stage',type=Path,default=ROOT/'.build/notebook-typesetter-runtime')
 p.add_argument('--distribution',type=Path,default=ROOT/'.build/notebook-typesetter-runtime/Resources/texlive.zip')
 args=p.parse_args();identity=input_digest()
 if args.prepare:prepare(args.stage.resolve(),args.platform,identity,args.distribution.resolve())
 else:check(args.stage.resolve(),args.platform,identity)
 print(args.stage.resolve())
if __name__=='__main__':main()

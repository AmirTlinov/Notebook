#!/usr/bin/env python3
"""Build a pinned SVG→PDF helper; --check only reads a frozen stage/source.

Cargo/registry access happens only in --prepare. No build paths, filesystem or
network switches are passed to the runtime helper, which reads SVG on stdin.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "Sources/NotebookImageCompiler"
RUST_VERSION = "1.94.1"
TARGET = "aarch64-apple-darwin"
DEPLOYMENT = "27.0"
BINARY = "notebook-image-compiler"
PINS = {"krilla":"=0.8.2", "krilla-svg":"=0.8.1", "usvg":"=0.47.0", "log":"=0.4.34"}


def sha(data): return hashlib.sha256(data).hexdigest()
def file_pin(path):
    if not path.is_file() or path.is_symlink(): raise RuntimeError("Expected regular image resource: " + str(path))
    data=path.read_bytes(); return {"bytes":len(data),"sha256":sha(data)}

def bundle_outputs(manifest):
    """Exact files and directories written by the sandboxed Xcode phase.

    Xcode grants literal paths for new outputs; naming a not-yet-created
    directory does not grant its descendants on a clean build.
    """
    paths={'Helpers/'+BINARY,'Resources/NotebookImages/manifest.json'}
    for relative in manifest['resources']:
        path=Path(relative)
        if not relative.startswith('Resources/NotebookImages/') or '..' in path.parts:
            raise RuntimeError('Image build output escapes its resource directory')
        paths.add(relative)
    for relative in tuple(paths):
        for parent in Path(relative).parents:
            # The preceding TeX phase owns the shared Helpers directory. Its
            # image consumer declares that directory as an input, not a second
            # output which would give Xcode two producers for the same path.
            if str(parent) not in ('.','Resources','Helpers'):
                paths.add(parent.as_posix())
    return ''.join('$(TARGET_BUILD_DIR)/$(CONTENTS_FOLDER_PATH)/'+path+'\n' for path in sorted(paths))

def check_bundle_outputs(manifest, path):
    if Path(path).read_text()!=bundle_outputs(manifest):
        raise RuntimeError('Xcode image outputs differ from the pinned resource inventory; regenerate the owned xcfilelist before building')
def pinned_tables(path):
    # These two owned build manifests deliberately use only simple sections and
    # JSON-compatible literal values. Reject richer TOML syntax rather than
    # silently interpreting it differently on Xcode's system Python 3.9.
    tables = {}; current = None
    for raw in Path(path).read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#"): continue
        section = re.fullmatch(r"\[([A-Za-z0-9_.-]+)\]", line)
        if section:
            current = section.group(1)
            if current in tables: raise RuntimeError("Duplicate pinned build section")
            tables[current] = {}; continue
        entry = re.fullmatch(r"([A-Za-z0-9_-]+)\s*=\s*(.+)", line)
        if current is None or not entry or entry.group(1) in tables[current]:
            raise RuntimeError("Unsupported or duplicate syntax in owned pinned build manifest")
        try: tables[current][entry.group(1)] = json.loads(entry.group(2))
        except ValueError as error: raise RuntimeError("Pinned build manifest requires JSON-compatible literal values") from error
    return tables


def source_inputs(source=SOURCE):
    source=Path(source)
    files=[source/name for name in ("Cargo.toml","Cargo.lock","rust-toolchain.toml")]
    for directory in ("src","licenses"):
        root=source/directory
        if not root.is_dir() or root.is_symlink(): raise RuntimeError("Missing image source directory: "+directory)
        for path in sorted(root.rglob("*")):
            if path.is_symlink(): raise RuntimeError("Image sources cannot contain symlinks")
            if path.is_file():files.append(path)
    cargo=pinned_tables(source/'Cargo.toml')
    toolchain=pinned_tables(source/'rust-toolchain.toml')['toolchain']
    if cargo["package"]["name"]!=BINARY or cargo["dependencies"]!=PINS:raise RuntimeError("Image compiler dependency pins changed")
    if toolchain!={"channel":RUST_VERSION,"profile":"minimal","targets":[TARGET]}:raise RuntimeError("Image compiler toolchain pin changed")
    records=[{"path":str(path.relative_to(source)),**file_pin(path)} for path in sorted(files)]
    return {"files":records,"sha256":sha(json.dumps(records,sort_keys=True).encode())}


def macho(data):
    """Inspect architecture/imports and hash code independently of re-signing.

    Codesign changes LC_CODE_SIGNATURE and __LINKEDIT allocation. Normalize
    only those lengths/pointers and exclude the signature blob. Every preceding
    executable byte and all other load commands remain in the fingerprint.
    """
    if len(data)<32:raise RuntimeError("Image helper has no Mach-O header")
    magic,cpu,subtype,kind,count,size,flags,reserved=struct.unpack_from('<IiiIIIII',data)
    if magic!=0xFEEDFACF or cpu!=0x0100000C or kind!=2 or count>4096 or size>len(data)-32:raise RuntimeError("Image helper must be thin arm64 Mach-O executable")
    output=bytearray(data);cursor=32;signature=None;platform=None;minimum=None;libraries=[]
    for _ in range(count):
        if cursor+8>32+size:raise RuntimeError("Truncated image helper load commands")
        command,length=struct.unpack_from('<II',data,cursor)
        if length<8 or cursor+length>32+size:raise RuntimeError("Invalid image helper load command size")
        if command==0x1D:
            if length!=16 or signature is not None:raise RuntimeError("Invalid image helper code signature command")
            start,amount=struct.unpack_from('<II',data,cursor+8)
            if start<32+size or amount==0 or start+amount!=len(data):raise RuntimeError("Image helper signature does not end the executable")
            signature=start;output[cursor+8:cursor+16]=bytes(8)
        elif command==0x19:
            if length<72:raise RuntimeError("Truncated image helper segment")
            name=data[cursor+8:cursor+24].rstrip(b'\0')
            if name==b'__LINKEDIT':output[cursor+32:cursor+40]=bytes(8);output[cursor+48:cursor+56]=bytes(8)
        elif command==0x32:
            if length<24:raise RuntimeError("Truncated image helper build version")
            platform,minimum=struct.unpack_from('<II',data,cursor+8)
        elif command in (0xC,0x80000018,0x8000001F,0x20,0x80000023):
            if length<24:raise RuntimeError("Truncated image helper dylib command")
            offset=struct.unpack_from('<I',data,cursor+8)[0]
            if not 24<=offset<length:raise RuntimeError("Invalid dylib name")
            library=data[cursor+offset:cursor+length].split(b'\0',1)[0].decode('utf8')
            if not library.startswith(('/System/Library/','/usr/lib/')):raise RuntimeError("Non-system image helper library: "+library)
            libraries.append(library)
        elif command==0x8000001C:raise RuntimeError("Image helper cannot depend on a runtime library search path")
        cursor+=length
    if cursor!=32+size or signature is None or platform!=1 or minimum!=(27<<16):raise RuntimeError("Image helper must target signed macOS 27.0")
    return {"architecture":"arm64","platform":"MACOS","minimumOS":DEPLOYMENT,
            "systemLibraries":libraries,"codeSHA256":sha(output[:signature])}


def metadata_licenses(metadata, destination, source):
    packages=[]
    supplemental=source/'licenses'
    for package in sorted(metadata['packages'],key=lambda p:(p['name'],p['version'])):
        if package['source'] is None:continue
        name,version=package['name'],package['version']
        if not re.fullmatch(r'[A-Za-z0-9_-]+',name) or not re.fullmatch(r'[0-9A-Za-z.+-]+',version):raise RuntimeError("Invalid crate identity")
        root=Path(package['manifest_path']).parent
        paths=[]
        for path in root.rglob('*'):
            if path.is_file() and path.name.upper().startswith(('LICENSE','LICENCE','COPYING','NOTICE','COPYRIGHT')):
                if path.is_symlink() or not path.resolve().is_relative_to(root.resolve()):raise RuntimeError("Crate license escapes package")
                paths.append(path)
        target=destination/(name+'-'+version);target.mkdir(parents=True)
        copied=[]
        for path in sorted(paths):
            relative=path.relative_to(root);out=target/relative;out.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(path,out)
            copied.append(str(out.relative_to(destination)))
        if name in ('krilla','krilla-svg'):
            for path in sorted((supplemental/'krilla').iterdir()):
                out=target/('upstream-'+path.name);shutil.copyfile(path,out);copied.append(str(out.relative_to(destination)))
        if not copied:raise RuntimeError("No redistributable notice for locked crate: "+name+'@'+version)
        packages.append({"name":name,"version":version,"license":package['license'],"source":package['source'],"notices":copied})
    return packages


def check(stage, source=SOURCE, *, signed=False, container=False):
    stage,source=Path(stage),Path(source)
    if stage.is_symlink():raise RuntimeError("Image stage cannot be a symlink")
    resources=stage/'Resources/NotebookImages';manifest_path=resources/'manifest.json'
    manifest=json.loads(manifest_path.read_text())
    if manifest['schema']!=1 or manifest['source']!=source_inputs(source) or manifest['target']!=TARGET or manifest['rustVersion']!=RUST_VERSION or manifest['deploymentTarget']!=DEPLOYMENT:
        raise RuntimeError("Image stage does not match pinned source/toolchain")
    paths=list((resources if container else stage).rglob('*'))
    if any(p.is_symlink() for p in paths):raise RuntimeError("Image stage contains a symlink")
    expected=set(manifest['resources'])|{'Resources/NotebookImages/manifest.json'}
    if not container:expected.add('Helpers/'+BINARY)
    if {str(p.relative_to(stage)) for p in paths if p.is_file()}!=expected:raise RuntimeError("Image stage contains missing or untracked files")
    for entry in manifest['source']['files']:
        if manifest['resources'].get('Resources/NotebookImages/source/'+entry['path'])!={k:entry[k] for k in ('bytes','sha256')}:
            raise RuntimeError('Bundled image compiler source differs from its immutable source fingerprint')
    for relative,pin in manifest['resources'].items():
        if not relative.startswith('Resources/NotebookImages/') or '..' in Path(relative).parts:raise RuntimeError('Invalid image resource path')
        path=stage/relative
        if not path.resolve().is_relative_to(stage.resolve()) or file_pin(path)!=pin:raise RuntimeError("Image stage resource changed: "+relative)
    compiler=stage/'Helpers'/BINARY
    inspection=macho(compiler.read_bytes())
    if inspection!=manifest['binaryInspection']:raise RuntimeError("Image compiler code/platform/library fingerprint changed")
    if not signed and file_pin(compiler)!=manifest['unsignedBinary']:raise RuntimeError("Prepared image compiler bytes changed")
    return manifest


def prepare(stage, source=SOURCE, target_dir=None):
    stage,source=Path(stage),Path(source)
    before=source_inputs(source)
    if stage.exists():return check(stage,source)
    rustup=shutil.which('rustup')
    if not rustup:raise RuntimeError("Pinned Rust toolchain 1.94.1 is required at build time")
    rustc=subprocess.check_output([rustup,'run',RUST_VERSION,'rustc','--version'],text=True).strip()
    cargo=subprocess.check_output([rustup,'run',RUST_VERSION,'cargo','--version'],text=True).strip()
    if not rustc.startswith('rustc '+RUST_VERSION+' ') or not cargo.startswith('cargo '+RUST_VERSION+' '):raise RuntimeError("Rust toolchain differs from source pin")
    target_dir=Path(target_dir or ROOT/'.build/notebook-image-compiler-build').resolve()
    environment={**os.environ,'MACOSX_DEPLOYMENT_TARGET':DEPLOYMENT}
    command=[rustup,'run',RUST_VERSION,'cargo','build','--locked','--release','--manifest-path',str(source/'Cargo.toml'),
             '--target',TARGET,'--target-dir',str(target_dir)]
    subprocess.run(command,check=True,env=environment,stdout=sys.stderr)
    metadata=json.loads(subprocess.check_output([rustup,'run',RUST_VERSION,'cargo','metadata','--locked','--offline',
        '--format-version','1','--manifest-path',str(source/'Cargo.toml')],env=environment))
    stage.parent.mkdir(parents=True,exist_ok=True)
    temporary=Path(tempfile.mkdtemp(prefix='notebook-images-',dir=stage.parent))
    try:
        helper=temporary/'Helpers'/BINARY;helper.parent.mkdir();shutil.copyfile(target_dir/TARGET/'release'/BINARY,helper);helper.chmod(0o755)
        resources=temporary/'Resources/NotebookImages';resources.mkdir(parents=True)
        for entry in before['files']:
            target=resources/'source'/entry['path'];target.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(source/entry['path'],target)
        packages=metadata_licenses(metadata,resources/'licenses',source)
        pins={str(path.relative_to(temporary)):file_pin(path) for path in sorted(resources.rglob('*')) if path.is_file()}
        manifest={'schema':1,'source':before,'rustVersion':RUST_VERSION,'target':TARGET,'deploymentTarget':DEPLOYMENT,
                  'rustc':rustc,'cargo':cargo,'buildArguments':['build','--locked','--release','--target',TARGET],
                  'unsignedBinary':file_pin(helper),'binaryInspection':macho(helper.read_bytes()),'resources':pins,'packages':packages}
        (resources/'manifest.json').write_text(json.dumps(manifest,indent=2,sort_keys=True)+'\n')
        if source_inputs(source)!=before:raise RuntimeError("Image compiler sources changed during preparation")
        check(temporary,source)
        if stage.exists():raise RuntimeError("Image stage appeared during preparation; existing evidence not replaced")
        temporary.rename(stage);return manifest
    finally:
        if temporary.exists():shutil.rmtree(temporary)


def main():
    p=argparse.ArgumentParser(description=__doc__);m=p.add_mutually_exclusive_group(required=True)
    m.add_argument('--prepare',action='store_true');m.add_argument('--check',action='store_true')
    s=p.add_mutually_exclusive_group();s.add_argument('--stage',type=Path);s.add_argument('--stage-root',type=Path)
    p.add_argument('--target-dir',type=Path)
    p.add_argument('--output-list',type=Path,help='Validate the checked-in Xcode output inventory without modifying it')
    args=p.parse_args()
    if args.check and not args.stage:p.error('--check requires exact --stage; never prepares or discovers resources')
    explicit=args.stage or (Path(os.environ['NOTEBOOK_IMAGE_RUNTIME']) if 'NOTEBOOK_IMAGE_RUNTIME' in os.environ else None)
    stage=(explicit or (args.stage_root or ROOT/'.build/notebook-image-runtime')/source_inputs()['sha256']).resolve()
    manifest=prepare(stage,target_dir=args.target_dir) if args.prepare else check(stage)
    if args.output_list:check_bundle_outputs(manifest,args.output_list)
    print(json.dumps({'status':'ready','stage':str(stage),'sourceSHA256':manifest['source']['sha256'],
                      'compilerCodeSHA256':manifest['binaryInspection']['codeSHA256']}))

if __name__=='__main__':main()

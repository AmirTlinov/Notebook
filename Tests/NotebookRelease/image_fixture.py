"""Fabricated CPU-only packaging inputs; never run, signed, or shipped."""
from pathlib import Path
import json
import shutil
import struct
import prepare_notebook_images as images


def source(root):
    root=Path(root);(root/'src').mkdir(parents=True);(root/'licenses').mkdir()
    dependencies='\n'.join(name+' = '+json.dumps(version) for name,version in images.PINS.items())
    (root/'Cargo.toml').write_text('[package]\nname="notebook-image-compiler"\nversion="1.0.0"\n[dependencies]\n'+dependencies+'\n')
    (root/'Cargo.lock').write_text('# Fabricated CPU contract input, not a build lock\n')
    (root/'rust-toolchain.toml').write_text('[toolchain]\nchannel="1.94.1"\nprofile="minimal"\ntargets=["aarch64-apple-darwin"]\n')
    (root/'src/main.rs').write_text('// Fabricated CPU contract; not compiled\n')
    (root/'licenses/NOTICE').write_text('Synthetic license resource for packaging tests only\n')
    return root


def executable(signature=b'unsigned-signature', library='/usr/lib/libSystem.B.dylib'):
    dylib=library.encode()+b'\0';dylib+=bytes((-len(dylib))%8)
    linkedit=struct.pack('<II16sQQQQiiII',0x19,72,b'__LINKEDIT',0,4096,256,256+len(signature),7,1,0,0)
    version=struct.pack('<IIIIII',0x32,24,1,27<<16,27<<16,0)
    imports=struct.pack('<IIIIII',0xC,24+len(dylib),24,0,0,0)+dylib
    commands=linkedit+version+imports+struct.pack('<IIII',0x1D,16,256,len(signature))
    header=struct.pack('<IiiIIIII',0xFEEDFACF,0x0100000C,0,2,4,len(commands),0,0)
    prefix=header+commands;return prefix+bytes(256-len(prefix))+signature


def stage(root, source_root, signature=b'unsigned-signature'):
    root,source_root=Path(root),Path(source_root);helper=root/'Helpers'/images.BINARY
    helper.parent.mkdir(parents=True,exist_ok=True);helper.write_bytes(executable(signature));helper.chmod(0o755)
    resources=root/'Resources/NotebookImages';resources.mkdir(parents=True,exist_ok=True)
    inputs=images.source_inputs(source_root)
    for entry in inputs['files']:
        target=resources/'source'/entry['path'];target.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(source_root/entry['path'],target)
    pins={str(p.relative_to(root)):images.file_pin(p) for p in resources.rglob('*') if p.is_file()}
    manifest={'schema':1,'source':inputs,'rustVersion':images.RUST_VERSION,'target':images.TARGET,
        'deploymentTarget':images.DEPLOYMENT,'rustc':'synthetic compiler identity','cargo':'synthetic cargo identity',
        'binaryInspection':images.macho(helper.read_bytes()),'unsignedBinary':images.file_pin(helper),
        'resources':pins,'packages':[]}
    (resources/'manifest.json').write_text(json.dumps(manifest));return root

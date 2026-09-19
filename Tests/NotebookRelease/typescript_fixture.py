"""Synthetic compiler bytes for packaging guards, never executable evidence."""
import json, shutil, struct, tempfile
from pathlib import Path
import macho_fixture
import prepare_notebook_typescript as ts


def inputs(root):
    root=Path(root);package=root/'MCP/node_modules/@typescript/typescript-darwin-arm64'
    (package/'lib').mkdir(parents=True)
    data=bytearray(macho_fixture.executable());struct.pack_into('<I',data,32+72+12,12<<16)
    (package/'lib/tsc').write_bytes(data)
    (package/'package.json').write_text('{"version":"7.0.2"}')
    resources={'lib.d.ts':b'// CLI discovery library', 'lib.es5.d.ts':b'// synthetic declarations', 'LICENSE':b'synthetic license'}
    for name,content in resources.items():(package/('lib/'+name if name.startswith('lib.') else name)).write_bytes(content)
    sdk=root/'Sources/NotebookScriptHost/Resources/notebook-sdk.d.ts';sdk.parent.mkdir(parents=True);sdk.write_bytes(b'// synthetic SDK')
    lock=root/'Sources/NotebookMarkupService/TypeScriptResources.lock.json';lock.parent.mkdir(parents=True,exist_ok=True)
    lock.write_text(json.dumps({'version':'7.0.2','compiler':{'file':ts.pin(package/'lib/tsc'),'macho':ts.macho(bytes(data),minimum_os='12.0')},
      'resources':{name:ts.pin(package/('lib/'+name if name.startswith('lib.') else name)) for name in resources}}))
    return {'PACKAGE':package,'SDK':sdk,'LOCK':lock}


def stage(contents):
    with tempfile.TemporaryDirectory() as temporary:
        source=Path(temporary)/'stage';ts.prepare(source)
        shutil.copytree(source/ts.RESOURCES,Path(contents)/ts.RESOURCES,dirs_exist_ok=True)
        helper=Path(contents)/ts.BINARY;helper.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(source/ts.BINARY,helper);helper.chmod(0o755)
        (Path(contents)/ts.DISCOVERY).symlink_to(ts.DISCOVERY_TARGET)

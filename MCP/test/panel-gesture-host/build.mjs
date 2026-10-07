import {build} from 'esbuild';
import {mkdir,readFile,writeFile} from 'node:fs/promises';
import {dirname,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import {gzipSync} from 'node:zlib';
import {readSurface} from '../../build-surface.mjs';
import {sealPanelBundle} from '../../panel-bundle.mjs';

const root=resolve(dirname(fileURLToPath(import.meta.url)),'../..');
const output=resolve(root,'../.build/panel-gesture-host');
// This route consumes the existing pin-checked stage and never starts Swift.
const {bytes,receipt}=await readSurface(process.env.NOTEBOOK_SURFACE_STAGE??resolve(root,'../.build/surface'));
const script=await build({entryPoints:[resolve(root,'test/panel-gesture-host/client.ts')],bundle:true,platform:'browser',
  target:'es2022',format:'esm',write:false,define:{NOTEBOOK_SURFACE_WASM:JSON.stringify(gzipSync(bytes).toString('base64'))}});
const [html,css]=await Promise.all([readFile(resolve(root,'panel/index.html'),'utf8'),readFile(resolve(root,'panel/styles.css'),'utf8')]);
await mkdir(output,{recursive:true});
const {version}=JSON.parse(await readFile(resolve(root,'plugin/notebook/plugin.json'),'utf8'));
const panel=sealPanelBundle(html.replace('/* NOTEBOOK_STYLE */',()=>css)
  .replace('/* NOTEBOOK_SCRIPT */',()=>script.outputFiles[0].text.replaceAll('</script','<\\/script')),version);
await writeFile(resolve(output,'index.html'),panel.html);
await writeFile(resolve(output,'surface-build.json'),JSON.stringify(receipt,null,2)+'\n');
console.log(JSON.stringify({path:resolve(output,'index.html'),moduleSHA256:receipt.sha256}));

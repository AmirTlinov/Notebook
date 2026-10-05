import {build} from 'esbuild';
import {readFile,writeFile,mkdir} from 'node:fs/promises';
import {dirname,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import {gzipSync} from 'node:zlib';
import {buildSurface,readSurface} from './build-surface.mjs';
const root=dirname(fileURLToPath(import.meta.url));
export async function buildPanel(){
  const {bytes}=await (process.env.NOTEBOOK_SURFACE_STAGE?readSurface(process.env.NOTEBOOK_SURFACE_STAGE):buildSurface());
  const js=await build({entryPoints:[resolve(root,'panel/panel.ts')],bundle:true,platform:'browser',target:'es2022',format:'esm',write:false,minify:true,
    define:{NOTEBOOK_SURFACE_WASM:JSON.stringify(gzipSync(bytes).toString('base64'))}});
  const html=await readFile(resolve(root,'panel/index.html'),'utf8');
  const css=await readFile(resolve(root,'panel/styles.css'),'utf8');
  return html.replace('/* NOTEBOOK_STYLE */',()=>css).replace('/* NOTEBOOK_SCRIPT */',()=>js.outputFiles[0].text.replaceAll('</script','<\\/script'));
}
if(process.argv[1]===fileURLToPath(import.meta.url)){
  const output=resolve(process.argv[2]??resolve(root,'../.build/notebook-panel.html'));
  await mkdir(dirname(output),{recursive:true});await writeFile(output,await buildPanel());
}

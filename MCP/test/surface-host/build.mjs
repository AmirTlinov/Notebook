import {build} from 'esbuild';
import {mkdir,writeFile,readFile} from 'node:fs/promises';
import {dirname,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import {gzipSync} from 'node:zlib';
import {buildSurface} from '../../build-surface.mjs';
const root=dirname(fileURLToPath(import.meta.url));
const output=resolve(root,'../../../.build/surface-host-plugin');
const plugin=resolve(output,'surface-host');
const {bytes,receipt}=await buildSurface();
const client=await build({entryPoints:[resolve(root,'client.mjs')],bundle:true,platform:'browser',target:'es2022',format:'esm',write:false,
  define:{SURFACE_WASM_GZIP:JSON.stringify(gzipSync(bytes).toString('base64')),SURFACE_WASM_SHA256:JSON.stringify(receipt.sha256)}});
const html=(await readFile(resolve(root,'index.html'),'utf8')).replace('/* SCRIPT */',()=>client.outputFiles[0].text.replaceAll('</script','<\\/script'));
await mkdir(resolve(plugin,'.codex-plugin'),{recursive:true});await mkdir(resolve(output,'.agents/plugins'),{recursive:true});
await build({entryPoints:[resolve(root,'server.ts')],bundle:true,platform:'node',target:'node22',format:'esm',outfile:resolve(plugin,'server.mjs'),
  define:{SURFACE_HOST_HTML:JSON.stringify(html)},banner:{js:"import {createRequire} from 'node:module';const require=createRequire(import.meta.url);"}});
await writeFile(resolve(output,'.agents/plugins/marketplace.json'),JSON.stringify({name:'notebook-surface-verification',plugins:[{name:'surface-host',source:{source:'local',path:'./surface-host'},policy:{installation:'AVAILABLE',authentication:'ON_INSTALL'}}]},null,2));
await writeFile(resolve(plugin,'.codex-plugin/plugin.json'),JSON.stringify({name:'surface-host',version:'1.0.0',description:'Temporary Notebook surface capability checks; no workspace access.',mcpServers:'./mcp.json',interface:{displayName:'Notebook surface verification',shortDescription:'Check the Codex surface host',capabilities:['Interactive','Read']}},null,2));
await writeFile(resolve(plugin,'mcp.json'),JSON.stringify({mcpServers:{notebook_surface_verification:{type:'stdio',command:process.execPath,args:[resolve(plugin,'server.mjs')]}}},null,2));
await writeFile(resolve(output,'surface-build.json'),JSON.stringify(receipt,null,2));
console.log(JSON.stringify({marketplace:output,plugin:'surface-host@notebook-surface-verification',surface:receipt},null,2));

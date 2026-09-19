#!/usr/bin/env node
import {readFile,writeFile} from 'node:fs/promises';
import {readFileSync,existsSync} from 'node:fs';
import {resolve} from 'node:path';
import {fileURLToPath} from 'node:url';

// Preview the exact prepared program. This page has no Notebook connection;
// its state lives only until reload. Publication still uses submit.mjs.
export function animationPreview(request) {
  const candidates=process.env.NOTEBOOK_PROGRAM_BRIDGE ? [resolve(process.env.NOTEBOOK_PROGRAM_BRIDGE)] : [
    new URL('../../../../Applications/WebResources/notebook-program.js',import.meta.url),
    new URL('../../../../WebResources/notebook-program.js',import.meta.url)];
  const bridgePath=candidates.find(path=>existsSync(path));
  if(!bridgePath)throw new Error('Notebook browser bridge is missing; set NOTEBOOK_PROGRAM_BRIDGE to the installed notebook-program.js');
  const bridge=readFileSync(bridgePath,'utf8');
  const programs=(request.args?.operations??[]).filter(op=>
    (op.kind==='insertElement'&&op.values.kind==='web')||(op.kind==='insertBlock'&&op.values.kind==='interactive'));
  if(programs.length!==1)throw new Error('Preview needs exactly one prepared animation');
  const value=programs[0].values;
  const json=value=>JSON.stringify(value).replace(/</g,'\\u003c');
  return `<!doctype html><html lang="ru"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'none';img-src data: blob:;style-src 'unsafe-inline';script-src 'unsafe-inline';font-src data:;media-src data: blob:;connect-src 'none';form-action 'none';base-uri 'none';object-src 'none'">
<title>Notebook — анимация (локальный просмотр)</title>
<style>html,body{margin:0;background:#fff;color:#171714;font:17px/1.42 -apple-system,BlinkMacSystemFont,sans-serif}*{box-sizing:border-box}</style>
<script>
${bridge}
window.notebookProgram=createNotebookProgram({state:${json(value.state??value.initialState??{})},
  paint:()=>new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve))),
  report:(kind,message)=>{document.documentElement.dataset.programError=kind+': '+message;console.error(kind,message)}});
window.notebook=notebookProgram.api;
addEventListener('load',async()=>{try{
  await document.fonts.ready;await Promise.all([...document.images].map(image=>image.decode()));
  const receipt=await notebookProgram.start({requiresReady:${!!(String(value.javaScript??'').trim() || /<script/i.test(value.html??''))}});
  document.documentElement.dataset.programReady=receipt.version;
}catch(error){document.documentElement.dataset.programError=String(error)}});
addEventListener('pagehide',()=>{void notebookProgram.dispose().catch(()=>{})});
const style=document.createElement('style');style.textContent=${json(value.css??'')};document.head.append(style);
</script></head><body>${value.html}
<script>const program=document.createElement('script');program.textContent=${json(value.javaScript??'')};document.body.append(program);</script>
</body></html>`;
}

if(process.argv[1]&&resolve(process.argv[1])===fileURLToPath(import.meta.url)) {
  const [input,output,...extra]=process.argv.slice(2);
  try {
    if(!input||!output||extra.length)throw new Error('Usage: node animation-preview.mjs request.json preview.html');
    await writeFile(output,animationPreview(JSON.parse(await readFile(input,'utf8'))),{flag:'wx'});
    process.stdout.write(resolve(output)+'\n');
  }catch(error){process.stderr.write(error.message+'\n');process.exitCode=1;}
}

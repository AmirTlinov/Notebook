#!/usr/bin/env node
import {readFile,writeFile} from 'node:fs/promises';
import {readFileSync,existsSync} from 'node:fs';
import {resolve} from 'node:path';
import {fileURLToPath} from 'node:url';

// Preview the exact prepared program. This page has no Notebook connection;
// its state lives only until reload. Publication still uses submit.mjs.
export function loadBrowserBridge() {
  const candidates=process.env.NOTEBOOK_PROGRAM_BRIDGE ? [resolve(process.env.NOTEBOOK_PROGRAM_BRIDGE)] : [
    new URL('../../../../Applications/WebResources/notebook-program.js',import.meta.url),
    new URL('../../../../WebResources/notebook-program.js',import.meta.url)];
  const bridgePath=candidates.find(path=>existsSync(path));
  if(!bridgePath)throw new Error('Notebook browser bridge is missing; set NOTEBOOK_PROGRAM_BRIDGE to the installed notebook-program.js');
  return {path:bridgePath,source:readFileSync(bridgePath,'utf8')};
}

const json=value=>JSON.stringify(value).replace(/</g,'\\u003c');

/** Local transport only; the public API is the same notebook-program.js. */
export function previewDocument({state={},requiresReady=true,policy,css='',cssURL,scriptURL,module=true,identity={},diagnosticsURL}={}) {
  const bridge=loadBrowserBridge().source;
  return {before:`<!doctype html><html lang="ru"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="${policy}">
<title>Notebook — локальный preview (не установленное приложение)</title>
<style>html,body{margin:0;background:#fff;color:#171714;font:17px/1.42 -apple-system,BlinkMacSystemFont,sans-serif}*{box-sizing:border-box}</style>
${cssURL?`<link rel="stylesheet" href="${cssURL}">`:''}
<script>
${bridge}
window.notebookPreview=Object.freeze(${json({runtime:'local-browser',api:'NotebookProgram/1',...identity})});
window.notebookPreviewDiagnostics=[];
function showPreviewErrors(){
  if(!document.body){addEventListener('DOMContentLoaded',showPreviewErrors,{once:true});return}
  let view=document.getElementById('notebook-preview-error');
  if(!view){view=document.createElement('pre');view.id='notebook-preview-error';view.setAttribute('role','alert');
    view.style.cssText='white-space:pre-wrap;padding:16px;border:1px solid #bb4939;color:#8b2014;font:14px/1.5 monospace';document.body.prepend(view)}
  view.textContent=notebookPreviewDiagnostics.map(d=>{const source=d.source;return d.stage+': '+d.message+(source?' — '+source.file+':'+source.line+':'+source.column:'')}).join('\\n');
}
function previewError(stage,reason,file,line,column){
  const diagnostic={stage,message:String(reason?.message||reason),stack:String(reason?.stack||''),file,line,column};
  notebookPreviewDiagnostics.push(diagnostic);if(notebookPreviewDiagnostics.length>20)notebookPreviewDiagnostics.shift();
  document.documentElement.dataset.programError=stage+': '+diagnostic.message;
  delete document.documentElement.dataset.programReady;
  console.error(stage,reason);showPreviewErrors();
  ${diagnosticsURL?`void fetch(${json(diagnosticsURL)},{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(diagnostic)}).then(response=>response.json()).then(result=>{diagnostic.source=result.source;showPreviewErrors()}).catch(()=>{});`:''}
}
addEventListener('error',event=>previewError('runtime',event.error||event.message||'Resource failed',event.filename||event.target?.src,event.lineno,event.colno),true);
addEventListener('unhandledrejection',event=>previewError('runtime',event.reason));
window.notebookProgram=createNotebookProgram({state:${json(state)},
  paint:()=>new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve))),
  report:(kind,message)=>previewError(kind,message)});
window.notebook=notebookProgram.api;
addEventListener('load',async()=>{try{
  await document.fonts.ready;await Promise.all([...document.images].map(image=>image.decode()));
  const receipt=await notebookProgram.start({requiresReady:${requiresReady}});
  if(!notebookPreviewDiagnostics.length)document.documentElement.dataset.programReady=receipt.version;
}catch(error){previewError('ready',error)}});
addEventListener('pagehide',()=>{void notebookProgram.dispose().catch(()=>{})});
const style=document.createElement('style');style.textContent=${json(css)};document.head.append(style);
</script></head><body>`,after:`${scriptURL?`<script${module?' type="module"':''} src="${scriptURL}"></script>`:''}</body></html>`};
}

export function animationPreview(request) {
  const programs=(request.args?.operations??[]).filter(op=>
    (op.kind==='insertElement'&&op.values.kind==='web')||(op.kind==='insertBlock'&&op.values.kind==='interactive'));
  if(programs.length!==1)throw new Error('Preview needs exactly one prepared animation');
  const value=programs[0].values;
  if(value.programPackage)throw new Error('A packaged program needs its prepared files for preview, not an empty inline page');
  const parts=previewDocument({state:value.state??value.initialState??{},css:value.css??'',
    requiresReady:!!(String(value.javaScript??'').trim()||/<script/i.test(value.html??'')),
    policy:"default-src 'none';img-src data: blob:;style-src 'unsafe-inline';script-src 'unsafe-inline';font-src data:;media-src data: blob:;connect-src 'none';form-action 'none';base-uri 'none';object-src 'none'"});
  return parts.before+value.html+`<script>const program=document.createElement('script');program.textContent=${json(value.javaScript??'')};document.body.append(program);</script>`+parts.after;
}

if(process.argv[1]&&resolve(process.argv[1])===fileURLToPath(import.meta.url)) {
  const [input,output,...extra]=process.argv.slice(2);
  try {
    if(!input||!output||extra.length)throw new Error('Usage: node animation-preview.mjs request.json preview.html');
    await writeFile(output,animationPreview(JSON.parse(await readFile(input,'utf8'))),{flag:'wx'});
    process.stdout.write(resolve(output)+'\n');
  }catch(error){process.stderr.write(error.message+'\n');process.exitCode=1;}
}

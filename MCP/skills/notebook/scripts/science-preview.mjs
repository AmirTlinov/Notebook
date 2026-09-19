#!/usr/bin/env node
// Uses the existing inline and asset-backed author previews; no second scene runtime.
import {mkdir,writeFile} from 'node:fs/promises';
import {resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import {prepare} from './prepare.mjs';
import {scienceExamples} from './science-examples.mjs';
import {animationPreview} from './animation-preview.mjs';
import {startProgramPreview} from './program-preview.mjs';

const escape=value=>value.replaceAll('&','&amp;').replaceAll('"','&quot;').replaceAll('<','&lt;').replaceAll('>','&gt;');

export async function startSciencePreview(directory) {
  const previews=[],examples=[];
  const close=()=>Promise.all(previews.map(preview=>preview.close()));
  try {
    await mkdir(directory,{recursive:true});
    for(const example of scienceExamples) {
      if(example.format==='program') {
        const descriptor=await prepare('program',{example:example.id});
        const preview=await startProgramPreview(descriptor);
        previews.push(preview);examples.push({...example,url:preview.url,identity:preview.identity});
      } else {
        const request=await prepare('animation',{example:example.id,target:{kind:'page',id:'local-preview-only'}},{runID:`science-preview-${example.id}`});
        const html=animationPreview(request).replace('<title>Notebook — локальный preview (не установленное приложение)</title>',`<title>${escape(example.title)} — Notebook</title>`);
        await writeFile(resolve(directory,example.id+'.html'),html);
        examples.push({...example,url:example.id+'.html'});
      }
    }
    const cards=examples.map(e=>`<article><a class="preview" href="${escape(e.url)}" aria-label="Открыть: ${escape(e.title)}"><iframe src="${escape(e.url)}" title="Миниатюра ${escape(e.title)}" tabindex="-1" aria-hidden="true" loading="lazy"></iframe></a><div class="caption"><h2><a href="${escape(e.url)}">${escape(e.title)}</a></h2></div></article>`).join('\n');
    await writeFile(resolve(directory,'index.html'),`<!doctype html><html lang="ru"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Научные примеры — Notebook</title>
<style>*{box-sizing:border-box}body{margin:0;background:#fff;color:#191a20;font:16px/1.5 -apple-system,BlinkMacSystemFont,sans-serif}main{max-width:1200px;margin:auto;padding:48px 28px}header{max-width:780px;margin-bottom:40px}h1{font:600 clamp(36px,6vw,56px)/1.06 -apple-system,BlinkMacSystemFont,sans-serif;margin:0}.gallery{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:32px}article{border-top:1px solid #e5e7ee}.preview{display:block;position:relative;height:380px;overflow:hidden;background:#fff}.preview iframe{position:absolute;left:0;top:0;border:0;width:200%;height:1100px;transform:scale(.5);transform-origin:top left;pointer-events:none}.caption{padding:16px 0 24px}.caption h2{font:500 23px/1.15 -apple-system,BlinkMacSystemFont,sans-serif;margin:8px 0}a{color:inherit;text-underline-offset:4px}h2 a{text-decoration:none}a:focus-visible{outline:3px solid #4263eb;outline-offset:5px}@media(max-width:720px){main{padding:28px 16px}.gallery{grid-template-columns:1fr}.preview{height:340px}}</style>
<main><header><h1>Увидеть связь.</h1></header><div class="gallery">${cards}</div></main></html>`);
    return {path:resolve(directory,'index.html'),examples,close};
  } catch(error) {await close();throw error;}
}

if(process.argv[1]&&resolve(process.argv[1])===fileURLToPath(import.meta.url)) {
  const [directory,...extra]=process.argv.slice(2);
  try {
    if(!directory||extra.length)throw new Error('Usage: node science-preview.mjs OUTPUT_DIRECTORY');
    const preview=await startSciencePreview(directory);
    console.log(preview.path);
    process.stderr.write('Локальные предпросмотры пакетов работают до Ctrl+C. Подключения к Notebook нет.\n');
    for(const name of ['SIGINT','SIGTERM'])process.once(name,()=>void preview.close());
  } catch(error) {process.stderr.write(error.message+'\n');process.exitCode=1;}
}

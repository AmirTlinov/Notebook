#!/usr/bin/env node
// Builds the exact animation programs, using the existing preparation/preview path.
import {mkdir,writeFile} from 'node:fs/promises';
import {resolve} from 'node:path';
import {prepare} from './prepare.mjs';
import {scienceExamples} from './science-examples.mjs';
import {animationPreview} from './animation-preview.mjs';

const [directory,...extra]=process.argv.slice(2);
if(!directory||extra.length)throw new Error('Usage: node science-preview.mjs OUTPUT_DIRECTORY');
await mkdir(directory,{recursive:true});
for(const example of scienceExamples) {
  const request=await prepare('animation',{example:example.id,target:{kind:'page',id:'local-preview-only'}},{runID:`science-preview-${example.id}`});
  const html=animationPreview(request).replace('<title>Notebook — анимация (локальный просмотр)</title>',`<title>${example.title} — Notebook</title>`);
  await writeFile(resolve(directory,example.id+'.html'),html);
}
const cards=scienceExamples.map((e,i)=>`<article><a class="preview" href="${e.id}.html" aria-label="Открыть: ${e.title}"><iframe src="${e.id}.html" title="Миниатюра ${e.title}" tabindex="-1" aria-hidden="true" loading="lazy"></iframe></a><div class="caption"><span>0${i+1} / ${e.id}</span><h2><a href="${e.id}.html">${e.title}</a></h2><p>${e.idea}</p><a href="${e.source}">Исходный референс</a></div></article>`).join('\n');
await writeFile(resolve(directory,'index.html'),`<!doctype html><html lang="ru"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Семь научных экспликаций — Notebook</title>
<style>*{box-sizing:border-box}body{margin:0;background:#fff;color:#191a20;font:16px/1.5 -apple-system,BlinkMacSystemFont,sans-serif}main{max-width:1200px;margin:auto;padding:48px 28px}header{max-width:780px;margin-bottom:40px}header>span,.caption>span{font-size:11px;letter-spacing:.14em;text-transform:uppercase;color:#6d7280}h1{font:600 clamp(36px,6vw,56px)/1.06 -apple-system,BlinkMacSystemFont,sans-serif;margin:16px 0 22px}header p{font-size:18px;color:#646772}.gallery{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:32px}article{border-top:1px solid #e5e7ee}.preview{display:block;position:relative;height:380px;overflow:hidden;background:#fff}.preview iframe{position:absolute;left:0;top:0;border:0;width:200%;height:1100px;transform:scale(.5);transform-origin:top left;pointer-events:none}.caption{padding:16px 0 24px}.caption h2{font:500 23px/1.15 -apple-system,BlinkMacSystemFont,sans-serif;margin:8px 0}.caption p{color:#646772;margin:8px 0}.caption>a{font-size:13px}a{color:inherit;text-underline-offset:4px}h2 a{text-decoration:none}a:focus-visible{outline:3px solid #4263eb;outline-offset:5px}footer{font-size:13px;color:#646772;margin-top:30px}@media(max-width:720px){main{padding:28px 16px}.gallery{grid-template-columns:1fr}.preview{height:340px}}</style>
<main><header><span>Notebook / Живые научные примеры</span><h1>Семь способов увидеть связь.</h1><p>Живые модели на JavaScript и SVG. Открой пример и измени то, что видишь.</p></header><div class="gallery">${cards}</div><footer>Оригинальные учебные реализации по выбранным визуальным референсам, не копии статей. Все сцены работают без сети. Здесь состояние живёт до перезагрузки; в Notebook оно сохраняется при действии человека.</footer></main></html>`);
console.log(resolve(directory,'index.html'));

import {readFile,readdir} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';

const root=new URL('../assets/science/',import.meta.url);
export const scienceExamples=JSON.parse(await readFile(new URL('examples.json',root),'utf8'));
export async function loadScienceExample(id) {
  const example=scienceExamples.find(e=>e.id===id);
  if(!example)throw new Error(`Unknown science example: ${id}. Choose ${scienceExamples.map(e=>e.id).join(', ')}`);
  if(example.format==='program')throw new Error('This example uses offline assets; prepare program with example:'+id+' first');
  const read=name=>readFile(new URL(name,root),'utf8');
  const [html,css,models,runtime,scene]=await Promise.all([read(`${id}.html`),read('common.css'),read('models.js'),read('runtime.js'),read(`${id}.js`)]);
  const source=`<p class="source">Собственная учебная реализация Notebook. Визуальный референс: <a href="${example.source}" target="_blank" rel="noopener noreferrer">${example.author}</a>. Код и изображения оригинала не включены.</p>`;
  return {title:example.title,html:html.replace('<!-- source -->',source),css,javaScript:[models,runtime,scene].join('\n'),width:960,height:960};
}

/** Asset-backed recipes use the same author-only compiler and package path. */
export async function buildScienceProgram(id) {
  const example=scienceExamples.find(e=>e.id===id);
  if(!example||example.format!=='program')throw new Error('Choose an asset-backed science program: '+scienceExamples.filter(e=>e.format==='program').map(e=>e.id).join(', '));
  const directory=fileURLToPath(new URL('../../../',import.meta.url));
  const {buildProgram}=await import('./program-build.mjs');
  if(id==='wave')return buildProgram({directory,entry:'skills/notebook/assets/science/wave/main.ts',html:'skills/notebook/assets/science/wave/view.html',workers:{wave:'skills/notebook/assets/science/wave/solver.ts'},assets:['skills/notebook/assets/science/wave/provenance.json','skills/notebook/assets/science/wave/recording-input.json','skills/notebook/assets/science/wave/generate.py','skills/notebook/assets/science/wave/sonification.wav']});
  if(id==='gears')return buildProgram({directory,entry:'skills/notebook/assets/science/gears/main.ts',html:'skills/notebook/assets/science/gears/view.html',assets:['node_modules/three/LICENSE']});
  const font='node_modules/@mathjax/mathjax-newcm-font';
  const dynamic=(await readdir(new URL('../../../'+font+'/svg/dynamic/',import.meta.url))).filter(name=>name.endsWith('.js')).sort();
  const assets=['node_modules/mathjax/tex-svg-nofont.js','node_modules/mathjax/a11y/assistive-mml.js',
    'node_modules/mathjax/LICENSE',font+'/svg.js',font+'/package.json',...dynamic.map(name=>font+'/svg/dynamic/'+name)];
  const visited=new Set();
  async function licenses(name) {
    if(visited.has(name))return;visited.add(name);
    const folder='node_modules/'+name;
    const pkg=JSON.parse(await readFile(new URL('../../../'+folder+'/package.json',import.meta.url),'utf8'));
    for(const file of await readdir(new URL('../../../'+folder+'/',import.meta.url)))if(/^licen[sc]e(?:[.-]|$)/i.test(file))assets.push(folder+'/'+file);
    for(const dependency of Object.keys(pkg.dependencies??{}))await licenses(dependency);
  }
  await licenses('@observablehq/plot');
  return buildProgram({directory,entry:'skills/notebook/assets/science/signal/main.ts',html:'skills/notebook/assets/science/signal/view.html',assets});
}

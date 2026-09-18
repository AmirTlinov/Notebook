import {readFile} from 'node:fs/promises';

const root=new URL('../assets/science/',import.meta.url);
export const scienceExamples=JSON.parse(await readFile(new URL('examples.json',root),'utf8'));
export async function loadScienceExample(id) {
  const example=scienceExamples.find(e=>e.id===id);
  if(!example)throw new Error(`Unknown science example: ${id}. Choose ${scienceExamples.map(e=>e.id).join(', ')}`);
  const read=name=>readFile(new URL(name,root),'utf8');
  const [html,css,models,runtime,scene]=await Promise.all([read(`${id}.html`),read('common.css'),read('models.js'),read('runtime.js'),read(`${id}.js`)]);
  const source=`<p class="source">Собственная учебная реализация Notebook. Визуальный референс: <a href="${example.source}" target="_blank" rel="noopener noreferrer">${example.author}</a>. Код и изображения оригинала не включены.</p>`;
  return {title:example.title,html:html.replace('<!-- source -->',source),css,javaScript:[models,runtime,scene].join('\n'),width:960,height:960};
}

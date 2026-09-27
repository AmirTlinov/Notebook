// Run this async body with notebook_execute(start) on the isolated paired owner.
const scene = await nb.board(args?.boardID ? {id:args.boardID} : {});
if (!scene.data?.header || !scene.data.boardID) throw Error('An addressed board is required');
const boardID = scene.data.boardID;
const documentID = await nb.id('latex-control-document');
const title = args?.title ?? 'Notebook canonical control';

// A small real vector PDF resource, not HTML, a data URL or a TeX conversion.
// Its ASCII byte offsets equal JavaScript string offsets.
function chartPDF() {
  const drawing = '0.12 0.24 0.42 RG 2 w 30 30 m 290 30 l 290 150 l S\n'
    + '0.18 0.48 0.8 RG 3 w 30 70 m 90 140 160 10 220 90 c 250 130 275 90 290 110 c S\n'
    + 'BT /F1 12 Tf 34 160 Td (A vector resource from figures/control.pdf) Tj ET\n';
  const objects = [
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 320 180] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>',
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
    '<< /Length '+drawing.length+' >>\nstream\n'+drawing+'endstream'
  ];
  let pdf = '%PDF-1.4\n'; const offsets = [0];
  for (let index=0; index<objects.length; index++) {
    offsets.push(pdf.length); pdf += (index+1)+' 0 obj\n'+objects[index]+'\nendobj\n';
  }
  const start = pdf.length;
  pdf += 'xref\n0 '+offsets.length+'\n0000000000 65535 f \n';
  for (const offset of offsets.slice(1)) pdf += String(offset).padStart(10,'0')+' 00000 n \n';
  return pdf+'trailer\n<< /Size '+offsets.length+' /Root 1 0 R >>\nstartxref\n'+start+'\n%%EOF\n';
}
const tex = String.raw;
const files = [
  {id:'main',path:'main.tex',source:tex`\documentclass{notebook-control}
\usepackage{fontspec}
\setmainfont{Libertinus Serif}
\usepackage[paperwidth=540bp,paperheight=720bp,margin=42bp]{geometry}
\usepackage{graphicx}
\usepackage{multicol}
\usepackage{hyperref}
\usepackage{notebook}
\usepackage{control}
\begin{document}
\input{chapters/introduction}
\include{chapters/methods}
\include{chapters/continuation}
\include{chapters/landscape}
\include{chapters/distant}
\bibliographystyle{plain}
\bibliography{references}
\end{document}
`},
  {id:'class',path:'notebook-control.cls',source:tex`\NeedsTeXFormat{LaTeX2e}
\ProvidesClass{notebook-control}[2026/09/26 File document acceptance]
\LoadClass[11pt]{article}
`},
  {id:'style',path:'control.sty',source:tex`\NeedsTeXFormat{LaTeX2e}
\ProvidesPackage{control}[2026/09/26 Local document style]
\setlength{\parindent}{0pt}
\setlength{\parskip}{6pt}
\newcommand{\ControlTerm}[1]{\textbf{#1}}
`},
  {id:'introduction',path:'chapters/introduction.tex',source:tex`\section{Начало проверки}\label{acceptance-contents}
\hyperref[acceptance-distant]{К дальней главе}\quad
\hyperref[fig:vector]{К векторному рисунку}

Это обычный исходный файл. Сохранение, получение на iPad и фактический показ
проверяются отдельно. Здесь человек добавляет контрольную строку через нативный
редактор; адрес файла остаётся прежним после закрытия и повторного открытия.

\ControlTerm{Формула:} $x(t)=A\sin(2\pi t)$, а энергия $E=\frac12 A^2$.
Ссылка на живой рисунок~\ref{fig:oscillator} и источник~\cite{control} должна
сохраниться после правки соседнего абзаца.

\tableofcontents
`},
  {id:'methods',path:'chapters/methods.tex',source:tex`\section{Файлы, рисунки и колонки}\label{sec:methods}
\begin{figure}[htbp]
\centering
\includegraphics[width=.75\linewidth]{figures/control.pdf}
\caption{Самостоятельный векторный PDF-ресурс}\label{fig:vector}
\end{figure}
\begin{multicols}{2}
\ControlTerm{Первый столбец.} Текст принадлежит LaTeX. Изображение читается по
относительному пути; ресурс не получает доступа к файловой системе устройства.
\columnbreak
\ControlTerm{Второй столбец.} Диагностика и SyncTeX возвращают этот файл и строку.
Переименование включения и файла выполняется одной файловой транзакцией.
\end{multicols}
\begin{figure}[htbp]
\centering
\NotebookInteractive[id=oscillator,width=\linewidth,height=240bp]{programs/oscillator}
\caption{Амплитуда сохраняется ползунком}\label{fig:oscillator}
\end{figure}
`},
  {id:'continuation',path:'chapters/continuation.tex',source:tex`\section{Продолжение одного исполнителя}\label{sec:continuation}
Следующая область находится в обычном вертикальном потоке, не внутри figure
или minipage. Полосы 1--6 отмечают разные участки одного viewport.
\NotebookInteractive[id=continuation,width=\linewidth,height=1200bp,breakable]{programs/oscillator}
После перелистывания состояние первого ползунка и независимое состояние этого
экземпляра должны сохраниться. Они используют один исходник, но разные ID.
`},
  {id:'landscape',path:'chapters/landscape.tex',source:tex`\clearpage
\setlength{\paperwidth}{720bp}
\setlength{\paperheight}{540bp}
\newgeometry{margin=42bp}
\special{papersize=720bp,540bp}
\section{Индивидуальный размер страницы}\label{sec:landscape}
Этот лист имеет размер 720 на 540 bp; остальные листы — 540 на 720 bp.
Размеры задаёт исходник, а приложение читает их из PDF.
\[\int_0^1 t^2\,dt=\frac13\]
\includegraphics[width=260bp]{figures/control.pdf}
\clearpage
`},
  {id:'distant',path:'chapters/distant.tex',source:tex`\setlength{\paperwidth}{540bp}
\setlength{\paperheight}{720bp}
\newgeometry{margin=42bp}
\special{papersize=540bp,720bp}
\section{Дальняя глава}\label{acceptance-distant}
\hyperref[acceptance-contents]{К оглавлению}

Последняя глава — отдельный файл. Её адресная правка не переписывает введение,
программу или её состояние. Ссылка на рисунок~\ref{fig:vector} возвращает к
настоящему назначению PDF, а не к предполагаемому номеру страницы.
`},
  {id:'bibliography',path:'references.bib',source:tex`@misc{control,
  author = {Notebook},
  title = {A deterministic file-document acceptance fixture},
  year = {2026},
  note = {Local bibliography resource}
}
`},
  {id:'vector-image',path:'figures/control.pdf',source:chartPDF()},
  {id:'oscillator-manifest',path:'programs/oscillator/program.json',source:JSON.stringify({
    html:'index.html',css:'style.css',javaScript:'main.js',module:false,initialState:{amplitude:1},dependencies:[]})},
  {id:'oscillator-html',path:'programs/oscillator/index.html',source:'<section class="control"><label>Амплитуда <input id="amplitude" aria-label="Амплитуда" type="range" min="0.2" max="2" step="0.1" value="1"></label><output id="value"></output><svg id="wave" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 480 1200" preserveAspectRatio="none" aria-label="Шесть участков одного viewport"></svg></section>'},
  {id:'oscillator-css',path:'programs/oscillator/style.css',source:'html,body{margin:0;height:100%;font:16px system-ui;color:#15395a;background:#f2f7fb}.control{box-sizing:border-box;height:100vh;padding:12px}label{display:flex;gap:12px;align-items:center}input{flex:1;min-width:80px}output{display:block;margin:6px 0}svg{display:block;width:100%;height:calc(100% - 70px)}'},
  {id:'oscillator-js',path:'programs/oscillator/main.js',source:`const slider=document.getElementById('amplitude'),value=document.getElementById('value'),wave=document.getElementById('wave');
function draw(state){
  const amplitude=Number(state?.amplitude??1);slider.value=String(amplitude);value.textContent='A = '+amplitude.toFixed(1);
  let content='';
  for(let band=0;band<6;band++){
    const top=band*200;
    content+='<rect x="0" y="'+top+'" width="480" height="200" fill="'+(band%2?'#e4edf7':'#f4f8fc')+'"/>';
    content+='<text x="12" y="'+(top+28)+'" font-size="22" fill="#15395a">Viewport '+(band+1)+' / 6</text>';
    let path='';for(let x=0;x<=480;x+=4){const y=top+112-Math.sin(x/480*Math.PI*4)*amplitude*25;path+=(x?'L':'M')+x+','+y.toFixed(2);}
    content+='<path d="'+path+'" fill="none" stroke="#286ab1" stroke-width="3"/>';
  }
  wave.innerHTML=content;
}
slider.addEventListener('input',()=>{const state={amplitude:Number(slider.value)};notebook.commit(state);draw(state);});
addEventListener('notebookstate',()=>draw(notebook.state));
notebook.exportFrame(async({format,state})=>{if(format!=='raster')throw Error('program_export_unavailable');draw(state);return null;});
notebook.ready(Promise.resolve().then(()=>draw(notebook.state)));
`}
];
const sourceCharacters = files.reduce((total,file)=>total+file.source.length,0);
if (sourceCharacters>50000) throw Error('The acceptance control must remain bounded');
const saved = await nb.transaction('latex-control-create', {
  summary:'Контрольный LaTeX-документ: файлы, ссылки, ресурсы и живые рисунки',base:scene.basis,
  operations:[{kind:'createDocument',target:{kind:'board',id:boardID},id:documentID,
    values:{title,center:args?.center??{tileX:0,tileY:0,localX:0,localY:0},entrypoint:'main.tex',files}}]
});
const directory = await nb.document({id:documentID});
const first = await nb.document({id:documentID,fileID:'introduction'});
const distant = await nb.document({id:documentID,fileID:'distant'});
if (directory.data.files.length!==files.length || first.data?.file.source!==files.find(f=>f.id==='introduction').source
  || distant.data?.file.source!==files.find(f=>f.id==='distant').source) throw Error('Addressed native source differs from the saved files');
await emit({documentID,boardID,title,fileCount:files.length,sourceCharacters,actionID:saved.actionID,
  editableFileID:'introduction',entrypoint:'main.tex',programInstances:['oscillator','continuation'],
  paperSizesBP:[{width:540,height:720},{width:720,height:540}],addressedReadConfirmed:true,
  outwardLink:'К дальней главе',returningLink:'К оглавлению'});

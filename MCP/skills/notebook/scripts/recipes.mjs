import {createHash, randomUUID} from 'node:crypto';

const tile = (132 / 2.54 / 2) * 256;
const ink = {red:0.16, green:0.22, blue:0.31};
const blue = {red:0.18, green:0.43, blue:0.82};
const escape = value => String(value).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const finite = (n, label) => { if (!Number.isFinite(n)) throw new Error(`${label} must be finite`); return n; };
const positive = (n, label) => { if (finite(n,label)<=0) throw new Error(`${label} must be positive`); return n; };
function id(namespace, key) {
  const bytes=createHash('sha256').update(`${namespace}\0${key}`).digest();
  bytes[6]=(bytes[6]&15)|80; bytes[8]=(bytes[8]&63)|128;
  const hex=bytes.subarray(0,16).toString('hex');
  return `${hex.slice(0,8)}-${hex.slice(8,12)}-${hex.slice(12,16)}-${hex.slice(16,20)}-${hex.slice(20)}`;
}
function wrap(value, width=240, font=18) {
  const columns=Math.max(5,Math.floor((width-36)/(font*0.6))), lines=[];
  for (const paragraph of String(value).split('\n')) {
    let line='';
    for (let word of paragraph.split(/\s+/).filter(Boolean)) {
      if (line && line.length+1+word.length>columns) { lines.push(line); line=''; }
      while(word.length>columns) { if(line) {lines.push(line);line='';} lines.push(word.slice(0,columns));word=word.slice(columns); }
      if(word) line+=(line?' ':'')+word;
    }
    lines.push(line);
  }
  return {label:lines.join('\n'),height:Math.max(64,lines.length*font*1.4+30)};
}
function node(namespace, value, width=240) {
  if(!value.id || typeof value.label!=='string') throw new Error('Each node needs an id and label');
  const text=wrap(value.label,width);
  return {id:id(namespace,value.id),kind:'graphic',source:'',frame:{x:0,y:0,width,height:text.height},
    graphic:{shape:value.shape??'rectangle',style:{stroke:ink,strokeWidth:1.6,fill:{red:0.96,green:0.97,blue:0.99}},
      label:text.label,representation:'geometry',visible:true,sourceInkIDs:[]}};
}
function edge(namespace, key, from, to, label='', arrow=true) {
  const a=from.frame,b=to.frame,right=b.x>=a.x+a.width;
  const p={x:right?a.x+a.width:a.x,y:a.y+a.height/2};
  const q={x:right?b.x:b.x+b.width,y:b.y+b.height/2};
  const x=Math.min(p.x,q.x),y=Math.min(p.y,q.y);
  const endpoint=(point,element,xAnchor)=>({point:{x:point.x-x,y:point.y-y},binding:{elementID:element.id,
    normalizedAnchor:{x:xAnchor,y:0.5},isExact:true,isPrecise:true}});
  return {id:id(namespace,key),kind:'graphic',source:'',frame:{x,y,width:Math.max(1,Math.abs(q.x-p.x)),height:Math.max(1,Math.abs(q.y-p.y))},
    graphic:{shape:'connector',style:{stroke:blue,strokeWidth:1.8},label,representation:'geometry',visible:true,sourceInkIDs:[],
      connection:{start:endpoint(p,from,right?1:0),end:endpoint(q,to,right?0:1),bend:right?0:-80,routing:right?'straight':'curved',
        startArrowhead:'none',endArrowhead:arrow?'arrow':'none',labelPosition:0.5}}};
}
function mindmap(input, namespace) {
  const elements=[],ids=Object.create(null),seen=new Set(),gap=input.gap??32,width=input.nodeWidth??220;
  positive(gap,'gap');positive(width,'nodeWidth');
  function measure(value,depth=0) {
    if(depth>100 || seen.size>=250) throw new Error('Mind map is limited to 250 nodes and 100 levels');
    if(seen.has(value.id)) throw new Error(`Duplicate node id: ${value.id}`);
    seen.add(value.id);
    const own=node(namespace,value,width),children=(value.children??[]).map(v=>measure(v,depth+1));
    ids[value.id]=own.id;
    return {own,children,height:Math.max(own.frame.height,children.reduce((sum,c)=>sum+c.height,0)+Math.max(0,children.length-1)*gap)};
  }
  const tree=measure(input.tree);
  function place(branch,x,y) {
    branch.own.frame.x=x;branch.own.frame.y=y+(branch.height-branch.own.frame.height)/2;
    elements.push(branch.own);
    let cy=y+(branch.height-(branch.children.reduce((s,c)=>s+c.height,0)+Math.max(0,branch.children.length-1)*gap))/2;
    for(const child of branch.children) {
      place(child,x+width+60,cy);cy+=child.height+gap;
      elements.push(edge(namespace,`edge:${branch.own.id}:${child.own.id}`,branch.own,child.own,'',false));
    }
  }
  place(tree,0,0);return {elements,ids};
}
function flow(input,namespace) {
  const values=input.nodes??[],edges=input.edges??[],nodes=new Map(),ids=Object.create(null);
  for(const value of values) {
    if(nodes.has(value.id)) throw new Error(`Duplicate node id: ${value.id}`);
    const element=node(namespace,value,input.nodeWidth??240);nodes.set(value.id,element);ids[value.id]=element.id;
  }
  // A spanning traversal supplies a stable layout; cross-links and feedback remain real edges.
  const levels=new Map(),incoming=new Set(edges.map(e=>e.to));
  for(const e of edges) if(!nodes.has(e.from)||!nodes.has(e.to)) throw new Error(`Unknown edge endpoint: ${e.from} -> ${e.to}`);
  const roots=values.filter(n=>!incoming.has(n.id)).map(n=>n.id);
  for(const root of [...roots,...nodes.keys()]) {
    if(levels.has(root))continue;
    const queue=[[root,0]];levels.set(root,0);
    for(let i=0;i<queue.length;i++) {
      const [key,level]=queue[i];
      for(const e of edges.filter(e=>e.from===key)) if(!levels.has(e.to)) {levels.set(e.to,level+1);queue.push([e.to,level+1]);}
    }
  }
  const bottoms=new Map();
  for(const [key,element] of nodes) {
    const level=levels.get(key);element.frame.x=level*((input.nodeWidth??240)+100);element.frame.y=bottoms.get(level)??0;
    bottoms.set(level,element.frame.y+element.frame.height+40);
  }
  return {ids,elements:[...nodes.values(),...edges.map((e,i)=>edge(namespace,`edge:${i}`,nodes.get(e.from),nodes.get(e.to),e.label??''))]};
}
function compare(input,namespace) {
  const width=input.columnWidth??300,ids=Object.create(null);positive(width,'columnWidth');
  const elements=(input.columns??[]).map((column,i)=>{
    const key=column.id??`column:${i}`,element=node(namespace,{id:key,label:`${column.title}\n\n${column.body??''}`},width);
    element.frame.x=i*(width+36);ids[key]=element.id;return element;
  });
  return {elements,ids};
}
function worldOffset(origin,x,y) {
  const rawX=finite(origin.localX+x,'localX'),rawY=finite(origin.localY+y,'localY');
  const dx=Math.floor(rawX/tile),dy=Math.floor(rawY/tile);
  const result={tileX:origin.tileX+dx,tileY:origin.tileY+dy,localX:rawX-dx*tile,localY:rawY-dy*tile};
  if(!Number.isSafeInteger(result.tileX)||!Number.isSafeInteger(result.tileY)) throw new Error('World tile is outside exact integer range');
  return result;
}
function insert(elements,input) {
  const {target}=input,offset=input.offset??{x:0,y:0};
  if(!['page','board','cover'].includes(target.kind)) throw new Error('Drawing target must be a page, board or cover');
  if(target.kind==='board'&&!input.anchor) throw new Error('Board placement needs an explicit anchor');
  return elements.map(({id,...values})=>{
    const frame={...values.frame,x:values.frame.x+(offset.x??0),y:values.frame.y+(offset.y??0)};
    if(target.kind==='board') values.worldOrigin=worldOffset(input.anchor,frame.x,frame.y);
    return {kind:'insertElement',target,id,values:{...values,frame}};
  });
}
function visual(input,namespace) {
  const image=input.image;
  if(!/^data:image\/(png|jpeg|svg\+xml);base64,[A-Za-z0-9+/=]+$/.test(image?.dataURL??'')) throw new Error('Expected an embedded PNG, JPEG or SVG');
  const width=positive(input.width??720,'width'),height=width*positive(image.height,'image.height')/positive(image.width,'image.width');
  const source=`<figure><img src="${image.dataURL}" alt="${escape(input.alt??input.caption??'')}" width="${width}" height="${height}" style="max-width:100%;height:auto"/>${input.caption?`<figcaption>${escape(input.caption)}</figcaption>`:''}</figure>`;
  const imageID=id(namespace,'image');
  return {ids:{image:imageID},elements:[{id:imageID,kind:'markdown',source,frame:{x:0,y:0,width,height:height+(input.caption?60:0)}}]};
}
function animation(input,namespace) {
  let program;
  if(input.programPackage!==undefined) {
    if(!/^[a-f0-9]{64}$/.test(input.programPackage))throw new Error('Animation needs a staged package SHA-256');
    if(['html','css','javaScript'].some(key=>input[key]))throw new Error('Choose a package or inline sources, not both');
    program={html:'',css:'',javaScript:'',programPackage:input.programPackage};
  } else {
    if(typeof input.html!=='string'||!input.html.trim())throw new Error('Animation needs an HTML/SVG fragment');
    if(typeof input.javaScript!=='string'||!input.javaScript.trim())throw new Error('Animation needs JavaScript for drawing and controls');
    program={html:input.html,css:input.css??'',javaScript:input.javaScript};
  }
  const animationID=id(namespace,'animation'),height=positive(input.height??560,'height');
  const ids={animation:animationID};
  if(input.target.kind==='document') {
    if(height<48||height>2048)throw new Error('Document animation height must be 48–2048');
    return {ids,operations:[{kind:'insertBlock',target:input.target,id:animationID,
      values:{kind:'interactive',...program,initialState:input.initialState??{},height,...(input.afterID?{afterID:input.afterID}:{})}}]};
  }
  return {ids,operations:insert([{id:animationID,kind:'web',source:input.programPackage?'':input.title??'',...program,
    state:input.initialState??{},frame:{x:0,y:0,width:positive(input.width??760,'width'),height}}],input)};
}
function document(input,namespace) {
  const blocks=[],ids=Object.create(null);
  if(input.title) {ids.title=id(namespace,'title');blocks.push({id:ids.title,kind:'markdown',source:`# ${input.title}${input.subtitle?`\n\n${input.subtitle}`:''}`});}
  for(const [i,section] of (input.sections??[]).entries()) {
    const key=section.id??`section:${i}`;
    if(ids[key])throw new Error(`Duplicate section id: ${key}`);
    ids[key]=id(namespace,key);
    blocks.push({id:ids[key],kind:section.kind??'markdown',source:`${section.heading?`## ${section.heading}\n\n`:''}${section.body??''}`});
  }
  if(!blocks.length)throw new Error('Document needs content');
  if(input.target.kind==='document') {
    let afterID=input.afterID;
    const operations=blocks.map(({id,...values})=>{const op={kind:'insertBlock',target:input.target,id,values:{...values,...(afterID?{afterID}:{})}};afterID=id;return op;});
    return {ids,operations};
  }
  if(input.target.kind!=='board'||!input.anchor)throw new Error('New document needs a board target and anchor');
  ids.document=id(namespace,'document');
  return {ids,operations:[{kind:'createDocument',target:input.target,id:ids.document,
    values:{title:input.title??'Документ',center:input.anchor,paperSize:input.paperSize??'a4',blocks,
      ...(input.preamble?{preamble:input.preamble}:{})}}]};
}

export const applyCode=`const snapshot = args.base ? null : await nb.readMany({queries: args.queries});
const action = await nb.transaction(args.key, {
  base: args.base ?? snapshot.basis,
  summary: args.summary,
  additionalOwners: [args.target],
  ...(args.contextID ? {contextID: args.contextID} : {}),
  operations: args.operations
});
return {action, ids: args.ids};`;

export function makeRecipe(name,input,runID=randomUUID()) {
  if(name==='point') {
    const step={duration:input.duration??3,transition:0.2};
    if(input.references?.length)step.attention=input.references;
    else {
      if(!input.bounds)throw new Error('Pointing needs references or board-world bounds');
      const shape=input.shape==='ring'?'<ellipse cx="120" cy="70" rx="110" ry="60"/>':'<path d="M24 108 Q120 112 216 32 M190 35 L216 32 L208 56"/>';
      step.svg=`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 240 140"><g fill="none" stroke="#2E7DFF" stroke-width="3" stroke-linecap="round" stroke-linejoin="round">${shape}</g></svg>`;
      step.bounds=input.bounds;
    }
    return {op:'start',api_version:2,language:'javascript',run_id:runID,
      code:'const {view} = (await nb.presentation({})).data; return await nb.present(args.key, {view, steps:args.steps});',
      args:{key:input.key??'point',steps:[step]}};
  }
  if(!input.target?.id)throw new Error('Supply the chosen target');
  let prepared;
  if(name==='document')prepared=document(input,runID);
  else if(name==='animation')prepared=animation(input,runID);
  else if(name==='sketch') {
    if(!['page','board','cover'].includes(input.target.kind))throw new Error('Sketch needs a page, board or cover');
    if(input.target.kind==='board'&&!input.anchor)throw new Error('Board ink needs an anchor');
    const ids=Object.create(null),operations=(input.strokes??[]).map((stroke,i)=>{
      const key=stroke.id??`stroke:${i}`;ids[key]=id(runID,key);
      return {kind:'appendInkStroke',target:input.target,id:ids[key],values:{points:stroke.points,width:stroke.width??2,
        color:stroke.color??ink,...(input.target.kind==='board'?{worldOrigin:input.anchor}:{})}};
    });
    prepared={ids,operations};
  }
  else {
    const build={mindmap,flow,compare,visual}[name];
    if(!build)throw new Error(`Unknown recipe: ${name}`);
    prepared=build(input,runID);prepared.operations=insert(prepared.elements,input);
  }
  if(!prepared.operations.length||prepared.operations.length>512)throw new Error('One recipe needs 1–512 operations');
  const query={page:'pageHeader',document:'documentHeader',board:'boardContentRevision',cover:'itemHeader'}[input.target.kind];
  if(!query)throw new Error('Unsupported target');
  const queries=[{kind:query,id:input.target.id}];
  if(prepared.operations.some(op=>op.kind==='createDocument'))queries.push({kind:'workspaceHeader'});
  const args={target:input.target,key:input.key??name,summary:input.summary??`Notebook: ${name}`,queries,
    operations:prepared.operations,ids:prepared.ids,...(input.base?{base:input.base}:{}),...(input.contextID?{contextID:input.contextID}:{})};
  if(Buffer.byteLength(JSON.stringify(args))>1048576)throw new Error('Recipe exceeds the 1 MiB SDK argument limit; use a smaller image or a smaller composition');
  for(const op of args.operations)for(const field of ['source','html','css','javaScript']) {
    if((op.values[field]?.length??0)>1_000_000)throw new Error(`${field} exceeds Notebook source limit`);
  }
  return {op:'start',api_version:2,language:'javascript',run_id:runID,code:applyCode,args};
}

export function chartSVG(input) {
  const width=positive(input.width??720,'width'),height=positive(input.height??420,'height');
  if(width<240||height<180)throw new Error('Chart needs at least 240 × 180');
  const series=input.series??[],points=series.flatMap(s=>s.points??[]);
  if(!points.length)throw new Error('Chart needs data');
  for(const p of points){finite(p[0],'x');finite(p[1],'y');}
  let minX=Math.min(...points.map(p=>p[0])),maxX=Math.max(...points.map(p=>p[0]));
  let minY=Math.min(...points.map(p=>p[1])),maxY=Math.max(...points.map(p=>p[1]));
  if(minX===maxX){minX-=0.5;maxX+=0.5;}if(minY===maxY){minY-=0.5;maxY+=0.5;}
  const x=v=>64+(v-minX)/(maxX-minX)*(width-96),y=v=>height-64-(v-minY)/(maxY-minY)*(height-136);
  const palette=['#2468b4','#b55730','#328468','#8054a2'];
  const text=(px,py,s,extra='')=>`<text x="${px}" y="${py}" ${extra}>${escape(s)}</text>`;
  let body=text(64,30,input.title??'','font-size="20" font-weight="600"');
  for(let i=0;i<=4;i++) {
    const vx=minX+(maxX-minX)*i/4,vy=minY+(maxY-minY)*i/4;
    body+=`<path d="M64 ${y(vy)} H${width-32}" stroke="#dce2e8"/>`;
    body+=text(54,y(vy)+5,Number(vy.toPrecision(4)),'text-anchor="end"')+text(x(vx),height-42,Number(vx.toPrecision(4)),'text-anchor="middle"');
  }
  series.forEach((s,i)=>{
    const color=palette[i%palette.length],coords=s.points.map(p=>`${x(p[0])},${y(p[1])}`).join(' ');
    body+=`<polyline points="${coords}" fill="none" stroke="${color}" stroke-width="2.5"/>`;
    body+=s.points.map(p=>`<circle cx="${x(p[0])}" cy="${y(p[1])}" r="3.5" fill="${color}"/>`).join('');
    body+=text(64+i*160,53,s.label??`Ряд ${i+1}`,`fill="${color}"`);
  });
  body+=text(width-32,height-14,input.xLabel??'','text-anchor="end"');
  if(input.yLabel)body+=text(16,height/2,input.yLabel,`text-anchor="middle" transform="rotate(-90 16 ${height/2})"`);
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${width} ${height}"><title>${escape(input.title??'График')}</title><desc>${escape(input.description??series.map((s,i)=>`${s.label??`Ряд ${i+1}`}: ${s.points.length} точек`).join('; '))}</desc><rect width="100%" height="100%" fill="white"/><g font-family="Arial, sans-serif" font-size="13" fill="#273747">${body}</g></svg>`;
}

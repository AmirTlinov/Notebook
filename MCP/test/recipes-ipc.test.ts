import assert from 'node:assert/strict';
import test from 'node:test';
import {mkdtemp,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {randomUUID} from 'node:crypto';
import {marked} from 'marked';
import {NotebookStore} from './native-client.js';
import {writeFixture,fixtureSocket,stopFixture,pageID,rootBoardID} from './fixture.js';
const {makeRecipe,chartSVG}=await import(new URL('../skills/notebook/scripts/recipes.mjs',import.meta.url).href);
const AsyncFunction=Object.getPrototypeOf(async function(){}).constructor;

test('recipes commit through native admission: bound diagram, SVG, document, native ink and animation',async()=>{
  const root=await mkdtemp(join(tmpdir(),'notebook-recipes-ipc-'));
  try {
    await writeFixture(root);const store=new NotebookStore(fixtureSocket(root));
    const read=async(query:object)=>(await store.command<any[]>({command:'read',readSnapshots:true,queries:[query]}))[0];
    const nb={
      readMany:async({queries}:{queries:object[]})=>{
        const cuts=await store.command<any[]>({command:'read',readSnapshots:true,queries});
        const owners=new Map();for(const cut of cuts) for(const owner of cut.basis.owners)owners.set(JSON.stringify(owner.target),owner);
        return {basis:{workspaceID:cuts[0].basis.workspaceID,owners:[...owners.values()]}};
      },
      transaction:async(_key:string,{base,...input}:any)=>{
        const action={id:randomUUID(),...input,references:[],expected:base.owners};
        const admission=await store.command<any>({command:'admitAction',action});
        const prepared=await store.command<any>({command:'prepareAction',actionID:action.id,fingerprint:admission.fingerprint});
        for(const i of prepared.markdownOperations)prepared.action.operations[i].values.html=marked.parse(prepared.action.operations[i].values.source,{async:false,gfm:true});
        return store.command<any>({command:'commitAction',action:prepared.action,fingerprint:admission.fingerprint});
      },
    };
    async function run(name:string,input:object) {
      const request=makeRecipe(name,input,randomUUID());
      return new AsyncFunction('nb','args',request.code)(nb,request.args);
    }
    const target={kind:'page',id:pageID};
    const graph=await run('mindmap',{target,tree:{id:'root',label:'Вопрос',children:[{id:'a',label:'Наблюдение'},{id:'b',label:'Объяснение'}]}});
    assert.equal(graph.action.publication.saved,'confirmed');
    const actual=await read({kind:'page',id:pageID});
    const nodes=actual.data.elements.filter((e:any)=>e.graphic?.shape!=='connector');
    assert.equal(nodes.length,3);
    const connector=actual.data.elements.find((e:any)=>e.graphic?.shape==='connector');
    assert.ok(nodes.some((n:any)=>n.id===connector.graphic.connection.start.binding.elementID));
    const svg=chartSVG({title:'Источник сохраняется',series:[{points:[[0,0],[1,2]]}]});
    const picture=await run('visual',{target:{kind:'board',id:rootBoardID},anchor:{tileX:0,tileY:0,localX:400,localY:500},
      image:{dataURL:'data:image/svg+xml;base64,'+Buffer.from(svg).toString('base64'),width:720,height:420},caption:'SVG на доске'});
    assert.equal(picture.action.publication.saved,'confirmed');
    const persisted=await read({kind:'boardElement',id:rootBoardID,elementID:picture.ids.image});
    assert.match(JSON.stringify(persisted.data),/data:image\/svg\+xml;base64,/);
    assert.match(JSON.stringify(persisted.data),/SVG на доске/);
    const source=String.raw`\documentclass{article}
\usepackage{notebook}
\begin{document}
Одна очередь записи.
\end{document}`;
    const doc=await run('document',{target:{kind:'board',id:rootBoardID},anchor:{tileX:0,tileY:0,localX:1200,localY:500},
      title:'Технический дизайн',source});
    assert.equal(doc.action.publication.saved,'confirmed');
    assert.equal((await read({kind:'document',id:doc.ids.document})).data.files.length,1);
    const main=await read({kind:'documentFile',id:doc.ids.document,fileID:doc.ids['main.tex']});
    const location=main.data.file.source.indexOf(String.raw`\end{document}`);
    await run('document',{target:{kind:'document',id:doc.ids.document},edit:{fileID:main.data.file.id,
      expectedVersion:main.data.sourceVersion,range:{location,length:0},expectedText:'',source:'Продолжение человека и агента.\n'}});
    const updated=await read({kind:'documentFile',id:doc.ids.document,fileID:main.data.file.id});
    assert.match(updated.data.file.source,/Продолжение человека и агента/);
    const program={html:'<svg viewBox="0 0 100 100"><circle id="point" cx="50" cy="50" r="5"/></svg>',
      css:'svg{width:100%}',javaScript:'notebook.ready(Promise.resolve());',initialState:{phase:0.25}};
    const animation=await run('animation',{...program,target:{kind:'board',id:rootBoardID},anchor:{tileX:0,tileY:0,localX:400,localY:1200}});
    assert.equal(animation.action.publication.saved,'confirmed');
    const scene=(await read({kind:'boardElement',id:rootBoardID,elementID:animation.ids.animation})).data;
    assert.equal(scene.kind,'web');assert.equal(scene.html,program.html);assert.deepEqual(scene.state,program.initialState);
    const prepared=await run('animation',{...program,target:{kind:'document',id:doc.ids.document},
      edit:{fileID:updated.data.file.id,expectedVersion:updated.data.sourceVersion,
        range:{location:updated.data.file.source.indexOf(String.raw`\end{document}`),length:0},expectedText:''}});
    assert.equal(prepared.action.publication.saved,'confirmed');
    const withAnimation=(await read({kind:'document',id:doc.ids.document})).data.files;
    assert.equal(withAnimation.find((value:any)=>value.path===prepared.ids.programPath+'/main.js').source,program.javaScript);
    assert.deepEqual(JSON.parse(withAnimation.find((value:any)=>value.path===prepared.ids.programPath+'/program.json').source).initialState,program.initialState);
    const ink=await run('sketch',{target,strokes:[{points:[{x:10,y:10},{x:30,y:40},{x:60,y:15}]}]});
    assert.equal(ink.action.publication.saved,'confirmed');
    const undo=await store.command<any>({command:'undo',actionID:graph.action.actionID});
    assert.equal(undo.publication.saved,'confirmed');
    assert.equal((await read({kind:'page',id:pageID})).data.elements.length,0);
  } finally {await stopFixture(root);await rm(root,{recursive:true,force:true});}
});

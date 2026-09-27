import assert from 'node:assert/strict';
import test from 'node:test';
import {randomUUID} from 'node:crypto';
import {mkdtemp,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {NotebookStore} from './native-client.js';
import {writeFixture,fixtureSocket,stopFixture,rootBoardID} from './fixture.js';
import {readDataSchemas,snapshotSchema,actionResultSchema} from '../src/sdk-results.js';
import {BridgeError} from '../src/bridge.js';

test('file document lifecycle crosses the native owner with independent CAS and atomic undo',async()=>{
  const home=await mkdtemp(join(tmpdir(),'notebook-document-files-'));
  try {
    await writeFixture(home);const store=new NotebookStore(fixtureSocket(home));
    const read=async(kind:keyof typeof readDataSchemas,id?:string,fileID?:string,extra:Record<string,unknown>={})=>{
      const [snapshot]=await store.command<any[]>({command:'read',readSnapshots:true,queries:[{kind,...(id?{id}:{}),...(fileID?{fileID}:{}),...extra}]});
      snapshotSchema(readDataSchemas[kind]).parse(snapshot);return snapshot;
    };
    const apply=async(base:any,operations:unknown[])=>{
      const action={id:randomUUID(),summary:'Файловая правка',references:[],expected:base.owners,operations};
      const admission=await store.command<any>({command:'admitAction',action});
      const prepared=await store.command<any>({command:'prepareAction',actionID:action.id,fingerprint:admission.fingerprint});
      const request={command:'commitAction',action:prepared.action,fingerprint:admission.fingerprint};
      const result=await store.command<any>(request);actionResultSchema.parse(result);
      return {result,request};
    };
    const [creation]=await store.command<any[]>({command:'read',readSnapshots:true,queries:[{kind:'sceneWindow',id:rootBoardID,
      bounds:{anchor:{tileX:0,tileY:0,localX:0,localY:0},region:{x:-100,y:-100,width:400,height:400}},limit:1}]});
    const documentID=randomUUID(),target={kind:'document',id:documentID};
    const main=String.raw`\documentclass{article}
\usepackage{notebook}
\begin{document}
\input{chapters/intro}
\NotebookInteractive[id=oscillator,width=100bp,height=100bp]{programs/oscillator}
\end{document}`;
    const intro=String.raw`\section{Начало}\label{sec:start}`+'\n🧪 first';
    await apply(creation.basis,[{kind:'createDocument',target:{kind:'board',id:rootBoardID},id:documentID,
      values:{title:'Файлы',center:{tileX:0,tileY:0,localX:0,localY:0},entrypoint:'main.tex',files:[
        {id:'main',path:'main.tex',source:main},{id:'intro',path:'chapters/intro.tex',source:intro},{id:'notes',path:'notes.txt',source:'separate'},
        {id:'program-html',path:'programs/oscillator/index.html',source:'<p>Live</p>'},
        {id:'program-config',path:'programs/oscillator/program.json',source:JSON.stringify({html:'index.html',css:null,javaScript:null,module:false,initialState:{amplitude:1}})}]}}]);
    const directory=await read('documentDirectory',documentID);
    assert.equal(directory.data.files.length,5);assert.ok(directory.data.files.every((file:any)=>!Object.hasOwn(file,'source')));
    const a=await read('documentFile',documentID,'intro'),b=await read('documentFile',documentID,'notes');
    const offset=Buffer.byteLength(intro.slice(0,intro.indexOf('🧪')));
    const chunk=await read('documentFileBytes',documentID,'intro',{sourceVersion:a.data.sourceVersion,offset,maxBytes:4});
    assert.equal(Buffer.from(chunk.data.base64,'base64').toString(),'🧪');
    assert.deepEqual(chunk.data.sourceVersion,a.data.sourceVersion);assert.equal(chunk.data.totalBytes,Buffer.byteLength(intro));
    await apply(directory.basis,[{kind:'putDocumentFile',target,id:'appendix',values:{path:'chapters/appendix.tex',source:'New addressed file',expectedVersion:null}}]);
    const appended=await read('documentFile',documentID,'appendix');
    assert.equal(appended.data.file.source,'New addressed file');
    assert.deepEqual((await read('documentFile',documentID,'intro')).data.sourceVersion,a.data.sourceVersion,'Insertion does not renumber or revise sibling files');
    const programQuery={instanceID:'oscillator',programPath:'programs/oscillator'};
    const program=await read('documentProgram',documentID,undefined,programQuery);
    assert.deepEqual(program.data.state,{amplitude:1});assert.equal(program.data.stateVersion,undefined);
    await apply(program.basis,[{kind:'setDocumentProgramState',target,id:programQuery.instanceID,values:{programPath:programQuery.programPath,sourceBasis:program.data.sourceBasis,state:{amplitude:2}}}]);
    const structure=await read('documentStructure',documentID);
    assert.ok(structure.data.entries.some((entry:any)=>entry.fileID==='intro'&&entry.kind==='section'));
    await apply(b.basis,[{kind:'patchDocumentFile',target,id:'notes',values:{expectedVersion:b.data.sourceVersion,
      range:{location:0,length:8},expectedText:'separate',source:'independent'}}]);
    const location=intro.indexOf('first');
    const {result,request}=await apply(a.basis,[{kind:'patchDocumentFile',target,id:'intro',values:{expectedVersion:a.data.sourceVersion,
      range:{location,length:5},expectedText:'first',source:'second'}}]);
    assert.equal((await read('documentFile',documentID,'intro')).data.file.source,intro.replace('first','second'));
    await assert.rejects(read('documentFileBytes',documentID,'intro',{sourceVersion:a.data.sourceVersion,offset:0,maxBytes:64}),error=>error instanceof BridgeError&&error.detail.code==='file_conflict');
    assert.deepEqual(await store.command(request),result,'Retry attaches to the same native receipt');
    const current=await read('documentFile',documentID,'main');
    await assert.rejects(apply(current.basis,[
      {kind:'patchDocumentFile',target,id:'main',values:{expectedVersion:current.data.sourceVersion,range:{location:0,length:0},expectedText:'',source:'% must not save\n'}},
      {kind:'patchDocumentFile',target,id:'intro',values:{expectedVersion:a.data.sourceVersion,range:{location,length:5},expectedText:'first',source:'stale'}}
    ]),error=>error instanceof BridgeError&&error.detail.code==='file_conflict');
    assert.equal((await read('documentFile',documentID,'main')).data.file.source,main,'Late failure rolls back the earlier file edit');
    const undo=await store.command<any>({command:'undo',actionID:result.actionID});actionResultSchema.parse(undo);
    assert.equal((await read('documentFile',documentID,'intro')).data.file.source,intro);
    assert.equal((await read('documentFile',documentID,'notes')).data.file.source,'independent','Undo retains the other file');
    const renamed=await read('documentFile',documentID,'intro');
    await apply(renamed.basis,[{kind:'renameDocumentFile',target,id:'intro',values:{expectedVersion:renamed.data.sourceVersion,path:'chapters/opening.tex'}}]);
    const afterRename=await read('documentFile',documentID,'intro');assert.equal(afterRename.data.file.path,'chapters/opening.tex');
    assert.equal(afterRename.data.file.id,'intro');assert.equal(afterRename.data.file.source,intro);
    const removed=await read('documentFile',documentID,'notes');
    await apply(removed.basis,[{kind:'removeDocumentFile',target,id:'notes',values:{expectedVersion:removed.data.sourceVersion}}]);
    assert.equal((await read('documentFile',documentID,'notes')).data,null);
    const savedProgram=await read('documentProgram',documentID,undefined,programQuery);
    assert.deepEqual(savedProgram.data.state,{amplitude:2});assert.ok(savedProgram.data.stateVersion);
    assert.equal(savedProgram.data.sourceBasis,program.data.sourceBasis,'Text edits, rename and Undo do not change executable identity');
    const executable=await read('documentFile',documentID,'program-html');
    await apply(executable.basis,[{kind:'putDocumentFile',target,id:'program-html',values:{path:executable.data.file.path,source:'<p>New program</p>',expectedVersion:executable.data.sourceVersion}}]);
    assert.notEqual((await read('documentProgram',documentID,undefined,programQuery)).data.sourceBasis,program.data.sourceBasis,'Changing an executable file changes the program basis');
  } finally {await stopFixture(home);await rm(home,{recursive:true,force:true});}
});

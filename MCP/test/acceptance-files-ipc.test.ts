import assert from 'node:assert/strict';
import test from 'node:test';
import {randomUUID} from 'node:crypto';
import {mkdtemp,readFile,rm} from 'node:fs/promises';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import {NotebookStore} from './native-client.js';
import {fixtureSocket,rootBoardID,stopFixture,writeFixture} from './fixture.js';
import {operationSchema} from '../src/actions.js';

const AsyncFunction=Object.getPrototypeOf(async function(){}).constructor;

test('public acceptance scripts author real files through native admission and bind export to an observed edit',async()=>{
  const home=await mkdtemp(join(tmpdir(),'notebook-acceptance-files-'));
  try {
    await writeFixture(home);const store=new NotebookStore(fixtureSocket(home));
    const read=async(query:object)=>(await store.command<any[]>({command:'read',readSnapshots:true,queries:[query]}))[0];
    const transaction=async(_key:string,{base,...input}:any)=>{
      input.operations.forEach((op:unknown)=>operationSchema.parse(op));
      const action={id:randomUUID(),...input,references:[],expected:base.owners};
      const admission=await store.command<any>({command:'admitAction',action});
      const prepared=await store.command<any>({command:'prepareAction',actionID:action.id,fingerprint:admission.fingerprint});
      return store.command<any>({command:'commitAction',action:prepared.action,fingerprint:admission.fingerprint});
    };
    const documentID=randomUUID(),output:any[]=[],exports:any[]=[];
    const nb={
      id:async()=>documentID,
      board:async()=>read({kind:'sceneWindow',id:rootBoardID,limit:1,bounds:{
        anchor:{tileX:0,tileY:0,localX:0,localY:0},region:{x:-100,y:-100,width:400,height:400}}}),
      document:async({id,fileID}:any)=>read({kind:fileID?'documentFile':'documentDirectory',id,...(fileID?{fileID}:{})}),
      read,transaction,
      export:async(key:string,request:unknown)=>{exports.push({key,request});return {status:'queued',jobID:randomUUID()};}
    };
    const source=await readFile(new URL('../../Tests/NotebookDocumentAcceptance/create-control.js',import.meta.url),'utf8');
    await new AsyncFunction('nb','args','emit',source)(nb,{boardID:rootBoardID},(value:any)=>output.push(value));
    const result=output[0];assert.equal(result.documentID,documentID);assert.equal(result.editableFileID,'introduction');
    const doc=(await read({kind:'document',id:documentID})).data;
    assert.equal(doc.format,3);assert.equal(doc.files.length,result.fileCount);assert.ok(result.sourceCharacters<50000);
    const byPath=new Map<string,string>(doc.files.map((file:any)=>[file.path,file.source]));
    assert.match(byPath.get('main.tex')!,/\\bibliography\{references\}/);
    assert.match(byPath.get('chapters/landscape.tex')!,/papersize=720bp,540bp/);
    assert.match(byPath.get('chapters/continuation.tex')!,/height=1200bp,breakable/);
    assert.match(byPath.get('figures/control.pdf')!,/^%PDF-1\.4/);
    assert.ok(byPath.has('notebook-control.cls')&&byPath.has('control.sty')&&byPath.has('references.bib'));
    new Function(byPath.get('programs/oscillator/main.js')!);
    const exportSource=await readFile(new URL('../../Tests/NotebookDocumentAcceptance/export-control.js',import.meta.url),'utf8');
    const exportControl=new AsyncFunction('nb','args','emit',exportSource),emit=(value:any)=>output.push(value);
    await assert.rejects(exportControl(nb,{documentID,marker:'missing-device-edit'},emit),/actual iPad edit/);
    assert.equal(exports.length,0,'A missing marker must not start an export');
    const intro=await nb.document({id:documentID,fileID:'introduction'}),marker='Physical marker';
    await transaction('marker',{base:intro.basis,summary:'Observed source witness',operations:[{
      kind:'patchDocumentFile',target:{kind:'document',id:documentID},id:'introduction',values:{
        expectedVersion:intro.data.sourceVersion,range:{location:intro.data.file.source.length,length:0},expectedText:'',source:'\n'+marker+'\n'}}]});
    await exportControl(nb,{documentID,marker,format:'package'},emit);
    assert.deepEqual(exports.map(value=>value.request),[{documentID,format:'package'}]);
    assert.equal(output.at(-1).uiEditObserved,true);assert.deepEqual(output.at(-1).observedSavedState,{amplitude:1});
  } finally {await stopFixture(home);await rm(home,{recursive:true,force:true});}
});

import assert from 'node:assert/strict';
import test from 'node:test';
import {randomUUID} from 'node:crypto';
import {operationSchema, documentPathSchema} from '../src/actions.js';
import {sdkInputs,sdkOutputs,sdkReference} from '../src/sdk-contracts.js';
import {readDataSchemas} from '../src/sdk-results.js';

const id=randomUUID(),target={kind:'document' as const,id};
const version={stamp:{counter:1,actor:id},human:false,observed:{}};
const source=String.raw`\documentclass{article}
\usepackage[paperwidth=173mm,paperheight=241mm,margin=17mm]{geometry}
\begin{document}
\input{chapters/intro}
\end{document}`;

test('file document public operations keep complete source and file-level CAS without legacy alternatives',()=>{
  const created=operationSchema.parse({kind:'createDocument',target:{kind:'board',id},values:{
    center:{tileX:0,tileY:0,localX:0,localY:0},entrypoint:'main.tex',files:[{id:'main',path:'main.tex',source}]}});
  if(created.kind!=='createDocument')assert.fail('wrong operation');
  assert.equal(created.values.files?.[0]?.source,source);
  for(const template of ['article','report','contract','instruction','book'])
    operationSchema.parse({kind:'createDocument',target:{kind:'board',id},values:{center:{tileX:0,tileY:0,localX:0,localY:0},template}});
  operationSchema.parse({kind:'putDocumentFile',target,id:'intro',values:{path:'chapters/intro.tex',source:'Text',expectedVersion:null}});
  const patch={kind:'patchDocumentFile',target,id:'main',values:{expectedVersion:version,
    range:{location:2,length:2},expectedText:'🧪',source:'x'}};
  assert.deepEqual(operationSchema.parse(patch),patch,'Offsets and exact text are not normalized by the adapter');
  for(const [kind,values] of [['renameDocumentFile',{path:'chapters/start.tex',expectedVersion:version}],
    ['removeDocumentFile',{expectedVersion:version}]])operationSchema.parse({kind,target,id:'intro',values});
  for(const kind of ['insertBlock','updateBlock','removeBlock','reorderBlocks','setBlockState','setPreamble','replaceDocument'])
    assert.equal(operationSchema.safeParse({kind,target,id:'legacy',values:{}}).success,false,kind);
  assert.equal(operationSchema.safeParse({...patch,values:{...patch.values,expectedVersion:null}}).success,false);
});

test('file paths cannot name a device file or leave the bounded document namespace',()=>{
  for(const path of ['main.tex','chapters/one.tex','programs/wave/program.json','assets/chart-1.pdf'])
    assert.equal(documentPathSchema.safeParse(path).success,true,path);
  for(const path of ['', '.', '..','../main.tex','a/../main.tex','a/./main.tex','/main.tex','a//b.tex','a\\b.tex','a/','file:///tmp/a','a\u0000.tex'])
    assert.equal(documentPathSchema.safeParse(path).success,false,path);
});

test('document directory, addressed source, structure and check contracts are distinct',()=>{
  sdkInputs.document!.parse({id,fileID:'main'});
  assert.equal(sdkInputs.document!.safeParse({id,blockID:'main'}).success,false);
  const directory={documentID:id,entrypoint:'main.tex',contentStamp:version.stamp,
    files:[{id:'main',path:'main.tex',byteCount:Buffer.byteLength(source),mimeType:'application/x-tex',sourceVersion:version}]};
  readDataSchemas.documentDirectory.parse(directory);
  readDataSchemas.documentFile.parse({documentID:id,contentStamp:version.stamp,sourceVersion:version,file:{id:'main',path:'main.tex',source}});
  readDataSchemas.documentStructure.parse({documentID:id,contentStamp:version.stamp,entries:[
    {kind:'section',fileID:'main',path:'main.tex',line:4,utf16Offset:80,text:'Introduction'},
    {kind:'program',fileID:'main',path:'main.tex',line:5,utf16Offset:110,text:'programs/oscillator',instanceID:'oscillator'}]});
  sdkInputs.read!.parse({kind:'documentProgram',id,instanceID:'oscillator',programPath:'programs/oscillator'});
  const stateVersion={...version,heads:[{stamp:version.stamp,human:true,hasValue:true,value:{time:1}}]};
  const program=readDataSchemas.documentProgram.parse({documentID:id,instanceID:'oscillator',programPath:'programs/oscillator',sourceBasis:'exact-program',initialState:{time:0},state:{time:1},stateVersion});
  assert.deepEqual(program.stateVersion,stateVersion,'State version preserves its opaque causal frontier, unlike compact file CAS');
  sdkInputs.documentCheck!.parse({id,expectedRevision:'exact-source',pageIndex:2});
  assert.equal(sdkInputs.documentCheck!.safeParse({id,expectedRevision:'exact-source',pageIndex:-1}).success,false);
  sdkInputs.render!.parse({target,expectedRevision:'exact-source',expectedBuildID:'exact-build'});
  sdkOutputs.documentCheck!.parse({data:{status:'pending',programs:[]},basis:{workspaceID:id,owners:[]},coverage:{complete:true},cursor:'1'});
  assert.ok(sdkReference.methods.documentCheck);
  assert.equal(sdkInputs.export!.safeParse({key:'old',documentID:id,blockID:'old'}).success,false);
  sdkInputs.export!.parse({key:'vector',documentID:id,instanceID:'oscillator',format:'svg'});
});


test('explicit bounded file byte reads preserve CAS without adding default binary payloads',()=>{
  const bytes={sourceVersion:version,offset:12,maxBytes:65536};
  sdkInputs.document!.parse({id,fileID:'chart',bytes});
  sdkInputs.read!.parse({kind:'documentFileBytes',id,fileID:'chart',...bytes});
  for(const input of [{id,bytes},{id,fileID:'chart',bytes:{...bytes,offset:-1}},
    {id,fileID:'chart',bytes:{...bytes,maxBytes:1048577}},{id,fileID:'chart',bytes:{offset:0,maxBytes:1}}])
    assert.equal(sdkInputs.document!.safeParse(input).success,false);
  const value={documentID:id,fileID:'chart',path:'figures/chart.png',mimeType:'image/png',
    sourceVersion:version,offset:12,byteCount:2,totalBytes:14,eof:true,base64:'AP8='};
  readDataSchemas.documentFileBytes.parse(value);
  sdkOutputs.document!.parse({data:value,basis:{workspaceID:id,owners:[]},coverage:{complete:true},cursor:'1'});
});


test('document check reports canonical per-instance startup evidence without claiming interaction',()=>{
  const programs=[{instanceID:'visible',sourceBasis:'program-resource-cut',status:'ready',scope:'startup'},
    {instanceID:'broken',status:'failed',scope:'startup'},
    {instanceID:'other-page',sourceBasis:'other-resource-cut',status:'not_checked',scope:'startup'}];
  const value={data:{status:'failed',buildID:'exact-build',programs,diagnostics:[{kind:'error',elementID:'broken',message:'Startup failed'}]},
    basis:{workspaceID:id,owners:[]},coverage:{complete:true},cursor:'1'};
  sdkOutputs.documentCheck!.parse(value);
  assert.equal(sdkOutputs.documentCheck!.safeParse({...value,data:{...value.data,programs:'not_checked'}}).success,false);
  assert.equal(sdkOutputs.documentCheck!.safeParse({...value,data:{...value.data,programs:[{...programs[0],scope:'interaction'}]}}).success,false);
});

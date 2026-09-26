import assert from 'node:assert/strict';
import test from 'node:test';
import {readFile,mkdtemp,writeFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {fileURLToPath} from 'node:url';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {sdkReference,sdkInputs,sdkOutputs} from '../src/sdk-contracts.js';
import {executionInput,executionOutput} from '../src/server.js';
import {actionResultSchema,readDataSchemas} from '../src/sdk-results.js';
const run=promisify(execFile);

test('SDK v2 declarations type addressed reads, tuples, bases and results without a second hand-written API',async()=>{
  const root=await mkdtemp(join(tmpdir(),'notebook-sdk-types-'));
  try {
    const declarations=await readFile(new URL('../../Sources/NotebookScriptHost/Resources/notebook-sdk.d.ts',import.meta.url),'utf8');
    assert.doesNotMatch(declarations,/\bany\b/);
    await writeFile(join(root,'notebook-sdk.d.ts'),declarations);
    await writeFile(join(root,'script.ts'),`async function program() {
      const input=args as {pageID:string; elementID:string; documentID:string};
      const s=await nb.page({id:input.pageID,elementID:input.elementID});
      if (!s.data) throw new Error('missing');
      const source:string=s.data.element.source;
      const nativeText=await nb.read({kind:'boardElement',id:input.documentID,elementID:input.elementID});
      if(nativeText.data) {
        const size:number=nativeText.data.textStyle.fontSize;
        const alpha:number=nativeText.data.textStyle.alpha;
        await nb.transaction('text-style',{base:nativeText.basis,summary:'Increase font size',operations:[
          {kind:'updateElement',target:{kind:'board',id:input.documentID},id:input.elementID,
            values:{textStyle:{...nativeText.data.textStyle,fontSize:size+2}}}
        ]});
        await emit(alpha);
      }
      const appearance:'intact'|'partial'|'erased'=s.data.appearance.state;
      const sourceIsPixels:boolean=s.data.appearance.sourceIsCompleteAppearance;
      const d=await nb.document({id:input.documentID,blockID:'one'});
      if(d.data) { const kind:'markdown'|'latex'|'tex'|'interactive'=d.data.block.kind; await emit(kind); }
      await nb.export('png',{documentID:input.documentID,format:'png',pageIndex:0,pixelWidth:1600});
      await nb.export('shown',{documentID:input.documentID,format:'png',moment:'presented',attention:{contextID:input.documentID,referenceID:input.documentID}});
      await nb.export('portable',{documentID:input.documentID,format:'package'});
      await nb.export('html',{documentID:input.documentID,format:'html',blockID:'sound'});
      await nb.export('svg',{documentID:input.documentID,format:'svg',blockID:'signal'});
      await nb.cancelExport('cancel-image',{jobID:input.documentID});
      const printed=await nb.exportStatus({jobID:input.documentID});
      for(const map of [printed.data.receipt?.artifact,printed.data.receipt?.source,printed.data.receipt?.cut,printed.data.receipt?.sourceMap,printed.data.receipt?.syncTeX]) {
        if(map) {
          const path:string=map.path, hash:string=map.sha256, bytes:number=map.byteCount, mime:string=map.mimeType;
          await emit({path,hash,bytes,mime});
        }
      }
      const vision=await nb.pageMap({id:input.pageID});
      const render=await nb.render({target:{kind:'page',id:input.pageID},expectedRevision:'read'});
      const pageImage=await nb.pageImage({id:input.pageID});
      const regions=await nb.regions({id:input.pageID,drawingRevision:'read',regionIDs:['one']});
      const targetReceipt=await nb.read({kind:'targetRenderReceipt',id:input.pageID});
      const snapshots=await nb.read({kind:'actionSnapshots',id:input.documentID});
      for(const data of [render.data,vision.data,pageImage.data,regions.data,targetReceipt.data,...snapshots.data]) {
        for(const diagnostic of data?.diagnostics??[]) {
          const kind:string=diagnostic.kind, message:string=diagnostic.message;
          const element:string|undefined=diagnostic.elementID;
          // @ts-expect-error: a native render diagnostic is structured, never a string
          const text:string=diagnostic;
          await emit({kind,message,element});
        }
      }
      if(vision.data.map) {
        const map=vision.data.map;
        const format:number=map.format, pageID:string=map.pageID;
        const scale:number=map.renderScale, spacing:number=map.gridSpacing;
        const columns:number=map.gridColumns, rows:number=map.gridRows;
        const pixels:number=map.pixelSize.width*map.pixelSize.height;
        const bounds:number|undefined=map.visibleInkBounds?.width;
        const suppressed:string[]|undefined=map.suppressedInkIDs;
        for(const cell of map.occupiedCells) { const column:number=cell.column,row:number=cell.row; await emit({column,row}); }
        for(const region of map.regions) {
          const content:number=region.contentPoints.width, crop:number=region.cropPoints.height;
          const pixelX:number=region.cropPixels.x, count:number=region.inkPixelCount;
          const cellWidth:number=region.contentCells.width, cellRow:number=region.cropCells.row;
          const faithful:string=region.faithfulPNG_SHA256, ink:string=region.inkPNG_SHA256;
          // @ts-expect-error: native PageVisionRegion has content/crop frames, not a region alias
          const invented=region.region;
          await emit({content,crop,pixelX,count,cellWidth,cellRow,faithful,ink});
        }
        await emit({format,pageID,scale,spacing,columns,rows,pixels,bounds,suppressed});
      }
      const inkDirectory=await nb.read({kind:'pageInkActions',id:input.pageID,limit:2});
      const raster:boolean=inkDirectory.data.baseline.present;
      for(const stroke of inkDirectory.data.actions) {
        const id:string=stroke.id, sequence:number=stroke.sequence;
        const tool:'pen'|'eraser'=stroke.tool;
        // @ts-expect-error: directory never reads sample bodies
        const samples=stroke.samples;
        const source=await nb.read({kind:'pageInkAction',id:input.pageID,elementID:id});
        if(source.data) {
          const x:number=source.data.action.samples[0].point.x;
          const targets=source.data.action.elementTargets;
          await emit({x,targets,sequence,tool,raster});
        }
      }
      for(const kind of ['board','cover','codeFragment'] as const) {
        const spatial=await nb.read({kind:'spatialInk',surfaces:[{kind,ownerID:input.documentID}]});
        for(const action of spatial.data.actions) for(const span of action.spans) {
          for(const target of span.elementTargets??[]) {
            const id:string=target.elementID;
            const width:number=target.frame.width;
            const tile:number|undefined=target.worldOrigin?.tileX;
            await emit({id,width,tile});
          }
          // @ts-expect-error: native spans use elementTargets, not a targets alias
          const invented=span.targets;
        }
      }
      const codeInk=await nb.read({kind:'codeFragment',id:input.documentID});
      if(codeInk.data) for(const action of codeInk.data.ink.actions) for(const span of action.spans) {
        const count:number|undefined=span.elementTargets?.length;
        await emit(count);
      }
      const receipt=await nb.read({kind:'pageVisionReceipt',id:input.pageID});
      if(receipt.data) { const id:string=receipt.data.pageID; await emit(id); }
      const runtime=await nb.read({kind:'runtime'});
      const runtimeStatus:string|undefined=runtime.data?.status;
      // @ts-expect-error: native runtime status is null until published
      const unguardedRuntimeStatus=runtime.data.status;
      await emit(runtimeStatus);
      const batch=await nb.readMany({queries:[{kind:'pageHeader',id:input.pageID},{kind:'workspaceHeader'}]});
      const workspace:string=batch.data[1].workspaceID;
      const content:number=batch.data[0].contentStamp.counter;
      const extent=await nb.read({kind:'itemLifecycle',id:input.documentID});
      if(extent.data) {
        const revision:string=extent.data.revision;
        const rows:number=extent.data.bodyRecordCount;
        const target:'cover'=extent.data.target.kind;
        const fence:string|undefined=extent.basis.owners[0].lifecycleRevision;
        await emit({revision,rows,target,fence});
        const appended=await nb.transaction('append-page',{base:extent.basis,summary:'Append',additionalOwners:[extent.data.target],
          operations:[{kind:'appendPage',target:extent.data.target,values:{}}]});
        for(const change of appended.changed) {
          if(change.change==='appendPage') {
            const page:string=change.pageID;
            const total:number=change.item.pageCount;
            const cover:'cover'=change.target.kind;
            await emit({page,total,cover});
          } else if(change.change==='deletedItem' || change.change==='restoreItem') {
            const title:string=change.item.title;
            await emit(title);
          } else if(change.change==='removePage') {
            const page:string=change.pageID;
            await emit(page);
          } else {
            const file:string=change.file;
            await emit(file);
          }
        }
        await nb.transaction('delete-item',{base:extent.basis,summary:'Delete',additionalOwners:[extent.data.target],
          operations:[{kind:'deleteItem',target:extent.data.target,values:{}}]});
        // @ts-expect-error: lifecycle writes require the physical cover, not a page
        await nb.transaction('wrong-owner',{base:extent.basis,summary:'Wrong',operations:[{kind:'appendPage',target:{kind:'page',id:input.pageID},values:{}}]});
        // @ts-expect-error: deleteItem has no second identity
        await nb.transaction('extra-id',{base:extent.basis,summary:'Wrong',operations:[{kind:'deleteItem',target:extent.data.target,id:input.pageID,values:{}}]});
        // @ts-expect-error: appendPage cannot replace size or any other catalogue field
        await nb.transaction('extra-values',{base:extent.basis,summary:'Wrong',operations:[{kind:'appendPage',target:extent.data.target,values:{size:{width:10,height:20}}}]});
      }
      const choice=await nb.read({kind:'selection'});
      const history=await nb.read({kind:'actions'});
      for(const receipt of history.data) {
        for(const target of receipt.undo?.preservedLifecycle??[]) {
          const kind:'cover'=target.kind;
          const parent:string=target.boardID;
          await emit({kind,parent});
        }
      }
      if(choice.data.status==='known') {
        const generation:number=choice.data.generation;
        if(choice.data.selection.kind==='region') {
          const polygon:{x:number,y:number}[]=choice.data.selection.region;
          const tile:number|undefined=choice.data.selection.worldOrigin?.tileX;
          await emit({polygon,tile});
        }
        if(choice.data.selection.kind==='element') {
          const exact:string=choice.data.selection.elementID;
          const owner:string=choice.data.selection.target.id;
          await emit({generation,exact,owner});
        }
      }
      const result=await nb.transaction('label',{base:[s.basis,batch.basis],summary:'Label',operations:[{
        kind:'updateElement',target:{kind:'page',id:input.pageID},id:input.elementID,values:{graphic:{label:'Next',connection:{routing:'elbow'}}}
      }]});
      const version:string=result.actionVersion;
      await emit({source,workspace,content,version,saved:result.publication.saved});
      // @ts-expect-error: a notebook read needs its identity
      await nb.notebook();
      // @ts-expect-error: v1 manual expected has been removed
      await nb.transaction('old',{summary:'old',expected:[],operations:[]});
      // @ts-expect-error: an addressed element is not the whole page
      const elements=s.data.elements;
      // @ts-expect-error: block kind is not arbitrary source text
      const wrong:number=d.data?.block.kind;
    }`);
    await writeFile(join(root,'tsconfig.json'),JSON.stringify({compilerOptions:{strict:true,noEmit:true,noEmitOnError:true,skipLibCheck:false,lib:['ES2023'],types:[],target:'ES2023',module:'esnext'},files:['notebook-sdk.d.ts','script.ts']}));
    const compiler=fileURLToPath(new URL('../node_modules/.bin/tsc',import.meta.url));
    await run(compiler,['--project',join(root,'tsconfig.json')],{maxBuffer:1024*1024});
  } finally { await rm(root,{recursive:true,force:true}); }
});

test('ActionResult has discriminated compact lifecycle events and keeps field events intact',()=>{
  const id='53d0ccbb-dc97-4911-ad2b-1b0f8ce4957d',target={kind:'cover',id,boardID:id};
  const item={id,kind:'notebook',title:'Saved title',firstPageID:id,pageCount:2};
  const result={actionID:id,actionVersion:'a'.repeat(64),summary:'Frozen lifecycle',basis:{workspaceID:id,owners:[]},
    publication:{saved:'confirmed',receivedByIPad:'awaiting_device',shownOnIPad:'awaiting_display'},changeCount:1};
  const events=[{change:'updated',file:'page.json',path:[],afterDigest:'digest',value:'saved'},
    {change:'deleted',file:'page.json',path:[],afterDigest:null},
    {change:'appendPage',target,pageID:id,item},{change:'deletedItem',target,item},
    {change:'restoreItem',target,item},{change:'removePage',target,pageID:id,item}];
  for(const change of events) {
    const parsed=actionResultSchema.safeParse({...result,changed:[change]});
    assert.equal(parsed.success,true,JSON.stringify(parsed));
  }
  for(const change of [
    {change:'appendPage',target,item},{change:'deletedItem',target},{change:'restoreItem',target},
    {change:'removePage',target,item},{change:'deleteItem',target,item},
    {change:'appendPage',target:{kind:'page',id},pageID:id,item},
  ]) assert.equal(actionResultSchema.safeParse({...result,changed:[change]}).success,false,JSON.stringify(change));
});

test('every method has a generated output schema and start only accepts v2, defaulting to bounded completion wait',()=>{
  for(const [name,method] of Object.entries(sdkReference.methods)) assert.ok(method.output&&sdkInputs[name]&&sdkOutputs[name],name);
  const request={op:'start',run_id:'53d0ccbb-dc97-4911-ad2b-1b0f8ce4957d',api_version:2,code:'return 42'};
  const parsed=executionInput.parse(request);
  assert.equal(parsed.wait_ms,1000);
  assert.equal(executionInput.safeParse({...request,api_version:1}).success,false);
  assert.equal(executionOutput.safeParse({status:'completed',run_id:request.run_id,api_version:2,run_api_version:1,fingerprint:'historic',events:[],next_seq:0,has_more:false,result:42,error:null,effects:[],resume_semantics:'attach_only_no_replay'}).success,true);
});


test('region selection keeps its polygon instead of becoming an unknown UI choice',()=>{
  const id='11111111-1111-4111-8111-111111111111';
  const value={status:'known',deviceID:id,sessionID:id,generation:1,selection:{id,kind:'region',
    surface:{kind:'board',id},target:{kind:'board',id},resolving:false,
    region:[{x:0,y:0},{x:100,y:0},{x:60,y:100}],worldOrigin:{tileX:1000000,tileY:0,localX:0,localY:0}}};
  assert.deepEqual(readDataSchemas.selection.parse(value),value);
});

test('region selection publication accepts all 8192 contour points and rejects overflow',()=>{
  const id='11111111-1111-4111-8111-111111111111';
  const region=Array.from({length:8192},(_,index)=>{
    const angle=index*2*Math.PI/8192;
    return {x:200+100*Math.cos(angle),y:200+100*Math.sin(angle)};
  });
  const value={status:'known',deviceID:id,sessionID:id,generation:1,selection:{id,kind:'region',
    surface:{kind:'board',id},target:{kind:'board',id},resolving:false,region}};
  assert.deepEqual(readDataSchemas.selection.parse(value),value);
  assert.equal(readDataSchemas.selection.safeParse({...value,
    selection:{...value.selection,region:[...region,{x:301,y:200}]}}).success,false);
});


test('whole ink selection publishes a separate namespace and one combined member budget',()=>{
  const id='11111111-1111-4111-8111-111111111111';
  const selection={id,kind:'elements',surface:{kind:'page',id},target:{kind:'page',id},
    resolving:false,elementIDs:[],inkActionIDs:[id]};
  const value={status:'known',deviceID:id,sessionID:id,generation:1,selection};
  assert.deepEqual(readDataSchemas.selection.parse(value),value);
  assert.equal(readDataSchemas.selection.safeParse({...value,selection:{...selection,elementIDs:Array.from({length:31},(_,i)=>`real-${i}`)}}).success,true);
  assert.equal(readDataSchemas.selection.safeParse({...value,selection:{...selection,elementIDs:Array.from({length:32},(_,i)=>`real-${i}`)}}).success,false);
  assert.equal(readDataSchemas.selection.safeParse({...value,selection:{...selection,inkActionIDs:[id,id]}}).success,false);
  assert.equal(readDataSchemas.selection.safeParse({...value,selection:{...selection,kind:'element',elementID:'real'}}).success,false);
});

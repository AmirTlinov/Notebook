import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {access,lstat,mkdir,mkdtemp,readFile,readdir,realpath,rename,rm} from 'node:fs/promises';
import {constants,fstatSync,lstatSync} from 'node:fs';
import {spawnSync} from 'node:child_process';
import {homedir} from 'node:os';
import {join,resolve,sep} from 'node:path';
import {fileURLToPath} from 'node:url';

const bundleID='com.amirtlinov.notebook.mac',team='M94V58FCVP';
const requirement=`=anchor apple generic and identifier "${bundleID}" and certificate leaf[subject.OU] = "${team}"`;
export const publicationRoot=()=>join(homedir(),'Library/Application Support/NotebookRuntime');

function run(command,args,leases){
  const result=spawnSync(command,args,{encoding:'utf8',maxBuffer:4*1024*1024,
    stdio:leases.length?['pipe','pipe','pipe',...leases]:'pipe'});
  assert.equal(result.status,0,result.error?.message||result.stderr||`${command} failed`);
  return result.stdout;
}

export async function inspectRuntimeBundle(app,{installed=false,leases=[]}={}){
  assert.equal(process.platform,'darwin','Notebook runtime publication requires macOS.');
  const directory=await lstat(app);
  assert(directory.isDirectory()&&!directory.isSymbolicLink(),'Runtime must be an ordinary app bundle.');
  const info=JSON.parse(run('/usr/bin/plutil',['-convert','json','-o','-',join(app,'Contents/Info.plist')],leases));
  assert.equal(info.CFBundleIdentifier,bundleID);assert.equal(info.CFBundleExecutable,'NotebookRuntime');
  assert.equal(info.CFBundleName,'NotebookRuntime');assert.equal(info.CFBundlePackageType,'APPL');
  assert.equal(info.LSUIElement,true,'The runtime must not create a Dock application.');
  assert(info.NotebookHeadlessRuntime===true||installed&&info.NotebookPluginRuntime===true,
    'New publication requires the headless runtime entrypoint.');
  assert.match(info.CFBundleVersion,/^\d{1,19}$/);assert.match(info.CFBundleShortVersionString,/^\d+\.\d+\.\d+$/);
  const tools=join(app,'Contents/Resources/NotebookTools');
  await Promise.all([access(join(app,'Contents/MacOS/NotebookRuntime'),constants.X_OK),
    access(join(app,'Contents/Resources/CodexRuntime/node'),constants.X_OK),
    access(join(tools,'dist/launch-runtime.mjs'),constants.R_OK),access(join(tools,'dist/index.mjs'),constants.R_OK)]);
  const metadata=JSON.parse(await readFile(join(tools,'package.json'),'utf8'));
  assert.equal(metadata.name,'notebook-mcp');assert.match(metadata.version,/^\d+\.\d+\.\d+$/);
  if(!installed){
    const entry=await readFile(join(tools,'dist/index.mjs'),'utf8');
    assert(entry.includes('notebook_execute')&&entry.includes('notebook_context'),'Runtime lacks its domain MCP tools.');
    assert(!entry.includes('notebook_panel_')&&!entry.includes('panel-bundle.json'),'Runtime still contains the plugin panel.');
  }
  run('/usr/bin/codesign',['--verify','--strict','--deep','-R',requirement,app],leases);
  return {app,bundleID,build:info.CFBundleVersion,version:info.CFBundleShortVersionString,mcpVersion:metadata.version};
}

/** Seals bytes and executable modes, including every signed resource. */
export async function runtimeInventory(app){
  const files=[];
  async function visit(path,relative=''){
    const info=await lstat(path);assert(!info.isSymbolicLink(),`Runtime contains a symbolic link: ${path}`);
    if(info.isDirectory()){
      for(const name of(await readdir(path)).sort())await visit(join(path,name),relative?`${relative}/${name}`:name);
    }else{
      assert(info.isFile(),`Runtime contains an unsupported entry: ${path}`);
      files.push({path:relative,bytes:info.size,executable:Boolean(info.mode&0o111),
        sha256:createHash('sha256').update(await readFile(path)).digest('hex')});
    }
  }
  await visit(app);
  return {sha256:createHash('sha256').update(JSON.stringify(files)).digest('hex'),files};
}

/** Build packaging and installed replacement copy the same signed payload.
 * The release owner holds its publication and stopped-writer leases at install. */
export async function publishRuntime(app,root,{inspect=inspectRuntimeBundle,copy,leases=[]}={}){
  root=resolve(root);await mkdir(root,{recursive:true,mode:0o700});
  assert.equal(await realpath(root),root,'Publication requires a direct directory.');
  const source=await realpath(app),output=join(root,'NotebookRuntime.app');
  assert(source!==output&&!source.startsWith(output+sep),'Publish from the verified build product.');
  const original=await inspect(source,{leases}),inventory=await runtimeInventory(source);
  let present;
  try{present=await lstat(output);}
  catch(error){if(error.code!=='ENOENT')throw error;}
  const current=present?await inspect(output,{installed:root===publicationRoot(),leases}):undefined;
  if(current){
    assert(BigInt(current.build)<=BigInt(original.build),'Runtime downgrade is forbidden.');
    if(current.build===original.build){
      assert.deepEqual(await runtimeInventory(output),inventory,'An immutable build already has another payload.');
      return {...current,root,app:output,inventorySHA256:inventory.sha256,alreadyPublished:true};
    }
  }
  const stage=await mkdtemp(join(root,'.runtime-stage-')),prepared=join(stage,'NotebookRuntime.app'),retired=join(stage,'retired.app');
  let replaced=false,preserveStage=false;
  try{
    if(copy)await copy(source,prepared);else run('/usr/bin/ditto',[source,prepared],leases);
    const result=await inspect(prepared,{leases});
    for(const key of['bundleID','build','version','mcpVersion'])assert.equal(result[key],original[key],`Copy replaced the verified ${key}.`);
    assert.deepEqual(await runtimeInventory(prepared),inventory,'Runtime changed during publication copy.');
    assert.deepEqual(await runtimeInventory(source),inventory,'Verified source changed during publication copy.');
    if(current){await rename(output,retired);replaced=true;}
    try{await rename(prepared,output);}
    catch(error){
      if(replaced){try{await rename(retired,output);}catch(restoreError){
        preserveStage=true;throw new AggregateError([error,restoreError],`Previous runtime remains at ${retired}`);
      }}
      throw error;
    }
    return {...result,root,app:output,inventorySHA256:inventory.sha256};
  }finally{if(!preserveStage)await rm(stage,{recursive:true,force:true});}
}

function admitLease(descriptor,path){
  assert(Number.isSafeInteger(descriptor)&&descriptor>2,'Use notebook_release.py install-pair to replace the installed runtime.');
  const inherited=fstatSync(descriptor),owner=lstatSync(path);
  assert(inherited.isFile()&&!owner.isSymbolicLink()&&inherited.nlink===1&&inherited.uid===process.getuid()
    &&(inherited.mode&0o777)===0o600&&inherited.dev===owner.dev&&inherited.ino===owner.ino,'Invalid inherited runtime lease.');
}

if(process.argv[1]&&resolve(process.argv[1])===fileURLToPath(import.meta.url)){
  const args=process.argv.slice(2);let leases=[];
  if(args.length===6){
    assert.equal(args[2],'--publication-fd');assert.equal(args[4],'--writer-fd');
    leases=[Number(args[3]),Number(args[5])];args.splice(2);
  }
  assert.equal(args.length,2,'Usage: node MCP/package-runtime.mjs <signed NotebookRuntime.app> <publication-root>');
  const root=resolve(args[1]);
  if(root===publicationRoot()){
    assert.equal(leases.length,2,'Installation must retain publication and writer leases.');
    admitLease(leases[0],join(root,'.publication.owner'));
    admitLease(leases[1],`/tmp/notebook-${process.getuid()}/bridge.sock.owner`);
  }
  console.log(JSON.stringify(await publishRuntime(resolve(args[0]),root,{leases}),null,2));
}

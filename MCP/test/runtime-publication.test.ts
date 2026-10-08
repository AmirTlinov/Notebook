import assert from 'node:assert/strict';
import {test,type TestContext} from 'node:test';
import {cp,mkdir,mkdtemp,readFile,realpath,readdir,rm,symlink,writeFile} from 'node:fs/promises';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
const {publishRuntime,runtimeInventory} = await import(new URL('../package-runtime.mjs',import.meta.url).href);

async function fixture(t:TestContext) {
  const root=await realpath(await mkdtemp(join(tmpdir(),'notebook-runtime-publication-')));
  t.after(()=>rm(root,{recursive:true,force:true}));
  const source=join(root,'signed/NotebookRuntime.app'),output=join(root,'published'),app=join(output,'NotebookRuntime.app');
  await mkdir(source,{recursive:true});
  const setBuild=async(build:string,body=`sealed-runtime-${build}`)=>{
    await writeFile(join(source,'identity.json'),JSON.stringify({bundleID:'com.amirtlinov.notebook.mac',
      build,version:'0.3.192',mcpVersion:'0.3.42'}));
    await writeFile(join(source,'sealed'),body);
  };
  const inspect=async(path:string)=>{
    assert.match(await readFile(join(path,'sealed'),'utf8'),/^sealed-runtime-/);
    return {app:path,...JSON.parse(await readFile(join(path,'identity.json'),'utf8'))};
  };
  const copy=(from:string,to:string)=>cp(from,to,{recursive:true,verbatimSymlinks:true});
  await setBuild('261');
  return {root,source,output,app,setBuild,inspect,copy};
}

test('runtime replacement admits the complete copied product before retiring the previous app',async t=>{
  const f=await fixture(t);
  await publishRuntime(f.source,f.output,{inspect:f.inspect,copy:f.copy});
  const first=await runtimeInventory(f.app);
  await f.setBuild('262');
  await assert.rejects(publishRuntime(f.source,f.output,{copy:f.copy,inspect:async(app:string)=>{
    if(app!==f.source&&app!==f.app)throw new Error('copied signature rejected');
    return f.inspect(app);
  }}),/copied signature/);
  assert.deepEqual(await runtimeInventory(f.app),first);
  await assert.rejects(publishRuntime(f.source,f.output,{copy:f.copy,inspect:async(app:string)=>{
    const value=await f.inspect(app);
    return app===f.source||app===f.app?value:{...value,mcpVersion:'0.3.41'};
  }}),/Copy replaced the verified mcpVersion/);
  assert.deepEqual(await runtimeInventory(f.app),first);
  const publication=await publishRuntime(f.source,f.output,{inspect:f.inspect,copy:async(from:string,to:string)=>{
    assert.deepEqual(await runtimeInventory(f.app),first);
    await f.copy(from,to);
    assert.deepEqual(await runtimeInventory(f.app),first);
  }});
  assert.equal(publication.build,'262');assert.equal(publication.app,f.app);
  assert.equal(await readFile(join(f.app,'sealed'),'utf8'),'sealed-runtime-262');
  assert.deepEqual(await runtimeInventory(f.app),await runtimeInventory(f.source));
  assert(!(await readdir(f.output)).some(name=>name.startsWith('.runtime-stage-')));
});

test('changed copy or source, reused build and downgrade preserve the admitted signed payload',async t=>{
  const f=await fixture(t);
  await publishRuntime(f.source,f.output,{inspect:f.inspect,copy:f.copy});
  const admitted=await runtimeInventory(f.app);
  await f.setBuild('261','sealed-runtime-another-payload');
  await assert.rejects(publishRuntime(f.source,f.output,{inspect:f.inspect,copy:f.copy}),/immutable build/);
  await f.setBuild('260');
  await assert.rejects(publishRuntime(f.source,f.output,{inspect:f.inspect,copy:f.copy}),/downgrade/);
  await f.setBuild('262');
  for(const changed of ['copy','source']){
    await f.setBuild('262');
    await assert.rejects(publishRuntime(f.source,f.output,{inspect:f.inspect,copy:async(from:string,to:string)=>{
      await f.copy(from,to);
      await writeFile(join(changed==='copy'?to:from,'sealed'),'sealed-runtime-truncated');
    }}),/changed during publication copy/);
    assert.deepEqual(await runtimeInventory(f.app),admitted);
  }
});

test('same exact runtime retries without replacement and linked resources cannot be published',async t=>{
  const f=await fixture(t);
  await publishRuntime(f.source,f.output,{inspect:f.inspect,copy:f.copy});
  const admitted=await runtimeInventory(f.app);
  const retried=await publishRuntime(f.source,f.output,{inspect:f.inspect,
    copy:async()=>assert.fail('An admitted immutable build does not need another copy')});
  assert.equal(retried.alreadyPublished,true);
  assert.deepEqual(await runtimeInventory(f.app),admitted);
  await f.setBuild('262');await symlink(join(f.source,'sealed'),join(f.source,'linked'));
  await assert.rejects(publishRuntime(f.source,f.output,{inspect:f.inspect,copy:f.copy}),/symbolic link/);
  assert.deepEqual(await runtimeInventory(f.app),admitted);
});

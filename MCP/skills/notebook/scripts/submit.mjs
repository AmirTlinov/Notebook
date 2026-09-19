#!/usr/bin/env node
// File-to-tool transport for large embedded images. Execution stays in Notebook.
import {readFile} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import {resolve} from 'node:path';
import {Client} from '@modelcontextprotocol/client';
import {StdioClientTransport,getDefaultEnvironment} from '@modelcontextprotocol/client/stdio';

const [path,...extra]=process.argv.slice(2);
if(!path||extra.length)throw new Error('Usage: node submit.mjs request.json');
const request=JSON.parse(await readFile(path,'utf8'));
const environment=getDefaultEnvironment();delete environment.NOTEBOOK_SOCKET;
const client=new Client({name:'notebook-recipe',version:'1'});
const transport=new StdioClientTransport({command:fileURLToPath(new URL('../../../run.sh',import.meta.url)),env:environment,stderr:'pipe'});
try {
  await client.connect(transport);
  if(request.packageHash && request.package && Array.isArray(request.sources)) {
    let stopping=false;
    const cancel=async()=>{stopping=true;await client.callTool({name:'notebook_import_program',arguments:{op:'cancel',packageHash:request.packageHash}}).catch(()=>{});};
    process.once('SIGINT',cancel);process.once('SIGTERM',cancel);
    try {
      let response=await client.callTool({name:'notebook_import_program',arguments:{op:'start',packageHash:request.packageHash,manifestPath:resolve(path)}});
      let result=response.structuredContent??response;
      while(!response.isError && result.status==='staging') {
        await new Promise(resolve=>setTimeout(resolve,250));
        response=await client.callTool({name:'notebook_import_program',arguments:{op:'status',packageHash:request.packageHash}});
        result=response.structuredContent??response;
      }
      process.stdout.write(JSON.stringify(result)+'\n');
      if(stopping)process.exitCode=130;
      else if(response.isError||result.status!=='ready')process.exitCode=1;
    } finally {process.removeListener('SIGINT',cancel);process.removeListener('SIGTERM',cancel);}
  } else {
    const response=await client.callTool({name:'notebook_execute',arguments:request});
    const result=response.structuredContent??response;
    process.stdout.write(JSON.stringify(result)+'\n');
    if(response.isError||['failed','cancelled','interrupted','error'].includes(result.status))process.exitCode=1;
  }
} finally {await client.close();}

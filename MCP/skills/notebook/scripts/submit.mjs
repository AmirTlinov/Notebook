#!/usr/bin/env node
// File-to-tool transport for large embedded images. Execution stays in Notebook.
import {fileURLToPath} from 'node:url';
import {readInput,stageProgram,submitPortable} from './portable-document.mjs';
import {Client} from '@modelcontextprotocol/client';
import {StdioClientTransport,getDefaultEnvironment} from '@modelcontextprotocol/client/stdio';

const [path,...extra]=process.argv.slice(2);
if(!path||extra.length)throw new Error('Usage: node submit.mjs request.json');
const request=(await readInput(path)).value;
const environment=getDefaultEnvironment();delete environment.NOTEBOOK_SOCKET;
const client=new Client({name:'notebook-recipe',version:'1'});
const transport=new StdioClientTransport({command:fileURLToPath(new URL('../../../run.sh',import.meta.url)),env:environment,stderr:'pipe'});
try {
  await client.connect(transport);
  const abort=new AbortController(),cancel=()=>abort.abort();
  process.once('SIGINT',cancel);process.once('SIGTERM',cancel);
  if(request.format==='NotebookPortable/1' || (request.packageHash && request.package && Array.isArray(request.sources))) {
    try {
      const result=request.format==='NotebookPortable/1' ? await submitPortable(client,path,abort.signal) : await stageProgram(client,request,path,abort.signal);
      process.stdout.write(JSON.stringify(result)+'\n');
      if(['failed','cancelled','interrupted','error'].includes(result.status))process.exitCode=1;
    } catch(error) {if(abort.signal.aborted)process.exitCode=130;else throw error;}
    finally {process.removeListener('SIGINT',cancel);process.removeListener('SIGTERM',cancel);}
  } else {
    process.removeListener('SIGINT',cancel);process.removeListener('SIGTERM',cancel);
    const response=await client.callTool({name:'notebook_execute',arguments:request});
    const result=response.structuredContent??response;
    process.stdout.write(JSON.stringify(result)+'\n');
    if(response.isError||['failed','cancelled','interrupted','error'].includes(result.status))process.exitCode=1;
  }
} finally {await client.close();}

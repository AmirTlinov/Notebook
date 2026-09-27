#!/usr/bin/env node
// File-to-tool transport for large embedded images. Execution stays in Notebook.
import {fileURLToPath} from 'node:url';
import {readInput,stageProgram,documentImportRequest,submitDocument,submitDocumentResource} from './file-import.mjs';
import {mkdtemp,writeFile,rm} from 'node:fs/promises';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import {Client} from '@modelcontextprotocol/client';
import {StdioClientTransport,getDefaultEnvironment} from '@modelcontextprotocol/client/stdio';

const [path,...extra]=process.argv.slice(2);
if(!path||extra.length)throw new Error('Usage: node submit.mjs request.json | document.notex');
const isDocument=path.toLowerCase().endsWith('.notex');
const request=isDocument?null:(await readInput(path)).value;
const environment=getDefaultEnvironment();delete environment.NOTEBOOK_SOCKET;
const client=new Client({name:'notebook-recipe',version:'1'});
const transport=new StdioClientTransport({command:fileURLToPath(new URL('../../../run.sh',import.meta.url)),env:environment,stderr:'pipe'});
try {
  await client.connect(transport);
  const abort=new AbortController(),cancel=()=>abort.abort();
  process.once('SIGINT',cancel);process.once('SIGTERM',cancel);
  if(isDocument||['notebook_import_document','notebook_import_document_resource'].includes(request?.tool)||(request.packageHash && request.package && Array.isArray(request.sources))) {
    try {
      let result;
      if(isDocument||request?.tool==='notebook_import_document') {
        const args=isDocument?await documentImportRequest(client,path,abort.signal):request.arguments;
        // Persist the exact request before native admission. If the process or
        // connection disappears, this file resumes the same copy, not a new one.
        const directory=isDocument?await mkdtemp(join(tmpdir(),'notebook-document-import-')):null;
        if(directory) {
          const retry=join(directory,'request.json');
          await writeFile(retry,JSON.stringify({tool:'notebook_import_document',arguments:args}),{mode:0o600});
          process.stderr.write('Import retry request: '+retry+'\n');
        }
        result=await submitDocument(client,args,abort.signal);
        if(directory)await rm(directory,{recursive:true,force:true});
      } else if(request?.tool==='notebook_import_document_resource') result=await submitDocumentResource(client,request.arguments,abort.signal);
      else result=await stageProgram(client,request,path,abort.signal);
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

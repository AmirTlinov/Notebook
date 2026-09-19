import {readFile,writeFile} from 'node:fs/promises';
import {resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import {buildScienceProgram} from '../skills/notebook/scripts/science-examples.mjs';
export const signalFixtureURL=new URL('../../Applications/TestSupport/ProgramAssets/signal-program.json',import.meta.url);
export async function signalProgramFixture() {
  const result=await buildScienceProgram('signal'),files={},binaryFiles={},webResources={};
  for(const source of result.sources) {
    const bytes=await readFile(source.sourcePath),path=source.path;
    const resource=path.startsWith('node_modules/mathjax/')?path.slice('node_modules/mathjax/'.length):
      path.startsWith('node_modules/@mathjax/mathjax-newcm-font/svg')?'fonts/mathjax-newcm-font/'+path.slice('node_modules/@mathjax/mathjax-newcm-font/'.length):null;
    if(resource&&!path.endsWith('LICENSE')) {
      const installed=await readFile(new URL('../../Applications/WebResources/'+resource,import.meta.url));
      if(!bytes.equals(installed))throw new Error('Native vendored MathJax does not match the prepared package: '+path);
      webResources[path]=resource;
    } else if(path.endsWith('.bin'))binaryFiles[path]=bytes.toString('base64');
    else files[path]=bytes.toString('utf8');
  }
  return {packageHash:result.packageHash,package:result.package,files,binaryFiles,webResources};
}
if(process.argv[1]&&resolve(process.argv[1])===fileURLToPath(import.meta.url))
  await writeFile(signalFixtureURL,JSON.stringify(await signalProgramFixture())+'\n');

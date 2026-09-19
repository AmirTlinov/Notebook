import {mkdtemp,cp,rm,readFile,writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import {buildProgram} from '../skills/notebook/scripts/program-build.mjs';
export const fixtureURL=new URL('../../Applications/TestSupport/ProgramAssets/compiled-program.json',import.meta.url);
export async function compiledProgramFixture(){
  const directory=await mkdtemp(join(tmpdir(),'notebook-compiled-fixture-'));
  try {
    await cp(new URL('./fixtures/program-source/',import.meta.url),directory,{recursive:true});
    const result=await buildProgram({directory,entry:'main.ts',workers:{square:'square.ts'},html:'view.html'});
    const files=Object.fromEntries(await Promise.all(result.sources.map(async source=>[source.path,await readFile(source.sourcePath,'utf8')])));
    return {packageHash:result.packageHash,package:result.package,files};
  }finally{await rm(directory,{recursive:true,force:true});}
}
if(process.argv[1]&&resolve(process.argv[1])===fileURLToPath(import.meta.url)) {
  await writeFile(fixtureURL,JSON.stringify(await compiledProgramFixture(),null,2)+'\n');
}

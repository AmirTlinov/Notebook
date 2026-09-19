import {readFile,writeFile} from 'node:fs/promises';
import {resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import {createHash} from 'node:crypto';
import {buildScienceProgram} from '../skills/notebook/scripts/science-examples.mjs';
export const gearsFixtureURL=new URL('../../Applications/TestSupport/ProgramAssets/gears-program.json',import.meta.url);
export async function gearsProgramFixture() {
  const result=await buildScienceProgram('gears'),files={},bundleResources={},assets=new Map();
  for(const name of ['mechanism.gltf','mechanism.bin','machined.png','roughness.png','poster.svg']) {
    const bytes=await readFile(new URL('../skills/notebook/assets/science/gears/'+name,import.meta.url));
    assets.set(createHash('sha256').update(bytes).digest('hex'),'science/gears/'+name);
  }
  for(const source of result.sources) {
    const bytes=await readFile(source.sourcePath),resource=assets.get(createHash('sha256').update(bytes).digest('hex'));
    if(resource)bundleResources[source.path]=resource;else files[source.path]=bytes.toString('utf8');
  }
  return {packageHash:result.packageHash,package:result.package,files,bundleResources};
}
if(process.argv[1]&&resolve(process.argv[1])===fileURLToPath(import.meta.url))await writeFile(gearsFixtureURL,JSON.stringify(await gearsProgramFixture())+'\n');

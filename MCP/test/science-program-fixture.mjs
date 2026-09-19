import {readFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {buildScienceProgram} from '../skills/notebook/scripts/science-examples.mjs';
/** The real package, with authored binary resources referenced rather than duplicated in JSON. */
export async function scienceProgramFixture(id,resourceNames) {
  const result=await buildScienceProgram(id),files={},bundleResources={},assets=new Map();
  for(const name of resourceNames) {
    const bytes=await readFile(new URL('../skills/notebook/assets/science/'+id+'/'+name,import.meta.url));
    assets.set(createHash('sha256').update(bytes).digest('hex'),'science/'+id+'/'+name);
  }
  for(const source of result.sources) {
    const bytes=await readFile(source.sourcePath),resource=assets.get(createHash('sha256').update(bytes).digest('hex'));
    if(resource)bundleResources[source.path]=resource;else files[source.path]=bytes.toString('utf8');
  }
  return {packageHash:result.packageHash,package:result.package,files,bundleResources};
}

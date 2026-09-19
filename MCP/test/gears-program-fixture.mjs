import {writeFile} from 'node:fs/promises';
import {resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import {scienceProgramFixture} from './science-program-fixture.mjs';
export const gearsFixtureURL=new URL('../../Applications/TestSupport/ProgramAssets/gears-program.json',import.meta.url);
export const gearsProgramFixture=()=>scienceProgramFixture('gears',['mechanism.gltf','mechanism.bin','machined.png','roughness.png','poster.svg']);
if(process.argv[1]&&resolve(process.argv[1])===fileURLToPath(import.meta.url))await writeFile(gearsFixtureURL,JSON.stringify(await gearsProgramFixture())+'\n');

import {writeFile} from 'node:fs/promises';
import {resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import {scienceProgramFixture} from './science-program-fixture.mjs';
export const waveFixtureURL=new URL('../../Applications/TestSupport/ProgramAssets/wave-program.json',import.meta.url);
export const waveProgramFixture=()=>scienceProgramFixture('wave',['experiment.mp4','recording-poster.png','sonification.wav','final.bin']);
if(process.argv[1]&&resolve(process.argv[1])===fileURLToPath(import.meta.url))await writeFile(waveFixtureURL,JSON.stringify(await waveProgramFixture())+'\n');

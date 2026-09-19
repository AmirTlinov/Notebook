#!/usr/bin/env node
import {readFile,writeFile,stat} from 'node:fs/promises';
import {execFileSync} from 'node:child_process';
import {resolve,dirname,extname} from 'node:path';
import {fileURLToPath} from 'node:url';
import {makeRecipe,chartSVG} from './recipes.mjs';
import {loadScienceExample,buildScienceProgram} from './science-examples.mjs';
import {prepareProgramPackage} from './program-package.mjs';

const maxImageBytes=700_000;
function size(bytes,mimeType,path) {
  if(mimeType==='image/svg+xml') {
    const source=bytes.toString('utf8'),view=source.match(/\bviewBox\s*=\s*["']\s*([-+\d.e]+)[\s,]+([-+\d.e]+)[\s,]+([-+\d.e]+)[\s,]+([-+\d.e]+)\s*["']/i);
    if(!/<svg\b/.test(source)||!view)throw new Error('SVG needs a viewBox');
    return {width:Number(view[3]),height:Number(view[4])};
  }
  if(mimeType==='image/png') {
    if(bytes.length<24||!bytes.subarray(0,8).equals(Buffer.from([137,80,78,71,13,10,26,10])))throw new Error('Invalid PNG');
    return {width:bytes.readUInt32BE(16),height:bytes.readUInt32BE(20)};
  }
  const info=execFileSync('/usr/bin/sips',['-g','pixelWidth','-g','pixelHeight',path],{encoding:'utf8'});
  return {width:Number(info.match(/pixelWidth: (\d+)/)?.[1]),height:Number(info.match(/pixelHeight: (\d+)/)?.[1])};
}

export async function loadImage(path,{fit=false,outputPath}={}) {
  const mimeType={'.png':'image/png','.jpg':'image/jpeg','.jpeg':'image/jpeg','.svg':'image/svg+xml'}[extname(path).toLowerCase()];
  if(!mimeType)throw new Error('Choose a PNG, JPEG or SVG file');
  let bytes=await readFile(path),dimensions=size(bytes,mimeType,path);
  if(bytes.length>maxImageBytes && fit && mimeType!=='image/svg+xml') {
    if(!outputPath||resolve(path)===resolve(outputPath))throw new Error('A fitting copy needs a separate output path');
    try {await stat(outputPath);throw new Error(`Fitting output already exists: ${outputPath}`);}catch(error){if(error.code!=='ENOENT')throw error;}
    let edge=Math.min(1600,Math.max(dimensions.width,dimensions.height));
    do {
      execFileSync('/usr/bin/sips',['--resampleHeightWidthMax',String(Math.round(edge)),path,'--out',outputPath],{stdio:'pipe'});
      bytes=await readFile(outputPath);dimensions=size(bytes,mimeType,outputPath);edge*=0.75;
    } while(bytes.length>maxImageBytes && edge>=128);
  }
  if(bytes.length>maxImageBytes)throw new Error('Image is too large for this embedded recipe. Use fit:true for a smaller raster copy, or simplify the SVG. The original is unchanged.');
  if(!Number.isFinite(dimensions.width)||!Number.isFinite(dimensions.height)||dimensions.width<=0||dimensions.height<=0)throw new Error('Image dimensions are unavailable');
  return {dataURL:`data:${mimeType};base64,${bytes.toString('base64')}`,...dimensions};
}

export async function prepare(name,input,{baseDirectory='.',outputPath,runID}={}) {
  input=structuredClone(input);
  if(name==='program'&&input.example) {
    if(Object.keys(input).some(key=>key!=='example'))throw new Error('Choose a named program or build inputs, not both');
    return buildScienceProgram(input.example);
  }
  if(name==='program') return (input.entry?(await import('./program-build.mjs')).buildProgram:prepareProgramPackage)({...input,directory:resolve(baseDirectory,input.directory??'.')});
  if(name==='animation'&&input.example) {
    if(input.programPackage!==undefined)throw new Error('Choose an example or a package, not both');
    for(const field of ['html','css','javaScript'])if(input[field]!==undefined||input[`${field}Path`]!==undefined)throw new Error('Choose a named example or source files, not both');
    input={...await loadScienceExample(input.example),...input};
  }
  if(name==='plot') {
    const svg=chartSVG(input),width=input.width??720,height=input.height??420;
    input.image={dataURL:`data:image/svg+xml;base64,${Buffer.from(svg).toString('base64')}`,width,height};
    name='visual';
  }
  if(name==='visual'&&input.imagePath) {
    const path=resolve(baseDirectory,input.imagePath);
    input.image=await loadImage(path,{fit:input.fit??false,
      outputPath:outputPath?`${outputPath}.image${extname(path)}`:undefined});
  }
  if(name==='document') for(const section of input.sections??[]) {
    if(section.sourcePath) section.body=await readFile(resolve(baseDirectory,section.sourcePath),'utf8');
  }
  if(name==='animation') for(const field of ['html','css','javaScript']) {
    if(input[`${field}Path`]) {
      if(input[field]!==undefined)throw new Error(`Choose ${field} or ${field}Path, not both`);
      input[field]=await readFile(resolve(baseDirectory,input[`${field}Path`]),'utf8');
    }
  }
  return makeRecipe(name,input,runID);
}

async function main() {
  const [name,inputPath,outputPath,...extra]=process.argv.slice(2);
  if(!name||!inputPath||!outputPath||extra.length)throw new Error('Usage: node prepare.mjs mindmap|flow|compare|visual|plot|sketch|point|document|animation|program input.json request.json');
  // This saved request is the retry identity; preparing again is a new intention.
  const input=JSON.parse(await readFile(inputPath,'utf8'));
  const request=await prepare(name,input,{baseDirectory:dirname(resolve(inputPath)),outputPath:resolve(outputPath)});
  await writeFile(outputPath,JSON.stringify(request),{flag:'wx',mode:0o600});
  process.stdout.write(JSON.stringify({request:resolve(outputPath),run_id:request.run_id,operations:request.args?.operations?.length??0,ids:request.args?.ids??{},...(request.packageHash?{packageHash:request.packageHash}:{})})+'\n');
}
if(process.argv[1]&&resolve(process.argv[1])===fileURLToPath(import.meta.url)) {
  main().catch(error=>{process.stderr.write((error.diagnostics?JSON.stringify({stage:error.stage,diagnostics:error.diagnostics}):error.message)+'\n');process.exitCode=1;});
}

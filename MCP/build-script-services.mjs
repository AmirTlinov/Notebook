import { build } from "esbuild";
import { fileURLToPath } from "node:url";
import { readFile, mkdir, writeFile } from "node:fs/promises";

const root=fileURLToPath(new URL(".",import.meta.url));
const checking=process.argv.includes("--check");
async function resource(path,bytes) {
  const target=new URL(path,import.meta.url), expected=Buffer.from(bytes);
  if(checking) {
    const actual=await readFile(target).catch(()=>Buffer.alloc(0));
    if(!actual.equals(expected)) throw new Error("Generated resource is stale: "+path+"; run node MCP/build-script-services.mjs");
  } else {
    await mkdir(new URL(".",target),{recursive:true});
    await writeFile(target,expected);
  }
}
const markup=await build({absWorkingDir:root,entryPoints:["src/markup.ts"],bundle:true,format:"iife",platform:"neutral",target:"es2022",
  outfile:"../Sources/NotebookMarkupService/Resources/notebook-markup.js",legalComments:"eof",write:false});
await resource("../Sources/NotebookMarkupService/Resources/notebook-markup.js",markup.outputFiles[0].contents);
await resource("../Sources/NotebookMarkupService/Resources/marked-LICENSE.md",
  await readFile(new URL("node_modules/marked/LICENSE",import.meta.url)));
for (const name of ["parse5", "entities"]) {
  await resource(`../Sources/NotebookMarkupService/Resources/${name}-LICENSE.txt`,
    await readFile(new URL(`node_modules/${name}/LICENSE`,import.meta.url)));
}
const contract=await build({absWorkingDir:root,entryPoints:["src/sdk-contracts.ts"],bundle:true,format:"esm",platform:"node",target:"es2022",write:false});
const {sdkReference}=await import("data:text/javascript;base64,"+Buffer.from(contract.outputFiles[0].contents).toString("base64"));
await resource("../Sources/NotebookScriptHost/Resources/sdk-reference.json",JSON.stringify(sdkReference,null,2)+"\n");

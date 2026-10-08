import test from "node:test";
import assert from "node:assert/strict";
import { mkdir, mkdtemp, readdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { execFileSync, spawn } from "node:child_process";
import { createInterface } from "node:readline";

test("sidecar bundle initializes and exposes shared content tools without node_modules at runtime", {timeout:10000}, async () => {
  const root = await mkdtemp(join(tmpdir(), "notebook-tools-bundle-"));
  const output = join(root,"NotebookTools"), temporary = join(root,"target-temp");
  try {
    await mkdir(join(output,"dist/panel"),{recursive:true});
    await writeFile(join(output,"panel-bundle.json"),"obsolete panel bundle");
    await writeFile(join(output,"dist/panel/surface.wasm"),"obsolete browser surface");
    execFileSync(process.execPath, [new URL("../build-sidecar.mjs", import.meta.url).pathname, output, temporary]);
    assert.deepEqual((await readdir(output)).sort(),["dist","package.json"]);
    assert.deepEqual((await readdir(join(output,"dist"))).sort(),["index.mjs","launch-runtime.mjs"]);
    assert.deepEqual(await readdir(temporary),[],"Complete publication retires obsolete assets and staging");
    const child = spawn(process.execPath, [join(output, "dist/index.mjs")], {stdio:["pipe","pipe","pipe"], cwd:output});
    const reader = createInterface({input: child.stdout});
    const iterator = reader[Symbol.asyncIterator]();
    try {
      child.stdin.write(JSON.stringify({jsonrpc:"2.0",id:1,method:"initialize",params:{protocolVersion:"2025-11-25",capabilities:{},clientInfo:{name:"notebook-bundle-proof",version:"1"}}})+"\n");
      const initialized = JSON.parse((await iterator.next()).value!);
      assert.equal(initialized.result.serverInfo.name,"notebook");
      assert.equal(initialized.result.capabilities.resources,undefined);
      child.stdin.write(JSON.stringify({jsonrpc:"2.0",method:"notifications/initialized"})+"\n");
      child.stdin.write(JSON.stringify({jsonrpc:"2.0",id:2,method:"tools/list"})+"\n");
      const tools = JSON.parse((await iterator.next()).value!).result.tools as {name:string;_meta?:{ui?:{resourceUri?:string}}}[];
      const names = tools.map(tool=>tool.name);
      assert.deepEqual(names.sort(),["notebook_context","notebook_execute","notebook_import_document","notebook_import_document_resource","notebook_import_program","notebook_workspaces"]);
      assert.ok(tools.every(tool=>tool._meta?.ui===undefined));
    } finally { child.stdin.end(); reader.close(); child.kill(); }
  } finally { await rm(root,{recursive:true,force:true}); }
});

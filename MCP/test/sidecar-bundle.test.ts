import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { execFileSync, spawn } from "node:child_process";
import { createInterface } from "node:readline";

test("sidecar bundle initializes and exposes shared content tools without node_modules at runtime", {timeout:10000}, async () => {
  const root = await mkdtemp(join(tmpdir(), "notebook-tools-bundle-"));
  try {
    execFileSync(process.execPath, [new URL("../build-sidecar.mjs", import.meta.url).pathname, root]);
    const child = spawn(process.execPath, [join(root, "dist/index.mjs")], {stdio:["pipe","pipe","pipe"], cwd:root});
    const reader = createInterface({input: child.stdout});
    const iterator = reader[Symbol.asyncIterator]();
    try {
      child.stdin.write(JSON.stringify({jsonrpc:"2.0",id:1,method:"initialize",params:{protocolVersion:"2025-11-25",capabilities:{},clientInfo:{name:"notebook-bundle-proof",version:"1"}}})+"\n");
      const initialized = JSON.parse((await iterator.next()).value!);
      assert.equal(initialized.result.serverInfo.name,"notebook");
      child.stdin.write(JSON.stringify({jsonrpc:"2.0",method:"notifications/initialized"})+"\n");
      child.stdin.write(JSON.stringify({jsonrpc:"2.0",id:2,method:"tools/list"})+"\n");
      const names = JSON.parse((await iterator.next()).value!).result.tools.map((tool:{name:string})=>tool.name);
      for (const name of ["notebook_read_attention","notebook_apply","notebook_render","notebook_place"]) assert.ok(names.includes(name),name);
    } finally { child.stdin.end(); reader.close(); child.kill(); }
  } finally { await rm(root,{recursive:true,force:true}); }
});

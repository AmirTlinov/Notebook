import { serveStdio } from "@modelcontextprotocol/server/stdio";
import { realpathSync } from "node:fs";
import { fileURLToPath } from "node:url";

import { createServer } from "./server.js";

export function startStdio(options:Parameters<typeof createServer>[1]={}) {
  void serveStdio(() => createServer(undefined,options));
  console.error("Notebook MCP listens on stdio");
}

// The development entry has no production launch capability. Only the
// signed plugin launcher supplies its admitted runtime bootstrap callback.
if(process.argv[1]&&realpathSync(process.argv[1])===fileURLToPath(import.meta.url))startStdio();

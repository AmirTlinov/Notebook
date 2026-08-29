import { serveStdio } from "@modelcontextprotocol/server/stdio";

import { createServer } from "./server.js";

void serveStdio(() => createServer());
console.error("Tetrad MCP listens on stdio");

import { spawn } from "node:child_process";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

export class BridgeError extends Error {
  constructor(readonly detail: Record<string, unknown>) {
    super(String(detail.message ?? "Notebook bridge failed"));
  }
}

/** NotebookCore owns mutations and the consistent snapshot read under its lock. */
export function runBridge<T = Record<string, unknown>>(
  root: string,
  request: Record<string, unknown>,
): Promise<T> {
  const binary = process.env.NOTEBOOK_BRIDGE
    ?? resolve(dirname(fileURLToPath(import.meta.url)), "../../.build/out/Products/Debug/notebook-bridge");
  return new Promise((fulfill, reject) => {
    const child = spawn(binary, [], { stdio: ["pipe", "pipe", "pipe"] });
    const output: Buffer[] = [];
    const errors: Buffer[] = [];
    let bytes = 0;
    child.stdout.on("data", (chunk: Buffer) => {
      bytes += chunk.length;
      if (bytes > 64 * 1024 * 1024) child.kill();
      else output.push(chunk);
    });
    child.stderr.on("data", (chunk: Buffer) => errors.push(chunk));
    child.on("error", reject);
    child.on("close", (code) => {
      try {
        const result: unknown = JSON.parse(Buffer.concat(output).toString("utf8"));
        if (code !== 0) reject(new BridgeError(result as Record<string, unknown>));
        else fulfill(result as T);
      } catch {
        reject(new BridgeError({ code: "bridge_unavailable",
          message: Buffer.concat(errors).toString("utf8") || "Соберите Notebook bridge через MCP/run.sh." }));
      }
    });
    child.stdin.on("error", reject);
    child.stdin.end(JSON.stringify({ ...request, root }));
  });
}

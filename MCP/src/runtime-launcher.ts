import { execFile, spawn } from "node:child_process";
import { access } from "node:fs/promises";
import { constants, realpathSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { promisify } from "node:util";
import { BridgeError, defaultSocketPath, runBridge } from "./bridge.js";

export type RuntimeStatus = {
  kind: "notebookRuntime";
  ready: boolean;
  pid: number;
  state: "opening" | "ready" | "workspaceRequired" | "failed";
  protocolVersion: number;
  build: string;
};

/** LaunchServices preserves the signed app's CloudKit and keychain identity. */
export function launchRuntime(app: string): Promise<void> {
  return new Promise((fulfill, reject) => {
    const child = spawn("/usr/bin/open", ["-gj", app], { stdio: ["ignore", "ignore", "pipe"], timeout: 5_000 });
    let detail = "";
    child.stderr!.on("data", chunk => { detail = (detail + String(chunk)).slice(-4096); });
    child.once("error", reject);
    child.once("close", code => code === 0 ? fulfill()
      : reject(new Error(`Notebook runtime could not start: ${detail.trim() || `open exited ${code}`}`)));
  });
}

/** All clients join the same IPC owner. Native process admission owns the race. */
export async function ensureRuntime(app: string, socket: string, expectedBuild: string, options: {
  launch?: (app: string) => Promise<void>;
  timeoutMilliseconds?: number;
} = {}): Promise<RuntimeStatus> {
  const deadline = performance.now() + (options.timeoutMilliseconds ?? 10_000);
  let launched = false;
  do {
    try {
      const status = await runBridge<RuntimeStatus>(socket, { command: "runtimeStatus" },
        { deadline: Math.min(deadline, performance.now() + 750) });
      if (status?.kind !== "notebookRuntime" || typeof status.ready !== "boolean"
        || !Number.isSafeInteger(status.pid) || status.pid <= 0
        || !["opening", "ready", "workspaceRequired", "failed"].includes(status.state)) {
        throw new Error("Notebook IPC returned an incompatible runtime status.");
      }
      if (status.protocolVersion !== 1 || status.build !== expectedBuild) {
        throw new BridgeError({code:"runtime_update_required", message:
          `runtime_update_required: Active Notebook runtime build ${status.build ?? "unknown"} `
          + `(protocol ${status.protocolVersion ?? "unknown"}) differs from plugin build ${expectedBuild}. `
          + "Complete the runtime update before reconnecting the plugin."});
      }
      if (!status.ready) throw new BridgeError({code:"owner_unavailable",message:"Notebook runtime is draining accepted work."});
      return status;
    } catch (error) {
      if (error instanceof BridgeError
        && ["ipc_unauthorized", "runtime_update_required"].includes(String(error.detail.code))) throw error;
      if (!(error instanceof BridgeError)
        || !["ipc_unavailable", "ipc_timeout", "owner_unavailable"].includes(String(error.detail.code))) {
        throw new Error("The active Notebook owner does not support this plugin runtime. "
          + "Finish the Notebook runtime transition before reconnecting the plugin. "
          + (error instanceof Error ? error.message : String(error)), { cause: error });
      }
      if (!launched && error.detail.code === "ipc_unavailable") {
        launched = true;
        await (options.launch ?? launchRuntime)(app);
      }
    }
    const remaining = deadline - performance.now();
    if (remaining > 0) await new Promise(fulfill => setTimeout(fulfill, Math.min(100, remaining)));
  } while (performance.now() < deadline);
  throw new Error("The bundled Notebook runtime has not opened its IPC channel. "
    + "Reconnect the plugin after resolving its startup error.");
}

/** Bootstrap requests share one admission attempt. A later user retry starts
 * a fresh attempt; domain commands are never captured or replayed here. */
export function runtimeBootstrap(app:string,socket:string,expectedBuild:string,
  options:Parameters<typeof ensureRuntime>[3]={}):()=>Promise<RuntimeStatus> {
  let pending:Promise<RuntimeStatus>|undefined;
  return ()=>pending ??= ensureRuntime(app,socket,expectedBuild,options).finally(()=>{pending=undefined;});
}

async function main() {
  if (process.platform !== "darwin") throw new Error("Notebook runtime currently requires macOS.");
  const directory = dirname(fileURLToPath(import.meta.url));
  const app = resolve(directory, "../../../..");
  const entry = join(directory, "index.mjs");
  await access(join(app, "Contents/MacOS/NotebookRuntime"), constants.X_OK);
  await access(entry, constants.R_OK);
  const socket = defaultSocketPath();
  if (socket !== `/tmp/notebook-${process.getuid!()}/bridge.sock`) {
    throw new Error("The production Notebook plugin uses its default runtime socket. "
      + "Use MCP/run.sh with NOTEBOOK_SOCKET for an isolated development owner.");
  }
  process.env.NOTEBOOK_SOCKET = socket;
  const {stdout} = await promisify(execFile)("/usr/bin/plutil",
    ["-extract", "CFBundleVersion", "raw", "-o", "-", join(app, "Contents/Info.plist")],
    {timeout:2_000,maxBuffer:1024});
  const build = stdout.trim();
  if (!build) throw new Error("The bundled Notebook runtime has no build identity.");
  const bootstrapRuntime=runtimeBootstrap(app,socket,build);
  await bootstrapRuntime();
  // The launcher already runs in the bundled Node. Keep one stdio transport
  // and its normal signal/EOF lifetime; closing it does not stop the app owner.
  const {startStdio}=await import(pathToFileURL(entry).href);
  startStdio({bootstrapRuntime});
}

if (process.argv[1] && realpathSync(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch(error => { console.error(error instanceof Error ? error.message : error); process.exitCode = 1; });
}

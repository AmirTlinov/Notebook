import { randomUUID } from "node:crypto";
import { lstat } from "node:fs/promises";
import { createConnection } from "node:net";
import { dirname } from "node:path";

const maximumFrameBytes = 32 * 1024 * 1024;
const timeoutMilliseconds = 35_000;
export const defaultSocketPath = () => process.env.NOTEBOOK_SOCKET
  ?? `/tmp/notebook-${process.getuid!()}/bridge.sock`;

export class BridgeError extends Error {
  constructor(readonly detail: Record<string, unknown>) {
    super(String(detail.message ?? "Notebook IPC failed"));
  }
}

/** One bounded domain request to the Mac owner; no subprocess/store fallback exists. */
export async function runBridge<T = Record<string, unknown>>(
  socketPath: string,
  request: Record<string, unknown>,
): Promise<T> {
  const id = randomUUID();
  const packet = Buffer.from(JSON.stringify({ version: 1, id, request }));
  if (packet.length > maximumFrameBytes) throw new BridgeError({ code: "resource_limit", message: "IPC команда превышает 32 МиБ." });
  try {
    const [directory, socket] = await Promise.all([lstat(dirname(socketPath)), lstat(socketPath)]);
    const uid = process.getuid!();
    if (!directory.isDirectory() || directory.uid !== uid || (directory.mode & 0o777) !== 0o700
      || !socket.isSocket() || socket.uid !== uid || (socket.mode & 0o777) !== 0o600) {
      throw new BridgeError({ code: "ipc_unauthorized", message: "Notebook IPC требует закрытый пользовательский каталог 0700 и сокет 0600." });
    }
  } catch (error) {
    if (error instanceof BridgeError) throw error;
    throw new BridgeError({ code: "ipc_unavailable", message: "Канал связи с Notebook на Mac недоступен. Проверьте запуск совместимой сборки Mac-помощника: наличие процесса Notebook не подтверждает готовность IPC." });
  }
  return new Promise<T>((fulfill, reject) => {
    const socket = createConnection(socketPath);
    let settled = false;
    let size: number | undefined;
    let bytes = 0;
    const prefix: Buffer[] = [];
    let prefixBytes = 0;
    const chunks: Buffer[] = [];
    const finish = (error?: Error, value?: T) => {
      if (settled) return;
      settled = true; clearTimeout(timer); socket.destroy();
      if (error) reject(error); else fulfill(value!);
    };
    const timer = setTimeout(() => finish(new BridgeError({ code: "ipc_timeout",
      message: "Notebook ещё завершает принятый запрос. Проверьте тот же ID хода; тайм-аут не отменяет запись." })), timeoutMilliseconds);
    socket.once("connect", () => {
      const length = Buffer.alloc(4); length.writeUInt32BE(packet.length);
      socket.end(Buffer.concat([length, packet]));
    });
    socket.on("data", (chunk: Buffer) => {
      if (settled) return;
      if (size === undefined) {
        const needed = Math.min(4 - prefixBytes, chunk.length);
        prefix.push(chunk.subarray(0, needed)); prefixBytes += needed; chunk = chunk.subarray(needed);
        if (prefixBytes < 4) return;
        size = Buffer.concat(prefix).readUInt32BE(0);
        if (!size || size > maximumFrameBytes) {
          finish(new BridgeError({ code: "resource_limit", message: "Ответ IPC превышает допустимый размер." })); return;
        }
      }
      bytes += chunk.length;
      if (bytes > size) { finish(new BridgeError({ code: "ipc_protocol", message: "Ответ содержит лишнее IPC сообщение." })); return; }
      chunks.push(chunk);
      if (bytes !== size) return;
      try {
        const response = JSON.parse(Buffer.concat(chunks, size).toString("utf8")) as Record<string, any>;
        if (response.version !== 1 || String(response.id).toLowerCase() !== id) {
          throw new BridgeError({ code: "ipc_protocol", message: "Ответ принадлежит другому запросу или протоколу." });
        }
        if (response.error) throw new BridgeError(response.error);
        if (!("result" in response)) throw new BridgeError({ code: "ipc_protocol", message: "Ответ IPC не содержит результата." });
        finish(undefined, response.result as T);
      } catch (error) { finish(error instanceof BridgeError ? error : new BridgeError({ code: "ipc_protocol", message: "Ответ IPC повреждён." })); }
    });
    socket.once("error", () => finish(new BridgeError({ code: "ipc_unavailable", message: "Notebook helper прервал соединение. Проверьте сохранение по ID хода перед повтором." })));
    socket.once("end", () => { if (!settled) finish(new BridgeError({ code: "ipc_protocol", message: "Ответ IPC завершился до результата." })); });
  });
}

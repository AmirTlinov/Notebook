import { randomUUID } from "node:crypto";
import { lstat } from "node:fs/promises";
import { createConnection, type Socket } from "node:net";
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
  options: { deadline?: number } = {},
): Promise<T> {
  // A monotonic deadline may be shared by several calls belonging to one
  // tool response. It includes validation, admission, reply and image reads.
  const deadline = options.deadline ?? performance.now() + timeoutMilliseconds;
  const id = randomUUID();
  const packet = Buffer.from(JSON.stringify({ version: 1, id, request }));
  if (packet.length > maximumFrameBytes) throw new BridgeError({ code: "resource_limit", message: "IPC команда превышает 32 МиБ." });
  return new Promise<T>((fulfill, reject) => {
    let socket: Socket | undefined;
    let settled = false;
    let size: number | undefined;
    let bytes = 0;
    const prefix: Buffer[] = [];
    let prefixBytes = 0;
    const chunks: Buffer[] = [];
    const finish = (error?: Error, value?: T) => {
      if (settled) return;
      settled = true; clearTimeout(timer); socket?.destroy();
      if (error) reject(error); else fulfill(value!);
    };
    const timer = setTimeout(() => finish(new BridgeError({ code: "ipc_timeout",
      message: "Ответ Notebook не получен в пределах срока. Истечение срока не отменяет принятую запись." })), Math.max(0, deadline - performance.now()));
    void (async () => {
      try {
        const [directory, endpoint] = await Promise.all([lstat(dirname(socketPath)), lstat(socketPath)]);
        const uid = process.getuid!();
        if (!directory.isDirectory() || directory.uid !== uid || (directory.mode & 0o777) !== 0o700
          || !endpoint.isSocket() || endpoint.uid !== uid || (endpoint.mode & 0o777) !== 0o600) {
          throw new BridgeError({ code: "ipc_unauthorized", message: "Notebook IPC требует закрытый пользовательский каталог 0700 и сокет 0600." });
        }
      } catch (error) {
        finish(error instanceof BridgeError ? error : new BridgeError({ code: "ipc_unavailable", message: "Канал связи с Notebook на Mac недоступен. Проверьте запуск совместимой сборки Mac-помощника: наличие процесса Notebook не подтверждает готовность IPC." }));
        return;
      }
      if (settled) return;
      if (performance.now() >= deadline) {
        finish(new BridgeError({ code: "ipc_timeout", message: "Срок ответа истёк до отправки запроса Notebook." }));
        return;
      }
      socket = createConnection(socketPath);
      socket.once("connect", () => {
        const length = Buffer.alloc(4); length.writeUInt32BE(packet.length);
        socket!.end(Buffer.concat([length, packet]));
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
    })().catch(error => finish(error instanceof Error ? error : new Error(String(error))));
  });
}

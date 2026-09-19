import {open, realpath} from 'node:fs/promises';
import {constants} from 'node:fs';
import {createHash} from 'node:crypto';
import {resolve, sep, extname} from 'node:path';

export const partBytes = 4 * 1024 * 1024;
export const validProgramPath = path => typeof path === 'string' && path.length <= 512
  && /^[A-Za-z0-9_.@/-]+$/.test(path) && path.split('/').every(p => p && p !== '.' && p !== '..');
const types = {html:'text/html',htm:'text/html',css:'text/css',js:'text/javascript',mjs:'text/javascript',
  json:'application/json',map:'application/json',svg:'image/svg+xml',png:'image/png',jpg:'image/jpeg',jpeg:'image/jpeg',
  webp:'image/webp',gif:'image/gif',avif:'image/avif',woff:'font/woff',woff2:'font/woff2',ttf:'font/ttf',otf:'font/otf',
  mp4:'video/mp4',webm:'video/webm',mp3:'audio/mpeg',m4a:'audio/mp4',wav:'audio/wav',ogg:'audio/ogg',wasm:'application/wasm',
  gltf:'model/gltf+json',glb:'model/gltf-binary',pdf:'application/pdf',tex:'application/x-tex',gz:'application/gzip',csv:'text/csv',txt:'text/plain'};
export const programMIME = path => types[extname(path).slice(1).toLowerCase()] ?? 'application/octet-stream';
export function canonicalProgramJSON(value) {
  return JSON.stringify(value, (_, item) => item && typeof item === 'object' && !Array.isArray(item)
    ? Object.fromEntries(Object.keys(item).sort().map(key => [key, item[key]])) : item);
}
const hash = value => createHash('sha256').update(value).digest('hex');

/** File metadata only. The existing Mac writer later stages bounded file ranges;
 * no bytes enter QuickJS arguments, model context or this descriptor's JSON. */
export async function prepareProgramPackage({directory, files, html, css, javaScript, module = true}, {signal} = {}) {
  if (!Array.isArray(files) || !files.length || files.length > 4096 || files.some(p => !validProgramPath(p))
    || new Set(files).size !== files.length || (!html && !javaScript) || typeof module !== 'boolean') {
    throw new Error('A program package needs a bounded unique file namespace and an HTML or JavaScript entry');
  }
  for (const [entry, mime] of [[html,'text/html'],[css,'text/css'],[javaScript,'text/javascript']]) {
    if (entry !== undefined && (!files.includes(entry) || programMIME(entry) !== mime)) throw new Error('Invalid program entry or MIME');
  }
  const root = await realpath(directory), entries = [], sources = [];
  let partCount = 0;
  const buffer = Buffer.allocUnsafe(partBytes);
  for (const path of [...files].sort()) {
    signal?.throwIfAborted();
    const sourcePath = await realpath(resolve(root, path));
    if (!sourcePath.startsWith(root + sep)) throw new Error('Program source escapes its directory');
    // Opening a FIFO must not wait for a writer before isFile() can reject it.
    const file = await open(sourcePath, constants.O_RDONLY | constants.O_NONBLOCK | constants.O_NOFOLLOW);
    try {
      const before = await file.stat({bigint:true}), parts = [];
      if (!before.isFile() || before.size > BigInt(Number.MAX_SAFE_INTEGER)) throw new Error('Program sources must be regular files');
      let position = 0;
      while (position < Number(before.size)) {
        signal?.throwIfAborted();
        const count = Math.min(partBytes, Number(before.size) - position);
        let filled = 0;
        while (filled < count) {
          const read = await file.read(buffer, filled, count - filled, position + filled);
          if (!read.bytesRead) throw new Error('Program source changed while preparing');
          filled += read.bytesRead;
        }
        if (++partCount > 16384) throw new Error('Program package has too many parts');
        parts.push({sha256:hash(buffer.subarray(0,count)),byteCount:count});
        position += count;
      }
      const after = await file.stat({bigint:true});
      if (before.size !== after.size || before.mtimeNs !== after.mtimeNs || before.ctimeNs !== after.ctimeNs) {
        throw new Error('Program source changed while preparing');
      }
      entries.push({path,mimeType:programMIME(path),byteCount:position,parts});
      sources.push({path,sourcePath});
    } finally { await file.close(); }
  }
  const packageValue = {format:1,html,css,javaScript,module,files:entries};
  const encoded = canonicalProgramJSON(packageValue);
  if (Buffer.byteLength(encoded) > 1048576) throw new Error('Program package manifest exceeds its metadata budget');
  return {packageHash:hash(encoded),package:JSON.parse(encoded),sources};
}

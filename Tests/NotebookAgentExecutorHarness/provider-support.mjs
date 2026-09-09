import { deflateSync } from 'node:zlib';

function pngFixture() {
  const width = 16, height = 8;
  const rows = Buffer.alloc((width * 4 + 1) * height);
  for (let y = 0; y < height; y++) for (let x = 0; x < width; x++) {
    const i = y * (width * 4 + 1) + 1 + x * 4;
    rows[i] = x * 16; rows[i + 1] = y * 32; rows[i + 2] = 127; rows[i + 3] = 255;
  }
  const chunk = (name, data) => {
    const type = Buffer.from(name), length = Buffer.alloc(4), checksum = Buffer.alloc(4);
    length.writeUInt32BE(data.length); let crc = 0xffffffff;
    for (const byte of Buffer.concat([type, data])) { crc ^= byte; for (let b = 0; b < 8; b++) crc = (crc >>> 1) ^ (crc & 1 ? 0xedb88320 : 0); }
    checksum.writeUInt32BE((crc ^ 0xffffffff) >>> 0); return Buffer.concat([length, type, data, checksum]);
  };
  const header = Buffer.alloc(13); header.writeUInt32BE(width); header.writeUInt32BE(height, 4); header[8] = 8; header[9] = 6;
  return Buffer.concat([Buffer.from([137,80,78,71,13,10,26,10]), chunk('IHDR', header), chunk('IDAT', deflateSync(rows)), chunk('IEND', Buffer.alloc(0))]);
}
export const selectedPNG = pngFixture();
export function imageItems(value) {
  if (Array.isArray(value)) return value.flatMap(imageItems);
  if (!value || typeof value !== 'object') return [];
  return [...(value.type === 'input_image' ? [value] : []), ...Object.values(value).flatMap(imageItems)];
}

export function event(response, value) { response.write(`event: ${value.type}\ndata: ${JSON.stringify(value)}\n\n`); }
export function respond(response, item) {
  const result = { id: 'resp_contract', object: 'response', created_at: 0, status: 'completed', output: [item], usage: { input_tokens: 1, output_tokens: 3, total_tokens: 4 } };
  response.writeHead(200, { 'content-type': 'text/event-stream' });
  event(response, { type: 'response.created', response: { ...result, status: 'in_progress', output: [] } });
  event(response, { type: 'response.output_item.added', output_index: 0, item: item.type === 'message' ? { ...item, content: [] } : { ...item, arguments: '' } });
  if (item.type === 'function_call') {
    event(response, { type: 'response.function_call_arguments.delta', item_id: item.id, output_index: 0, delta: item.arguments });
    event(response, { type: 'response.function_call_arguments.done', item_id: item.id, output_index: 0, arguments: item.arguments });
  } else {
    event(response, { type: 'response.content_part.added', output_index: 0, item_id: item.id, content_index: 0, part: { type: 'output_text', text: '', annotations: [] } });
    event(response, { type: 'response.output_text.delta', output_index: 0, item_id: item.id, content_index: 0, delta: item.content[0].text });
  }
  event(response, { type: 'response.output_item.done', output_index: 0, item });
  event(response, { type: 'response.completed', response: result });
  response.end();
}
export function textItem(text) { return { id: 'msg_contract', type: 'message', role: 'assistant', content: [{ type: 'output_text', text, annotations: [] }] }; }
export function catalog(request) {
  return [...(request.tools ?? []), ...(request.input ?? []).filter(x => x.type === 'additional_tools').flatMap(x => x.tools ?? [])];
}

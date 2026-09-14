// Run this body with notebook_execute(start). It uses only the public nb API.
const scene = (await nb.board(args?.boardID ? { id: args.boardID } : {})).values[0];
if (!scene?.header || !scene.boardID) throw new Error('No addressed board in the public context');
const boardID = scene.boardID;
const documentID = await nb.id('canonical-control-document');
const title = args?.title ?? 'Notebook canonical control';
const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
function asciiBase64(text) {
  const output = [];
  for (let i = 0; i < text.length; i += 3) {
    const a = text.charCodeAt(i), b = i + 1 < text.length ? text.charCodeAt(i + 1) : 0;
    const c = i + 2 < text.length ? text.charCodeAt(i + 2) : 0;
    if (a > 127 || b > 127 || c > 127) throw new Error('The controlled SVG generator is ASCII-only');
    const bits = (a << 16) | (b << 8) | c;
    output.push(alphabet[(bits >>> 18) & 63] + alphabet[(bits >>> 12) & 63]
      + (i + 1 < text.length ? alphabet[(bits >>> 6) & 63] : '=')
      + (i + 2 < text.length ? alphabet[bits & 63] : '='));
  }
  return output.join('');
}
const path = Array.from({ length: 12000 }, (_, i) => `L${i % 451}.${i % 10},${i % 157}.${(i + 3) % 10}`).join(' ');
const blocks = Array.from({ length: 140 }, (_, index) => {
  let source;
  if (index % 4 === 3) {
    const svg = `<svg xmlns='http://www.w3.org/2000/svg' width='451' height='158' viewBox='0 0 451 158'><path d='M0,0 ${path}' fill='none' stroke='#173d69' stroke-width='0.02'/><text x='20' y='40'>Figure ${index}</text></svg>`;
    source = `<div><h2>Figure ${index}</h2><img width='451' height='158' src='data:image/svg+xml;base64,${asciiBase64(svg)}'><p>Measured illustration ${index}.</p></div>`;
  } else {
    const formulas = Array.from({ length: 4 }, (_, n) => `\\(x_{${index},${n}}=\\frac{a^2+b^2}{1+e^{-t}}\\)`).join(' ');
    const paragraph = `<p>Source ${index}: A measured paragraph describes a state transition, its physical address, and an immutable result. ${formulas}</p>`;
    const navigation = index === 0
      ? `<p><a href='#acceptance-distant'>К дальней главе</a> · <a href='#missing-section'>Отсутствующий раздел</a></p>`
      : index === 136 ? `<p><a href='#acceptance-contents'>К оглавлению</a></p>` : '';
    const anchor = index === 0 ? " id='acceptance-contents'" : index === 136 ? " id='acceptance-distant'" : '';
    source = `<div><h2${anchor}>Chapter ${index}</h2>${navigation}${paragraph.repeat(4)}</div>`;
  }
  return { id: `part-${index}`, kind: 'markdown', source };
});
const formulaCount = blocks.reduce((n, block) => n + (block.source.match(/\\\(/g) ?? []).length, 0);
const svgCount = blocks.filter(block => block.source.includes('data:image/svg+xml;base64,')).length;
const sourceCharacters = blocks.reduce((n, block) => n + block.source.length, 0);
if (blocks.length !== 140 || formulaCount !== 1680 || svgCount !== 35 || sourceCharacters <= 6 * 1024 * 1024) {
  throw new Error('The canonical control changed its source size or inventory');
}
const saved = await nb.transaction('canonical-control-create', {
  summary: 'Контрольный документ: 140 блоков, 35 SVG, 1680 формул',
  expected: [
    { target: { kind: 'board', id: boardID }, revision: scene.boardContentRevisions[boardID.toLowerCase()] },
    { target: { kind: 'workspace', id: scene.header.rootBoardID }, revision: scene.header.stamp.counter + '@' + scene.header.stamp.actor.toLowerCase() }
  ],
  operations: [{ kind: 'createDocument', target: { kind: 'board', id: boardID }, id: documentID,
    values: { title, center: args?.center ?? { tileX: 0, tileY: 0, localX: 0, localY: 0 }, paperSize: 'a4', blocks } }]
});
const first = await nb.document({ id: documentID, blockID: 'part-0' });
const distant = await nb.document({ id: documentID, blockID: 'part-136' });
if (first?.values?.[0]?.block?.id !== 'part-0' || distant?.values?.[0]?.block?.id !== 'part-136') {
  throw new Error('The two addressed public reads did not return the committed document blocks');
}
await emit({ documentID, boardID, title, blockCount: blocks.length, svgCount, formulaCount, sourceCharacters,
  actionIDs: saved.map(value => value.receipt.id), addressedReadConfirmed: true,
  outwardLink: 'К дальней главе', returningLink: 'К оглавлению' });

import { marked } from "marked";
import { parseFragment, serializeOuter, type DefaultTreeAdapterMap } from "parse5";
import type { DocumentDocument } from "./domain.js";

type Node = DefaultTreeAdapterMap["childNode"];
type Element = DefaultTreeAdapterMap["element"];
export interface DocumentExportAsset {
  name: string;
  mediaType: "image/svg+xml" | "image/png" | "image/jpeg";
  data: string;
}
/** One-based, inclusive lines in the exact generated document.tex, not lines
 * in Markdown. SyncTeX addresses these lines; block IDs are never TeX tokens. */
export interface DocumentPrintSourceRange { blockID: string; firstLine: number; lastLine: number; sourceOffsets: number[] }
export interface DocumentExport {
  source: string;
  assets: DocumentExportAsset[];
  sourceRanges: DocumentPrintSourceRange[];
}

/** One print preparation owns Markdown and its embedded HTML. Images remain
 * data-only capabilities; the sandboxed compiler renders them before TeX runs. */
export function documentExport(document: DocumentDocument, programPointScale = 0.75): DocumentExport {
  if (!Number.isFinite(programPointScale) || programPointScale <= 0 || programPointScale > 10) throw new Error("invalid_program_scale");
  const printPackages = ["amsmath", "amssymb", "booktabs", "longtable", "array", "graphicx", "xcolor", "geometry", "hyperref"];
  const supplied = document.preamble.trim();
  const packages = new Set<string>(["geometry"]);
  // Authored TeX is opaque: retain its complete existing macro environment.
  // Generated Markdown only needs dependencies of the constructs we emit.
  let authoredTeX = Boolean(supplied);
  const assets: DocumentExportAsset[] = [];
  const images = new Map<string, DocumentExportAsset>();
  const anchors = new Set<string>();
  const emittedAnchors = new Set<string>();
  let imageBytes = 0;
  let restoreMath = (value: string) => value;
  // Base64 is an opaque resource, not millions of HTML tokenizer transitions.
  // Restore the exact attribute/text values before interpreting the parsed DOM,
  // including examples inside code fences. Tokens cannot collide with authored text.
  let imageToken = "NOTEBOOKEMBEDDEDIMAGE";
  while (document.blocks.some(block => block.source.includes(imageToken))) imageToken += "X";
  const encodedImages: string[] = [];
  const tokenPattern = new RegExp(`${imageToken}(\\d+)END`, "g");
  const restoreImages = (value: string) => value.replace(tokenPattern, (token, index: string) => encodedImages[Number(index)] ?? token);
  let markerPrefix = "NOTEBOOKSOURCEOFFSET";
  while (document.blocks.some(block => block.source.includes(markerPrefix))) markerPrefix += "X";
  const rendered = document.blocks.map(block => {
    if (block.kind !== "markdown") {
      if (block.kind === "tex" || block.kind === "latex") authoredTeX = true;
      return { block, fragment: null, nodes: [] as Node[], restoreMath: (value: string) => value };
    }
    const normalized = replaceMapped(block.source, /\r\n|\r/g, () => "\n");
    const compact = replaceMapped(normalized.text, /data:image\/(?:svg\+xml|png|jpeg)(?:;charset=[^;,\s]+)?;base64,[A-Za-z0-9+/=]+/gi, value => {
      const token = `${imageToken}${encodedImages.length}END`; encodedImages.push(value); return token;
    });
    const protectedMath = protectMath(compact.text);
    authoredTeX ||= protectedMath.hasMath;
    const tokens = marked.lexer(protectedMath.source, { gfm: true });
    let cursor = 0;
    // Top-level Markdown tokens retain the nearest authored paragraph. Keep
    // one HTML parse so embedded HTML containers/tables retain their semantics.
    const html = tokens.map(token => {
      const start = protectedMath.source.indexOf(token.raw, cursor);
      if (start < cursor) throw new Error("print_source_map_invalid: Markdown token lost its source");
      cursor = start + token.raw.length;
      const offset = normalized.originalOffset(compact.originalOffset(protectedMath.originalOffset(start)));
      return `<!--${markerPrefix}${offset}-->` + marked.parser([token], { gfm: true });
    }).join("");
    const fragment = parseFragment(html);
    const nodes = descendants(fragment.childNodes);
    for (const node of nodes) {
      if ("value" in node) node.value = restoreImages(node.value);
      if ("attrs" in node) for (const attr of node.attrs) attr.value = restoreImages(attr.value);
    }
    return { block, fragment, nodes, restoreMath: (value: string) => protectedMath.restore(value, restoreImages) };
  });
  // Explicit destinations across the whole document reserve their addresses
  // before implicit headings are named, just like the live document owner.
  for (const { nodes } of rendered) for (const node of nodes) {
    if (!("tagName" in node)) continue;
    const name = attribute(node, "id") || (node.tagName === "a" ? attribute(node, "name") : "");
    if (name) anchors.add(name);
  }
  const suffixes = new Map<string, number>();
  for (const { nodes, restoreMath } of rendered) for (const node of nodes) {
    if (!("tagName" in node) || !/^h[1-6]$/.test(node.tagName) || attribute(node, "id")) continue;
    const headingText = restoreMath(plainText(node));
    const stem = headingText.trim().toLowerCase().replace(/[^\p{L}\p{N}\p{M}_\s-]/gu, "").replace(/\s/g, "-") || "section";
    let suffix = suffixes.get(stem) ?? 0, id = suffix ? `${stem}-${suffix}` : stem;
    while (anchors.has(id)) id = `${stem}-${++suffix}`;
    node.attrs.push({ name: "id", value: id }); anchors.add(id); suffixes.set(stem, suffix + 1);
  }

  function image(source: string, width?: number, height?: number): string {
    packages.add("graphicx");
    const match = /^data:(image\/(?:svg\+xml|png|jpeg))(?:;charset=[^;,]+)?(;base64)?,([\s\S]*)$/i.exec(source);
    if (!match) throw new Error("export_image_unsupported: Print images must be embedded SVG, PNG or JPEG; remote URLs and user-file paths are unavailable.");
    const mediaType = match[1]!.toLowerCase() as DocumentExportAsset["mediaType"];
    const data = match[2] ? match[3]!.replace(/\s/g, "") : base64UTF8(decodeURIComponent(match[3]!));
    if (!/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(data) || !data) {
      throw new Error("export_image_invalid: Embedded image has invalid base64.");
    }
    const key = `${mediaType}:${data}`;
    let asset = images.get(key);
    if (!asset) {
      const bytes = Math.floor(data.length / 4) * 3 - (data.endsWith("==") ? 2 : data.endsWith("=") ? 1 : 0);
      imageBytes += bytes;
      if (assets.length >= 128 || bytes > 8 * 1024 * 1024 || imageBytes > 16 * 1024 * 1024) {
        throw new Error("resource_limit: Print images exceed 128 images, 8 MiB per image or 16 MiB total.");
      }
      asset = { name: `notebook-image-${assets.length}.pdf`, mediaType, data };
      assets.push(asset); images.set(key, asset);
    }
    // CSS pixels become physical print points. Oversized images fit the paper
    // without changing their aspect ratio. The asset keeps its intrinsic size.
    const dimensions = [width ? `width=${(width * 0.75).toFixed(4)}pt` : "",
      height ? `height=${(height * 0.75).toFixed(4)}pt` : "", !width && !height ? "scale=0.75" : "", "keepaspectratio"].filter(Boolean);
    return `\\NotebookPrintImage[${dimensions.join(",")}]{${asset.name}}`;
  }
  function target(node: Element): string {
    const name = attribute(node, "id") || (node.tagName === "a" ? attribute(node, "name") : "");
    if (!name || emittedAnchors.has(name)) return "";
    packages.add("hyperref"); packages.add("xcolor");
    emittedAnchors.add(name);
    return `\\hypertarget{${anchorName(name)}}{}`;
  }
  function renderNodes(nodes: Node[]): string { return nodes.map(renderNode).join(""); }
  function renderNode(node: Node): string {
    if (node.nodeName === "#comment" && "data" in node && new RegExp(`^${markerPrefix}\\d+$`).test(node.data)) return `\uE000${node.data}\uE001`;
    if ("value" in node) return renderText(node.value.replace(/\s+/g, " "));
    if (!("tagName" in node)) return "";
    const tag = node.tagName;
    if (["script", "style", "template", "noscript"].includes(tag)) return "";
    if (attribute(node, "hidden") !== null || /(?:^|;)\s*display\s*:\s*none\s*(?:;|$)/i.test(attribute(node, "style") ?? "")) return "";
    if (tag === "svg") return target(node) + image(`data:image/svg+xml;base64,${base64UTF8(restoreMath(serializeOuter(node)))}`,
      length(attribute(node, "width")), length(attribute(node, "height")));
    if (tag === "img") return target(node) + image(attribute(node, "src") ?? "", length(attribute(node, "width")), length(attribute(node, "height")));
    if (["iframe", "object", "embed", "canvas", "video", "audio"].includes(tag)) {
      throw new Error(`export_content_unsupported: ${tag} has no immutable print content.`);
    }
    const prefix = target(node);
    if (tag === "pre") return `${prefix}\n\\begin{verbatim}\n${restoreMath(plainText(node))}\n\\end{verbatim}\n`;
    if (tag === "table") {
      packages.add("booktabs"); packages.add("longtable"); packages.add("array");
      const rows = descendants(node.childNodes).filter((child): child is Element => "tagName" in child && child.tagName === "tr");
      const cells = rows.map(row => row.childNodes.filter((child): child is Element => "tagName" in child && ["td", "th"].includes(child.tagName)));
      for (const cell of cells.flat()) if (Number(attribute(cell, "colspan") ?? 1) !== 1 || Number(attribute(cell, "rowspan") ?? 1) !== 1) {
        throw new Error("export_table_unsupported: Merged table cells require an explicit LaTeX table.");
      }
      const columns = Math.max(1, ...cells.map(row => row.length));
      return `\n${prefix}\\begin{longtable}{${"l".repeat(columns)}}\n\\toprule\n${cells.map(row => row.map(cell => renderNodes(cell.childNodes)).join(" & ") + " \\\\").join("\n")}\n\\bottomrule\n\\end{longtable}\n`;
    }
    const body = renderNodes(node.childNodes);
    if (/^h[1-6]$/.test(tag)) {
      const command = ["section", "subsection", "subsubsection", "paragraph", "subparagraph", "subparagraph"][Number(tag[1]) - 1];
      return `\n${prefix}\\${command}{${body.trim()}}\n`;
    }
    switch (tag) {
    case "a": {
      const href = attribute(node, "href");
      if (!href) return prefix + body;
      if (href.startsWith("#")) {
        const destination = decodeURIComponent(href.slice(1));
        // Keep a missing destination visibly identified; never create an
        // annotation that silently lands at page one.
        if (!anchors.has(destination)) return `${prefix}${body}\\textsuperscript{[недоступная ссылка]}`;
        packages.add("hyperref"); packages.add("xcolor");
        return `${prefix}\\hyperlink{${anchorName(destination)}}{${body}}`;
      }
      if (!/^(?:https?:|mailto:)/i.test(href)) throw new Error("export_link_unsupported: Only document anchors, HTTPS/HTTP and mailto links can be printed.");
      packages.add("hyperref"); packages.add("xcolor");
      return `${prefix}\\href{${escapeURL(href)}}{${body}}`;
    }
    case "p": return `\n\\par\n${prefix}${body.trim()}\\par\n`;
    case "br": return "\\\\\n";
    case "hr": return "\n\\medskip\\hrule\\medskip\n";
    case "strong": case "b": return `${prefix}\\textbf{${body}}`;
    case "em": case "i": return `${prefix}\\emph{${body}}`;
    case "code": case "kbd": case "samp": return `${prefix}\\texttt{${escapeTeX(restoreMath(plainText(node)))}}`;
    case "u": return `${prefix}\\underline{${body}}`;
    case "sub": return `${prefix}\\textsubscript{${body}}`;
    case "sup": return `${prefix}\\textsuperscript{${body}}`;
    case "blockquote": return `\n${prefix}\\begin{quote}${body}\\end{quote}\n`;
    case "ul": case "ol": return `\n${prefix}\\begin{${tag === "ol" ? "enumerate" : "itemize"}}${body}\\end{${tag === "ol" ? "enumerate" : "itemize"}}\n`;
    case "li": return `\n${prefix}\\item ${body.trim()}\n`;

    case "div": case "section": case "article": case "header": case "footer": case "main": case "figure": case "figcaption":
      return `\n\\par\n${prefix}${body}\\par\n`;
    default: return prefix + body;
    }
  }

  const mappedOffsets = new Map<string, number[]>();
  const body = rendered.map(({ block, fragment, restoreMath: restore }) => {
    if (block.kind === "tex") return block.source;
    if (block.kind === "latex") {
      // A formula block keeps its historical math semantics. Full LaTeX uses
      // the explicit tex kind, never a heuristic Markdown/TeX round trip.
      return /^\s*(\$\$|\\\[|\\begin\s*\{(?:equation|align|alignat|gather|multline|flalign)\*?\})/.test(block.source)
        ? block.source : `\\[${block.source}\\]`;
    }
    if (block.kind === "interactive") {
      // Breakable, exact-height print slots. The existing native program keeps
      // its viewport; sourceOffset addresses each consecutive page fragment.
      const height = (block.height || 320) * programPointScale;
      // This is the actual compiled source, not a second editable program.
      // Comments expose the owner and its code without executing it in TeX.
      // Neutralize ^^ translation even in comments, and prefix every line.
      const comment = (text: string) => text.replace(/\r\n?/g, "\n")
        .replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f^]/g, character => `\\u${character.charCodeAt(0).toString(16).padStart(4, "0")}`)
        .split("\n").map(line => "% " + line).join("\n");
      const code = block.programPackage
        ? [`Package SHA-256: ${block.programPackage}`, "Open this program in the source menu to inspect its files."]
        : ["HTML", block.html, "CSS", block.css, "JavaScript", block.javaScript];
      const rows: string[] = [comment(`Notebook interactive block: ${JSON.stringify(block.id)}\nHTML/CSS/JavaScript executes in Notebook; TeX reserves the physical slot.\n${code.join("\n")}\nInitial state: ${JSON.stringify(block.initialState)}\nEnd Notebook program source`), "\\par"];
      for (let y = 0; y < height; y += 12) rows.push(`\\nointerlineskip\\hbox to\\linewidth{\\vrule width0pt height${Math.min(12, height-y).toFixed(6)}bp depth0pt\\hfil}\\penalty0`);
      rows.push("\\par"); return rows.join("\n");
    }
    restoreMath = restore;
    let text = restore(renderNodes(fragment!.childNodes));
    const offsets: number[] = [0];
    let currentOffset = 0, generatedLine = 0;
    text = text.replace(new RegExp(`\\uE000${markerPrefix}(\\d+)\\uE001|\\n`, "g"), (value, offset: string | undefined) => {
      if (offset !== undefined) { currentOffset = Number(offset); offsets[generatedLine] = currentOffset; return ""; }
      offsets[++generatedLine] = currentOffset; return value;
    });
    mappedOffsets.set(block.id, offsets);
    return text.trim() ? text : "\\noindent\\mbox{}\\par";
  });
  let preamble = /\\documentclass(?:\[[^\]]*\])?\{/.test(supplied) ? supplied : ["\\documentclass[12pt]{article}",
    "\\usepackage{fontspec}", "\\setmainfont{Libertinus Serif}", supplied].filter(Boolean).join("\n");
  if (/\\(?:begin|end)\s*\{document\}/.test(preamble)) throw new Error("preamble задаёт класс и пакеты; begin/end document принадлежат экспортёру.");
  for (const name of printPackages) {
    if (!authoredTeX && !packages.has(name)) continue;
    if (!new RegExp(String.raw`\\(?:usepackage|RequirePackage)(?:\[[^\]]*\])?\{[^}]*\b${name}\b[^}]*\}`).test(preamble)) {
      preamble += `\n\\usepackage${name === "hyperref" ? "[colorlinks=true,linkcolor=black,urlcolor=blue]" : ""}{${name}}`;
    }
  }
  preamble += `\n\\geometry{${document.paperSize === "letter" ? "letterpaper,margin=1in" : "a4paper,margin=25mm"}}`;
  if (assets.length) preamble += String.raw`
\newsavebox{\NotebookExportImageBox}
\newcommand{\NotebookPrintImage}[2][]{\begingroup
\sbox{\NotebookExportImageBox}{\includegraphics[#1]{#2}}%
\ifdim\wd\NotebookExportImageBox>\linewidth
\sbox{\NotebookExportImageBox}{\resizebox{\linewidth}{!}{\usebox{\NotebookExportImageBox}}}\fi
\ifdim\ht\NotebookExportImageBox>0.9\textheight
\resizebox{!}{0.9\textheight}{\usebox{\NotebookExportImageBox}}%
\else\usebox{\NotebookExportImageBox}\fi\endgroup}`;

  // The pinned SVG renderer emits PDF 1.7. The output driver must declare the
  // same supported version before importing its first image, on page one.
  const parts = [preamble, "\\begin{document}", "\\special{pdf:minorversion 7}"];
  // Build the mapping while assembling the source. Searching for block text
  // afterwards is ambiguous for repeated paragraphs and raw TeX macros.
  let line = parts.reduce((count, part) => count + newlineCount(part) + 2, 1);
  const sourceRanges = body.map((text, index) => {
    const firstLine = line, block = document.blocks[index]!;
    let sourceOffsets: number[];
    if (block.kind === "markdown") sourceOffsets = mappedOffsets.get(block.id)!;
    else {
      let offset = 0;
      sourceOffsets = block.kind === "interactive" ? [0] : block.source.split("\n").map(value => { const start = offset; offset += value.length + 1; return start; });
    }
    const count = newlineCount(text) + 2;
    if (count > 200_000) throw new Error("resource_limit: Print source exceeds 200000 mapped lines per block");
    sourceOffsets = Array.from({ length: count }, (_, index) => sourceOffsets[Math.min(index, sourceOffsets.length - 1)] ?? 0);
    parts.push(text);
    line += newlineCount(text) + 2;
    return { blockID: block.id, firstLine, lastLine: line - 1, sourceOffsets };
  });
  parts.push("\\end{document}", "");
  return { source: parts.join("\n\n"), assets, sourceRanges };
}
export function documentTeX(document: DocumentDocument): string { return documentExport(document).source; }

function newlineCount(value: string): number {
  let count = 0;
  for (let index = 0; index < value.length; index++) if (value.charCodeAt(index) === 10) count++;
  return count;
}

function attribute(node: Element, name: string): string | null { return node.attrs.find(value => value.name === name)?.value ?? null; }
function descendants(nodes: Node[]): Node[] {
  const result: Node[] = [], pending = nodes.map(node => ({ node, depth: 1 })).reverse();
  while (pending.length) {
    const { node, depth } = pending.pop()!; result.push(node);
    if (depth > 256 || result.length > 200_000) throw new Error("resource_limit: Print content exceeds 256 nested levels or 200000 HTML nodes.");
    if ("childNodes" in node) for (let index = node.childNodes.length - 1; index >= 0; index--) pending.push({ node: node.childNodes[index]!, depth: depth + 1 });
  }
  return result;
}
function plainText(node: Node): string {
  return "value" in node ? node.value : "childNodes" in node ? node.childNodes.map(plainText).join("") : "";
}
function length(value: string | null): number | undefined {
  if (!value) return undefined;
  const match = /^\s*(\d+(?:\.\d+)?)\s*(px|pt|in|cm|mm)?\s*$/.exec(value);
  if (!match) return undefined;
  const number = Number(match[1]) * ({ px: 1, pt: 4 / 3, in: 96, cm: 96 / 2.54, mm: 96 / 25.4 }[match[2] ?? "px"]!);
  return number > 0 && number <= 16384 ? number : undefined;
}
function anchorName(value: string): string { return "nb-" + Array.from(value).map(character => character.codePointAt(0)!.toString(16)).join("-"); }
function escapeTeX(value: string): string {
  return value.replace(/[\\{}#$%&_~^]/g, character => ({ "\\": "\\textbackslash{}", "{": "\\{", "}": "\\}", "#": "\\#", "$": "\\$", "%": "\\%", "&": "\\&", "_": "\\_", "~": "\\textasciitilde{}", "^": "\\textasciicircum{}" })[character]!);
}
function escapeURL(value: string): string { return value.replace(/[{}%#\\]/g, character => `\\${character}`); }
function renderText(value: string): string { return escapeTeX(value); }
function replaceMapped(source: string, pattern: RegExp, replace: (value: string) => string) {
  const spans: Array<{ start: number; end: number; sourceStart: number; sourceEnd: number }> = [];
  let delta = 0;
  const text = source.replace(pattern, (value: string, offset: number) => {
    const result = replace(value), start = offset + delta;
    spans.push({ start, end: start + result.length, sourceStart: offset, sourceEnd: offset + value.length });
    delta += result.length - value.length; return result;
  });
  return { text, originalOffset(offset: number): number {
    let low = 0, high = spans.length;
    while (low < high) { const mid = (low + high) >>> 1; if (spans[mid]!.start <= offset) low = mid + 1; else high = mid; }
    const span = spans[low - 1];
    return !span ? offset : offset < span.end ? span.sourceStart : offset + span.sourceEnd - span.end;
  } };
}
function protectMath(source: string) {
  let prefix = "NOTEBOOKTEXMATH"; while (source.includes(prefix)) prefix += "X";
  const segments: Array<[string, string]> = [];
  const mapped = replaceMapped(source, /\\\[[\s\S]*?\\\]|\\\([\s\S]*?\\\)|(?<!\\)\$\$[\s\S]+?(?<!\\)\$\$|(?<!\\)\$(?!\$)(?:\\.|[^$\n])+?(?<!\\)\$/g, formula => {
    const placeholder = `${prefix}${segments.length}TOKEN`; segments.push([placeholder, formula]); return placeholder;
  });
  const formulas = new Map(segments), pattern = new RegExp(`${prefix}\\d+TOKEN`, "g");
  return { source: mapped.text, originalOffset: mapped.originalOffset, hasMath: formulas.size > 0,
    restore: (text: string, restoreImages: (value: string) => string) =>
      text.replace(pattern, token => restoreImages(formulas.get(token) ?? token)) };
}
function base64UTF8(value: string): string {
  const bytes = encodeURIComponent(value).replace(/%([0-9A-F]{2})/g, (_, pair: string) => String.fromCharCode(parseInt(pair, 16)));
  const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  const result: string[] = [];
  for (let i = 0; i < bytes.length; i += 3) {
    const bits = (bytes.charCodeAt(i) << 16) | ((bytes.charCodeAt(i + 1) || 0) << 8) | (bytes.charCodeAt(i + 2) || 0);
    result.push(alphabet[(bits >>> 18) & 63]! + alphabet[(bits >>> 12) & 63]! + (i + 1 < bytes.length ? alphabet[(bits >>> 6) & 63] : "=") + (i + 2 < bytes.length ? alphabet[bits & 63] : "="));
  }
  return result.join("");
}

import { spawn } from "node:child_process";
import { mkdtemp, open, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { basename, join } from "node:path";

import { marked, type Token, type Tokens } from "marked";

import type { DocumentBlock, DocumentDocument } from "./domain.js";
import { NotebookStore, StoreError } from "./store.js";
import { revision } from "./domain.js";

export interface DocumentExportReceipt {
  documentID: string;
  texPath: string;
  pdfPath: string;
  pdfSHA256: string;
  byteCount: number;
  log: string;
}

export function documentTeX(document: DocumentDocument): string {
  const suppliedPreamble = document.preamble.trim();
  let preamble = /\\documentclass(?:\[[^\]]*\])?\{/.test(suppliedPreamble)
    ? suppliedPreamble
    : [
      "\\documentclass[12pt]{article}",
      "\\usepackage{fontspec}",
      "\\setmainfont{Georgia}",
      "\\usepackage{amsmath,amssymb,booktabs,longtable,array,graphicx,xcolor}",
      "\\usepackage[colorlinks=true,linkcolor=black,urlcolor=blue]{hyperref}",
      suppliedPreamble,
    ].filter(Boolean).join("\n");
  if (/\\begin\s*\{document\}/.test(preamble)
    || /\\end\s*\{document\}/.test(preamble)) {
    throw new StoreError(
      "preamble задаёт класс и пакеты; begin/end document принадлежат экспортёру.",
    );
  }
  if (!/\\(?:usepackage|RequirePackage)(?:\[[^\]]*\])?\{[^}]*\bgeometry\b[^}]*\}/.test(preamble)) {
    preamble += "\n\\usepackage{geometry}";
  }
  const geometry = document.paperSize === "letter"
    ? "letterpaper,margin=1in"
    : "a4paper,margin=25mm";
  preamble += `\n\\geometry{${geometry}}`;
  return [
    preamble,
    "\\begin{document}",
    ...document.blocks.map(blockTeX),
    "\\end{document}",
    "",
  ].join("\n\n");
}

let activeExports=0;

export async function exportDocument(
  document: DocumentDocument,
  store: NotebookStore,
): Promise<DocumentExportReceipt> {
  if(activeExports>=2) throw new StoreError("Две печатные формы уже собираются. Повторите после их завершения.");
  activeExports++;
  let work:string;
  try {work=await mkdtemp(join(tmpdir(), "notebook-tex-"));} catch(error){activeExports--;throw error;}
  const sourcePath = join(work, "document.tex");
  let source: string;
  const tectonic = process.env.TECTONIC_BIN || "/opt/homebrew/bin/tectonic";
  let output = "";
  try {
    source=documentTeX(document);
    await writeFile(sourcePath,source,"utf8");
    output = await run(
      tectonic,
      [
        "--untrusted",
        "--synctex",
        "--keep-logs",
        "--outdir",
        work,
        sourcePath,
      ],
      120_000,
    );
    const file=await open(join(work,"document.pdf"),"r");
    let pdf:Buffer;
    try {
      const info=await file.stat();
      if(!info.isFile() || info.size>16*1024*1024) throw new StoreError("Печатный PDF превышает 16 МиБ.");
      pdf=Buffer.alloc(info.size);
      let offset=0;
      while(offset<pdf.length){const {bytesRead}=await file.read(pdf,offset,pdf.length-offset,offset);if(!bytesRead)throw new StoreError("Печатный PDF не завершён.");offset+=bytesRead;}
    } finally {await file.close();}
    return await store.command<DocumentExportReceipt>({ command: "publishExport", export: {
      documentID: document.id, expectedRevision: revision(document.contentStamp), source,
      pdf: pdf.toString("base64"), log: output.slice(-8_000),
    } });
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") {
      throw new StoreError(
        `Tectonic не найден: ${tectonic}. Установите его через Homebrew или задайте TECTONIC_BIN.`,
      );
    }
    if (error instanceof StoreError) throw error;
    throw new StoreError(
      `LaTeX не собрался. ${String(error)}\n${output.slice(-8_000)}`,
    );
  } finally {
    activeExports--;
    await rm(work, { recursive: true, force: true });
  }
}

function blockTeX(block: DocumentBlock): string {
  switch (block.kind) {
  case "markdown":
    return markdownToTeX(block.source);
  case "latex":
    return block.source;
  case "interactive":
    return [
      "\\begin{center}",
      "\\fcolorbox{black!18}{black!2}{%",
      "\\begin{minipage}{0.88\\linewidth}",
      `\\textbf{Интерактивный элемент:} \\texttt{${escapeTeX(block.id)}}\\par`,
      "Откройте документ в Notebook, чтобы использовать этот элемент.",
      "\\end{minipage}}",
      "\\end{center}",
    ].join("\n");
  }
}

function markdownToTeX(source: string): string {
  const protectedMath = protectBackslashMath(source);
  let rendered = renderBlocks(marked.lexer(protectedMath.source, { gfm: true }));
  for (const [placeholder, math] of protectedMath.segments) {
    rendered = rendered.split(placeholder).join(math);
  }
  return rendered;
}

function protectBackslashMath(source: string): {
  source: string;
  segments: Array<[string, string]>;
} {
  let prefix = "NOTEBOOKTEXMATH";
  while (source.includes(prefix)) prefix += "X";
  const segments: Array<[string, string]> = [];
  const protectedSource = source.replace(
    /\\\[[\s\S]*?\\\]|\\\([\s\S]*?\\\)/g,
    (math) => {
      const placeholder = `${prefix}${segments.length}TOKEN`;
      segments.push([placeholder, math]);
      return placeholder;
    },
  );
  return { source: protectedSource, segments };
}

function renderBlocks(tokens: Token[]): string {
  return tokens.map((token) => {
    switch (token.type) {
    case "space":
      return "";
    case "heading": {
      const heading = token as Tokens.Heading;
      const command = ["section", "subsection", "subsubsection", "paragraph", "subparagraph", "subparagraph"]
        [Math.min(Math.max(heading.depth, 1), 6) - 1]!;
      return `\\${command}{${renderInline(heading.tokens)}}`;
    }
    case "paragraph":
      return `${renderInline((token as Tokens.Paragraph).tokens)}\\par`;
    case "text": {
      const text = token as Tokens.Text;
      return `${text.tokens ? renderInline(text.tokens) : escapeTeX(text.text)}\\par`;
    }
    case "blockquote":
      return `\\begin{quote}\n${renderBlocks((token as Tokens.Blockquote).tokens)}\n\\end{quote}`;
    case "list": {
      const list = token as Tokens.List;
      const environment = list.ordered ? "enumerate" : "itemize";
      const items = list.items.map((item) =>
        `\\item ${renderBlocks(item.tokens).replace(/\\\\par\s*$/u, "")}`
      ).join("\n");
      return `\\begin{${environment}}\n${items}\n\\end{${environment}}`;
    }
    case "code": {
      const code = token as Tokens.Code;
      return `\\begin{verbatim}\n${code.text}\n\\end{verbatim}`;
    }
    case "hr":
      return "\\medskip\\hrule\\medskip";
    case "table": {
      const table = token as Tokens.Table;
      const columns = Math.max(table.header.length, 1);
      const header = table.header.map((cell) => renderInline(cell.tokens)).join(" & ");
      const rows = table.rows.map((row) =>
        row.map((cell) => renderInline(cell.tokens)).join(" & ") + " \\\\"
      ).join("\n");
      return [
        `\\begin{longtable}{${"l".repeat(columns)}}`,
        "\\toprule",
        `${header} \\\\`,
        "\\midrule",
        rows,
        "\\bottomrule",
        "\\end{longtable}",
      ].join("\n");
    }
    case "html":
      return `${escapeTeX(stripHTML((token as Tokens.HTML).text))}\\par`;
    default:
      return escapeTeX(token.raw);
    }
  }).filter(Boolean).join("\n\n");
}

function renderInline(tokens: Token[]): string {
  return tokens.map((token) => {
    switch (token.type) {
    case "text": {
      const text = token as Tokens.Text;
      return text.tokens ? renderInline(text.tokens) : renderText(text.text);
    }
    case "escape":
      return escapeTeX((token as Tokens.Escape).text);
    case "strong":
      return `\\textbf{${renderInline((token as Tokens.Strong).tokens)}}`;
    case "em":
      return `\\emph{${renderInline((token as Tokens.Em).tokens)}}`;
    case "del":
      return renderInline((token as Tokens.Del).tokens);
    case "codespan":
      return `\\texttt{${escapeTeX((token as Tokens.Codespan).text)}}`;
    case "br":
      return "\\\\";
    case "link": {
      const link = token as Tokens.Link;
      return `\\href{${escapeURL(link.href)}}{${renderInline(link.tokens)}}`;
    }
    case "image": {
      const image = token as Tokens.Image;
      return `\\textit{[${escapeTeX(image.text || basename(image.href))}]}`;
    }
    default:
      return escapeTeX(token.raw);
    }
  }).join("");
}

function escapeTeX(value: string): string {
  return value.replace(/[\\{}#$%&_~^]/g, (character) => ({
    "\\": "\\textbackslash{}",
    "{": "\\{",
    "}": "\\}",
    "#": "\\#",
    "$": "\\$",
    "%": "\\%",
    "&": "\\&",
    "_": "\\_",
    "~": "\\textasciitilde{}",
    "^": "\\textasciicircum{}",
  })[character]!);
}

function renderText(value: string): string {
  let result = "";
  let plainStart = 0;
  let index = 0;
  while (index < value.length) {
    if (value.startsWith("$$", index)) {
      const end = value.indexOf("$$", index + 2);
      if (end >= index + 3) {
        result += escapeTeX(value.slice(plainStart, index));
        result += value.slice(index, end + 2);
        index = end + 2;
        plainStart = index;
        continue;
      }
    }
    if (value.startsWith("\\[", index)) {
      const end = value.indexOf("\\]", index + 2);
      if (end >= index + 2) {
        result += escapeTeX(value.slice(plainStart, index));
        result += value.slice(index, end + 2);
        index = end + 2;
        plainStart = index;
        continue;
      }
    }
    if (value[index] === "\\" && value[index + 1] === "(") {
      const end = value.indexOf("\\)", index + 2);
      if (end >= 0) {
        result += escapeTeX(value.slice(plainStart, index));
        result += value.slice(index, end + 2);
        index = end + 2;
        plainStart = index;
        continue;
      }
    }
    if (value[index] === "$" && value[index - 1] !== "\\") {
      let end = index + 1;
      while (end < value.length) {
        if (value[end] === "$" && value[end - 1] !== "\\") break;
        end += 1;
      }
      if (end < value.length && end > index + 1) {
        result += escapeTeX(value.slice(plainStart, index));
        result += value.slice(index, end + 1);
        index = end + 1;
        plainStart = index;
        continue;
      }
    }
    index += 1;
  }
  return result + escapeTeX(value.slice(plainStart));
}

function escapeURL(value: string): string {
  return value.replace(/[{}%#]/g, (character) => `\\${character}`);
}

function stripHTML(value: string): string {
  return value.replace(/<[^>]*>/g, " ").replace(/\s+/g, " ").trim();
}

function run(command: string, args: string[], timeoutMS: number): Promise<string> {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { stdio: ["ignore", "pipe", "pipe"] });
    let output = "";
    const timer = setTimeout(() => {
      child.kill("SIGKILL");
      reject(new StoreError("Tectonic не завершил сборку за 120 секунд."));
    }, timeoutMS);
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk: string) => { output = (output + chunk).slice(-64_000); });
    child.stderr.on("data", (chunk: string) => { output = (output + chunk).slice(-64_000); });
    child.once("error", (error) => {
      clearTimeout(timer);
      reject(error);
    });
    child.once("close", (code) => {
      clearTimeout(timer);
      if (code === 0) resolve(output);
      else reject(new StoreError(`Tectonic завершился с кодом ${String(code)}.\n${output}`));
    });
  });
}

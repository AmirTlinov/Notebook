import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import type { DocumentBlock, DocumentDocument } from "../src/domain.js";
import { documentTeX, exportDocument } from "../src/latex.js";
import { StoreError } from "../src/store.js";
import { appActor } from "./fixture.js";

const documentID = "7e7a0000-0000-4000-8000-000000000040";

function markdown(id: string, source: string): DocumentBlock {
  return {
    id,
    kind: "markdown",
    source,
    html: "",
    css: "",
    javaScript: "",
    initialState: {},
    height: 320,
  };
}

function latex(id: string, source: string): DocumentBlock {
  return { ...markdown(id, source), kind: "latex" };
}

function document(
  blocks: DocumentBlock[],
  preamble = "",
  paperSize: "a4" | "letter" = "a4",
): DocumentDocument {
  return {
    format: 2,
    id: documentID,
    paperSize,
    preamble,
    blocks,
    contentStamp: { counter: 0, actor: appActor },
  };
}

test("turns Markdown prose and exact LaTeX blocks into one TeX artifact", () => {
  const source = documentTeX(document([
    markdown(
      "intro",
      "# Привет\n\nФормула $x_1$, имя a_b и $$y=x^2$$.\n\n\\[z=3\\]",
    ),
    latex("proof", "\\begin{align}y &= x^2\\end{align}"),
  ]));

  assert.match(source, /\\setmainfont\{Georgia\}/);
  assert.match(source, /\\geometry\{a4paper,margin=25mm\}/);
  assert.match(source, /\\section\{Привет\}/);
  assert.match(source, /\$x_1\$/);
  assert.match(source, /\$\$y=x\^2\$\$/);
  assert.match(source, /\\\[z=3\\\]/);
  assert.match(source, /a\\_b/);
  assert.match(source, /\\begin\{align\}y &= x\^2\\end\{align\}/);
});

test("binds Letter creation choice to the exported PDF geometry", () => {
  const source = documentTeX(document(
    [markdown("body", "Letter")],
    "\\documentclass{article}\n\\usepackage{geometry}",
    "letter",
  ));

  assert.match(source, /\\geometry\{letterpaper,margin=1in\}/);
  assert.equal((source.match(/\\usepackage\{geometry\}/g) || []).length, 1);
});

test("keeps document boundaries owned by the exporter", () => {
  assert.throws(
    () => documentTeX(document([], "\\documentclass{article}\n\\begin{document}")),
    StoreError,
  );
});

test("compiles Cyrillic, Markdown math, and raw LaTeX to a PDF with Tectonic", {
  skip: !existsSync(process.env.TECTONIC_BIN || "/opt/homebrew/bin/tectonic"),
}, async () => {
  const root = await mkdtemp(join(tmpdir(), "notebook-latex-export-"));
  try {
    const receipt = await exportDocument(document([
      markdown("intro", "# Документ\n\nРусский текст и формула $x_1$."),
      latex("equation", "\\[E=mc^2\\]"),
    ]), root);
    const pdf = await readFile(receipt.pdfPath);
    const tex = await readFile(receipt.texPath, "utf8");

    assert.ok(pdf.byteLength > 1_000);
    assert.equal(pdf.subarray(0, 4).toString("ascii"), "%PDF");
    assert.equal(receipt.byteCount, pdf.byteLength);
    assert.equal(receipt.pdfSHA256.length, 64);
    assert.match(tex, /Русский текст/);
    assert.doesNotMatch(receipt.log, /Missing character/i);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

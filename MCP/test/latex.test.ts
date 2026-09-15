import assert from "node:assert/strict";
import test from "node:test";

import type { DocumentBlock, DocumentDocument } from "../src/domain.js";
import { documentTeX } from "../src/document-tex.js";
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

test("keeps paper text at 12 points and follows the Markdown heading hierarchy", () => {
  for (const paper of ["a4", "letter"] as const) {
    const source = documentTeX(document([
      markdown("body", "# Title\n\n## Section\n\n### Detail\n\nBody text."),
    ], "", paper));
    assert.match(source, /\\documentclass\[12pt\]\{article\}/);
    assert.match(source, /\\section\{Title\}/);
    assert.match(source, /\\subsection\{Section\}/);
    assert.match(source, /\\subsubsection\{Detail\}/);
  }
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
    Error,
  );
});

test("wraps an interactive block address without dropping characters or interpreting TeX", () => {
  const id = "collaboration-counter-1d13a2ed-6e64-4ff6-b973-aa1b28bc328e_%{x}\\end";
  const value = document([{ ...markdown(id, ""), kind: "interactive" }]);
  const before = JSON.stringify(value), source = documentTeX(value);
  assert.equal(JSON.stringify(value), before);
  assert.ok(source.includes(Array.from("collaboration-counter-").join("\\allowbreak{}")));
  assert.ok(source.includes("\\_\\allowbreak{}\\%\\allowbreak{}\\{\\allowbreak{}x\\allowbreak{}\\}"));
  assert.ok(source.includes("\\textbackslash{}\\allowbreak{}e\\allowbreak{}n\\allowbreak{}d"));
  assert.equal((source.match(/\\allowbreak\{\}/g) ?? []).length, Array.from(id).length - 1);
  assert.doesNotMatch(source, /\\texttt\{collaboration-counter-/);
});

test("preserves HTML SVGs and real internal/external link destinations instead of flattening tags", async () => {
  const { documentExport } = await import("../src/document-tex.js");
  const svg = '<svg xmlns="http://www.w3.org/2000/svg" width="120" height="80"><rect width="120" height="80" fill="#f00"/><text x="8" y="30">Vector</text></svg>';
  const sourceDocument = document([
    markdown("intro", `<h2 id="start">Начало &amp; смысл</h2><p><a href="#finish">Вперёд</a> <a href="https://example.org/a?x=1&amp;y=2#part">Web</a></p><img width="120" height="80" src="data:image/svg+xml;base64,${Buffer.from(svg).toString("base64")}">`),
    markdown("finish", '<h2 id="finish">Конец</h2><p><a href="#start">Назад</a></p>\\(x=\\frac{1}{2}\\)'),
  ]);
  const before = JSON.stringify(sourceDocument), result = documentExport(sourceDocument);
  assert.equal(JSON.stringify(sourceDocument), before);
  assert.equal(result.assets.length, 1);
  assert.equal(Buffer.from(result.assets[0]!.data, "base64").toString(), svg);
  assert.match(result.source, /\\NotebookPrintImage\[.*\]\{notebook-image-0\.pdf\}/);
  assert.equal((result.source.match(/\\hyperlink\{/g) ?? []).length, 2);
  assert.equal((result.source.match(/\\hypertarget\{/g) ?? []).length, 2);
  assert.match(result.source, /\\href\{https:\/\/example.org\/a\?x=1&y=2\\#part\}\{Web\}/);
  assert.match(result.source, /Начало \\& смысл/);
  assert.match(result.source, /\\\(x=\\frac\{1\}\{2\}\\\)/);
});

test("shares one image asset across Markdown and HTML and preserves inline SVG", async () => {
  const { documentExport } = await import("../src/document-tex.js");
  const svg = '<svg xmlns="http://www.w3.org/2000/svg" width="40" height="20"><circle cx="10" cy="10" r="8"/></svg>';
  const url = `data:image/svg+xml;base64,${Buffer.from(svg).toString("base64")}`;
  const result = documentExport(document([markdown("images", `![One](${url})\n\n<img src='${url}'>\n\n${svg}`)]));
  assert.equal(result.assets.length, 2, "Identical data URLs share bytes; the HTML parser canonically serializes the independent inline SVG.");
  assert.equal((result.source.match(/notebook-image-0\.pdf/g) ?? []).length, 2);
  assert.equal((result.source.match(/\\NotebookPrintImage\[/g) ?? []).length, 3);
  assert.doesNotMatch(result.source, /textit\{\[/);
});

test("does not silently discard an unavailable image or create a broken PDF destination", async () => {
  const { documentExport } = await import("../src/document-tex.js");
  for (const source of ['![remote](https://example.org/figure.svg)', '<img src="file:///Users/user/private.png">', '<img src="data:image/png;base64,!">']) {
    assert.throws(() => documentExport(document([markdown("image", source)])), /export_image_/);
  }
  const result = documentExport(document([markdown("link", '<a href="#absent">A missing section</a>')]));
  assert.match(result.source, /A missing section.*недоступная ссылка/);
  assert.doesNotMatch(result.source, /\\hyperlink/);
});

test("custom document classes retain their packages and gain only missing print dependencies", async () => {
  const { documentExport } = await import("../src/document-tex.js");
  const preamble = "\\documentclass{book}\n\\usepackage{tikz,siunitx,graphicx}\n\\usepackage[hidelinks]{hyperref}";
  const result = documentExport(document([markdown("contents", '# Heading\n\n[go](#heading)')], preamble));
  assert.ok(result.source.startsWith(preamble));
  assert.equal((result.source.match(/\\usepackage(?:\[[^\]]*\])?\{hyperref\}/g) ?? []).length, 1);
  assert.equal((result.source.match(/\\usepackage\{graphicx\}/g) ?? []).length, 0);
  assert.match(result.source, /\\hyperlink/);
});

test("the actual large acceptance document keeps every SVG, formula and valid link", async () => {
  const { documentExport } = await import("../src/document-tex.js");
  const { readFile } = await import("node:fs/promises");
  const source = await readFile(new URL("../../Tests/NotebookDocumentAcceptance/create-control.js", import.meta.url), "utf8");
  let created: { blocks: DocumentBlock[] } | undefined;
  const nb = {
    board: async () => ({ values: [{ boardID: documentID, header: { rootBoardID: documentID, stamp: { counter: 0, actor: appActor } }, boardContentRevisions: { [documentID]: "0@test" } }] }),
    id: async () => documentID,
    transaction: async (_key: unknown, action: { operations: Array<{ values: { blocks: DocumentBlock[] } }> }) => {
      created = action.operations[0]!.values; return [{ receipt: { id: documentID } }];
    },
    document: async ({ blockID }: { blockID: string }) => ({ values: [{ block: created!.blocks.find(block => block.id === blockID) }] }),
  };
  const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
  await new AsyncFunction("nb", "args", "emit", source)(nb, {}, async () => {});
  assert.ok(created);
  const result = documentExport(document(created.blocks));
  assert.equal(result.assets.length, 35);
  assert.equal((result.source.match(/\\NotebookPrintImage\[/g) ?? []).length, 35);
  assert.equal((result.source.match(/\\\(/g) ?? []).length, 1680);
  assert.equal((result.source.match(/\\hyperlink\{/g) ?? []).length, 2);
  assert.equal((result.source.match(/недоступная ссылка/g) ?? []).length, 1);
  for (const asset of result.assets) assert.match(Buffer.from(asset.data, "base64").toString(), /<path.*<text/s);
});

test("SVG math labels stay image text while document math stays TeX", async () => {
  const { documentExport } = await import("../src/document-tex.js");
  const result = documentExport(document([markdown("svg", '<svg xmlns="http://www.w3.org/2000/svg" width="80" height="30"><text x="0" y="20">$x$ \\(y\\)</text></svg>\n\n$z$')]));
  const image = Buffer.from(result.assets[0]!.data, "base64").toString();
  assert.match(image, /\$x\$ \\\(y\\\)/);
  assert.doesNotMatch(image, /NOTEBOOKTEXMATH/);
  assert.match(result.source, /\$z\$/);
});

test("HTML block boundaries keep image captions out of the preceding inline row", async () => {
  const { documentExport } = await import("../src/document-tex.js");
  const svg = '<svg xmlns="http://www.w3.org/2000/svg" width="120" height="40"><path d="M0 0L120 40"/></svg>';
  const result = documentExport(document([markdown("caption", `<div>Before<img src="data:image/svg+xml;base64,${Buffer.from(svg).toString("base64")}"><p>Caption with number 3.</p></div><div>After</div>`)]));
  assert.match(result.source, /notebook-image-0\.pdf\}\s*\\par\s*Caption with number 3\.\\par/);
  assert.match(result.source, /Caption with number 3\.\\par\s*\\par\s*\\par\s*After\\par/);
  assert.ok(result.source.indexOf("\\special{pdf:minorversion 7}") < result.source.indexOf("Before"));
  assert.ok(result.source.indexOf("\\special{pdf:minorversion 7}") > result.source.indexOf("\\begin{document}"));
});

test("code examples retain literal math delimiters while surrounding formulas print as math", () => {
  const result = documentTeX(document([markdown("code", 'Example `$x_1$` and formula $x_1$.\n\n```text\n\\(y\\) $z$\n```')]));
  assert.match(result, /\\texttt\{\\\$x\\_1\\\$\}/);
  assert.match(result, /formula \$x_1\$/);
  assert.match(result, /\\begin\{verbatim\}\n\\\(y\\\) \$z\$/);
  assert.doesNotMatch(result, /NOTEBOOKTEXMATH/);
});

test("implicit heading anchors use the visible formula source, never parser placeholders", () => {
  const result = documentTeX(document([markdown("formula-heading", '# Value $x_1$\n\n[Return](#value-x_1)')]));
  assert.match(result, /\\hyperlink\{/);
  assert.doesNotMatch(result, /недоступная ссылка|NOTEBOOKTEXMATH/);
});

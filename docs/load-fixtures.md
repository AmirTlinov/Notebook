# Reproducible heavy-source fixtures

`Applications/generate-load-fixture.sh` creates independent originals for test import.
Default seed is 410041; the full set has 100,000 items. It is input data, not another
Notebook store or an already-installed board, and does not open live user material.

```sh
Applications/generate-load-fixture.sh "$PWD/.build/load-100000" 100000 410041
python3 Applications/LoadFixtures/verify.py "$PWD/.build/load-100000"
```

Output must not exist. A private sibling preparation directory is published only
after the manifest completes. Ordinary failure removes only that preparation;
an abrupt process exit may leave .preparing-* but no finished fixture or Notebook item.

## Contents and identity

Every eight items include a notebook, Markdown document, SVG, interactive model, PDF
and three images. JPEG/PNG alternate with HEIC/HEIF; the manifest records the actual
ImageIO type rather than guessing from extension.

- Notebook: four 834×1194-point pages with ordered pen/eraser contact recipes,
  pressure, width and sample times—not canonical PageInkDrawing bytes.
- Markdown: long text/formula flow; physical page count remains unknown until real
  pagination, not a false measured zero.
- SVG/PDF: independently generated curves/fine lines. PDFs have distinct pages,
  CropBox and 0/90/180/270 rotations, validated by CoreGraphics.
- Interactive model: explicit parameter and 1,024-point curve; execution/readiness
  still requires Notebook verification.
- Images: independent pixels, 512×384 proportions, orientations 1/3/6/8 and periodic
  4096×3072 heavy samples. Encoded size/orientation is read back. Repeatability is
  scoped to the same system encoder version, recorded in the manifest.

Each item has sparse, dense and fully overlapping placement plus intended portal
depth. The first 24 items/sources are independent of collection size; sparse remaining
items are distant, allowing the same visible workset at 1k/10k/100k.
Actual portal construction/publication belongs to the importer; depth metadata is
not traversal evidence.

`items.jsonl` records SHA-256, bytes, known pages/pixels and source complexity
(curve segments, measured ink samples, text volume, blocks, controls).
`manifest.json` aggregates these and hashes records/generator.
These are source properties, not invented execution timings.

`Applications/test-load-fixture.sh` checks same/different seed, formats/orientations,
page geometry and invalid/existing output rejection. The verifier rereads every
original; repeated references to a few files fail uniqueness.

## Historical full set

September 6 fixture `.build/notebook-04-load-100000`, seed 410041:

| Property | Count |
|---|---:|
| Items / unique sources | 100,000 / 100,000 |
| Source bytes | 21,652,987,639 |
| Known pages | 174,837 |
| Image pixels | 12,153,913,344 |
| Markdown documents awaiting pagination | 12,500 |
| Measured pen samples | 13,148,352 |
| Vector segments | 95,071,105 |

Generator hash:
`67ff549e14438953f87c11bafcd433fd191e8644f709e6194433c164bdad0ce2`.
Record hash:
`98942e60fa4996226d8a4e92e29143d4d0f575af9fd7b21fea5f03cd9503157f`.
Readback log: `.build/notebook-04-load-100000.log`.

Generation/uniqueness does not prove import, frame latency, memory or physical
acceptance. Run the intended bounded import and user route separately.

# Historical physical-iPad typesetting probe

This is the **historical GUI-238 feasibility prototype**, preserved as evidence
of the limits of an earlier approach. It is not the current Notebook editor,
typesetter, or a supported build route for this checkout.

The prototype ran the Markdown-to-TeX converter and Tectonic 0.16.9 directly on a
physical iPad and displayed its PDF through PDFKit. Its separate signed bundle,
`com.amirtlinov.notebook.typeset-probe`, did not access the live Notebook
container, pairing, keys, or content. It used no Simulator.

## Historical reproduction

The retained `run.py` refers to the retired
`Sources/NotebookMarkupService/TeXResources.lock.json` and the old TeX runtime.
Those dependencies are absent from the current tree. Use a matching historical
checkout and its recorded runtime to reproduce the original experiment; do not
run these commands as current application setup:

```sh
python3 Tests/NotebookTypesetterProbe/run.py --build --tex-runtime /path/to/notebook-tex-runtime
python3 Tests/NotebookTypesetterProbe/run.py --run --device PHYSICAL_DEVICE_UDID
```

Historically, build preparation used `.build/print-layout-spike`, Rust with
`aarch64-apple-ios`, Xcode, XcodeGen, CMake, automake/pkg-config, and project
signing. Initial dependency preparation required network access; typesetting
verified the pinned bundle and denied user packages/network. Its full initial
bundle occupied about 1.4 GiB. The shared native runner slot must remain exclusive.

The run installed only the probe bundle and retained device logs, reports, and
PDFs. Removing that prototype is an explicit action independent of Notebook.

## What the experiment measured

- A4/Letter MediaBox, Cyrillic text, formulas, a table, a package, and a live PDF
  link through `notebook-markup.js`.
- Denial of a test private container file from TeX.
- Ten infinite-macro/deadline/success cycles and recovery after TeX errors
  without process restart; PDF text and vectors remained intact.
- Whole local compilation time and post-operation `phys_footprint`, not peak
  memory, FPS, or long-session stability.

One patch supplied CoreText integration, a replacement input provider, and an
experimental deadline check every 1,024 `get_next` calls. The provider allowed
canonical system-font files without the upstream unrestricted filesystem
provider. The checkpoint did not bound every engine phase and was not a
production security boundary.

The probe did not establish bounded cancellation/memory in PDF/font/BibTeX,
cross-device font/package identity, source maps, causal undo, canonical-layout
persistence, full document compatibility, or complete user/performance acceptance.
Those limitations remain properties of this experiment, not a current product
roadmap. GUI-199/205 were not closed by its results.

The current single-owner implementation is documented in
[canonical document pages](../../docs/document-page-fragments.md).
Historical outcomes and subsequent replacements are indexed in
[verification](../../docs/verification.md).

# Pinned computation resources

Pyodide **314.0.6**, CPython **3.14.2**, NumPy **2.4.6**, SciPy **1.18.0**,
SymPy **1.14.0**, and mpmath **1.4.1**. `manifest.json` owns versions, sizes,
and SHA-256 identities. Resource verification neither downloads nor executes
third-party code.

The core comes from the
[official release](https://github.com/pyodide/pyodide/releases/tag/314.0.6):
`pyodide-core-314.0.6.tar.bz2`, SHA-256
`1016c31e39ce3764d9a418cbb491a392c802c1b86ccc1367f009f5c59bf8f5fd`.
Its two ES modules, WASM, and standard library are unchanged. Four wheels came
from the release's full jsDelivr distribution and were verified against upstream
lockfile hashes. The local lock retains only their entries and original ABI
version metadata. Other package installation is disabled. Unneeded CLIs,
Windows executables, TypeScript types, and the rest of the package catalog are
excluded.

Pyodide uses MPL-2.0; corresponding source is available at the release link.
Python and library licenses are retained in `Licenses`; wheels preserve their
own notices, including bundled dependencies. Library files are unmodified.
This README is documentation, not an engine resource.

**These resources are not linked into application targets.**
The current consumer is `Tests/NotebookComputationHarness`: isolated dependency
evidence, not a released notebook calculator. Integration boundaries are in
[executable ink](../../docs/executable-ink.md).

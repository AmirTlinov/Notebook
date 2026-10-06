# Search source semantics and writer cost

Strict public Core route: **21actual functions/27executions,0failed,0skipped**.
Exact source before=after: `8f6993aad5e5d2986e22d4130f44a24013fe8054606a22b045995783ff153d4a` (1650files).
Base `b46361ab`;11code/test input files are fingerprinted in results.json.
The twelfth path is documentation, outside the release-source manifest.
Portable Core only; no native runner, installation or physical acceptance.

The extract retains exact commands, selected IDs and raw events.
verification-summary.json explicitly derives from the original receipt and
retains its hash and original artifact hashes. Full source/inventory and
compiled outputs are omitted.

NB10: three isolated processes on Apple M5 Max/128GiB/macOS27.0.1.
1KiB20.96ms writer/40.74ms ink;1MiB184.13ms/238.79ms;4MiB640.95ms/749.33ms.
All ink commands saved. This demonstrates writer contention and supplies a
follow-up cause; it does not accept a hash-bound plan or delta algorithm.
Allocator live peaks are SQL_PROFILE samples; total allocation events and
steady-state distributions are unmeasured. Apple global SQLite accounting
returned0 despite positive per-connection allocations and is unavailable here.

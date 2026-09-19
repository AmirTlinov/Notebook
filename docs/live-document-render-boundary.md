# Historical large-document rendering boundary

These September 11 measurements concern the **retired DOM paginator**.
They do not describe today's PDF engine or establish its performance.
Current contract: [canonical paper](document-page-fragments.md).

Installed pair 0.3.16 (19) could read a 140-block document and report ready/connected
while its first-page image stayed snapshot_pending. A durable render receipt reported
render_error:pending; retry returned the same failure. Existing content was not
evidence of a displayed page, and render failure was not evidence of data loss.

An independent synthetic source (140 blocks, 35 SVGs, 1,680 formulas, 39 measured
pages) reproduced the old path:

| Old DOM implementation | Total |
|---|---:|
| Baseline | 38.520 s |
| Task handoff only | 28.643 s |
| Task handoff plus local formula definitions | 2.737 s |

These were passive WKWebView timings, not a physical-device/native installation
receipt. MessageChannel traversal and distinct SVG definition IDs fixed the measured
causes without changing formula paths. Later native/page tests had their own source
and scope; none transfers automatically to the replacement typesetter.

The complete positive/negative sequence, image/log paths and source identities remain
in [the original evidence](https://github.com/AmirTlinov/Notebook/blob/1723ec2be6f6b8dda29e3a575fd6376fff03e093/docs/live-document-render-boundary.md).
Current release evidence is in [verification](verification.md).

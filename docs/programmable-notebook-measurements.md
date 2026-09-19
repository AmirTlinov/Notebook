# Historical SDK v1/v2 measurements — September 18, 2026

Environment: macOS 27.0 (26A428), arm64, isolated signed Mac Release apps.
Route: public MCP → coordinator → QuickJS → native writer.
These comparative runs were not production-pair or physical acceptance.

## Source and method

v1 retained source inventory:
`a9aad42a9a647039d94c980645d84c22115fbee9beb11775a44973c1fc5a6a7d`,
910 inputs. Exact commit was unknown; `1e456d3` was only a comparison base and
differed by 46 inputs. Initial v2 was `6f9e8e7` plus explicitly recorded GUI-225 work,
996 inputs, SHA
`d615df32d19b3cc24f3713be5afb5360de2ed25ca44968cb2582265ae51c936f`.
Final corrected source identities and raw series remain in the linked full record.

The first comparison exposed output-wait policy as a confounder. After correcting
the owner, the whole series was rerun rather than discarding inconvenient results.

| Scenario | Calls v1→v2 | Median RPC ms v1→v2 |
|---|---:|---:|
| Label | 2→1 | 150.93→121.66 |
| Offscreen search | 2→1 | 16.45→16.81 |
| One block | 2→1 | 15.53→15.24 |
| Three related objects | 2→1 | 227.64→186.49 |
| Diagram reflow | 2→1 | 194.44→148.97 |
| Conflict continuation | 2→1 | 225.58→191.44 |
| Reconnect with intentional 3 s wait | 5→5 | 3224.19→3239.56 |

These were small sequential samples (five repeats, three for reconnect).
They support fewer external calls for addressed work, not a universal speedup.
Payload bytes did not decrease in every case. Equal wait=1000 comparisons and
post-restart first-read checks were separate series; filesystem cache was not flushed.
The SQL/read/decode diagnostic series was also separate from release timing.

## Separate installed acceptance

The original record reports seven scenarios × ten on installed build 105, followed
by final addressed regression/cleanup on production 106, system traces of 135.816 s
and 300.948 s, and a >30-minute collaborative native/MCP scenario.
Receipt: `.build/s10-complete-20260918/final-receipt.json`.
That accepted S10 milestone did not claim isolated Notebook 60 FPS or a universal
acceleration percentage, and it does not accept later GUI-240 changes.

[Full comparison, immutable sources and raw evidence](https://github.com/AmirTlinov/Notebook/blob/1723ec2be6f6b8dda29e3a575fd6376fff03e093/docs/programmable-notebook-measurements.md).
[Detailed production-106 acceptance in the retained journal](https://github.com/AmirTlinov/Notebook/blob/1723ec2be6f6b8dda29e3a575fd6376fff03e093/docs/verification.md).
[Current installed scope](verification.md).

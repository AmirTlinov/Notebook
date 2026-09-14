# Passive navigation stage evidence

`notebook_acceptance.py ui --navigation-observation-session <new UUID>` enables
`NOTEBOOK_NAVIGATION_OBSERVATION_SESSION_ID` only for a verified private iPad
Simulator manifest. The native observer independently validates the manifest,
role, bundle, container and nonzero UUID. Without explicit opt-in it is inert.
The normal UI test forwards the variable; it never creates a request or pixel.

The observer writes metadata-only NDJSON under the private container beside the
store, `navigation-observations/<session>-<launch>.ndjson`. A serial utility queue
owns encoding and disk writes. Limits are 4096 records, 4 MiB, 128 queued records
per launch, with explicit dropped/truncated evidence. Stages carry monotonic
mach timestamps, request/generation, fence scope IDs, existing contact/phase and
pending-owner state. A cancellation includes its source line/reason. Document
text, query text, selection text, credentials and clipboard are not recorded.

The collector binds unchanged native source hashes, session/run/workspace and
Simulator identity; absent journals are `unobserved`, never PASS. It preserves
original bytes, refuses reused sessions, symlinks, oversized input and overwrite.
Cleanup failure preserves the primary UI failure and does not skip recording
cleanup. It neither installs an app nor changes trust, defaults or global MCP.

This trace diagnoses ownership and await/cancellation transitions. Correlate it
with the original XCTest logs and actual video. It does not prove installed
pixels, display latency or FPS. The document installation owner remains the
separate measurement authority.

CPU admission contracts:

```sh
python3 -m unittest discover -s Tests/NotebookNavigationObservation -v
```

The preserved launch configuration revision is distinct from the installed native
build revision after an upgrade. Preparation records its canonical JSON SHA-256;
collection verifies the actual selected manifest inside the same Simulator
container and compares each journal header with that configuration revision.
The receipt reports the configuration path/hash and native source provenance
separately. A changed manifest or a header carrying the native revision in place
of the configuration revision is rejected; no older-build fallback is used.

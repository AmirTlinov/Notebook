# Document acceptance through real applications

Run `create-control.js` as `notebook_execute start` source only against the
paired private acceptance Mac's MCP endpoint. It creates material through
`nb.board`, `nb.id`, and `nb.transaction`, then checks addressed
`nb.document` reads. The control has 140 blocks, 35 SVGs, 1,680 formulas, and
more than 6 MiB of text. Keep returned document/board/action IDs.
Generator completion alone does not establish delivery or iPad presentation.

`NotebookDocumentAcceptanceUITests` launches the separately installed
`com.amirtlinov.notebook.acceptance` with:

- `NOTEBOOK_ACCEPTANCE_MANIFEST`: the already paired isolated pair's manifest.
- `NOTEBOOK_ACCEPTANCE_DOCUMENT_ID`: the actual generator's document UUID.
- Optional `NOTEBOOK_ACCEPTANCE_DOCUMENT_TITLE`, default
  `Notebook canonical control`.

The test uses ordinary search, open, links, pages, typing, and Save gestures.
It does not populate storage directly, substitute agent replies, or control DOM.
Run ten cold openings before editing so measurements use the unchanged control.

## Presentation timing and source freshness

`DocumentPresentationRecorder`, enabled only for acceptance or explicit
profiling, observes the existing native owner: user request, canonical-content
arrival, and installation of the ready current surface. Its target polling
interval is 5 ms; a busy MainActor may delay observation longer. That delay is
included, so this is conservative request-to-observed-installation timing,
not a guaranteed ±5 ms measurement. The recorder does not trigger layout,
snapshots, focus, or loading. Missing native evidence fails explicitly.

Within one app launch, accepted records have unique IDs and strictly increasing
request times. Revisiting a page cannot reuse its prior record. Checks include
actual touch eligibility, window intersection, and current page from the ordinary
`page-turn-surface` accessibility value. History resets only after a new launch.
`testInstallationHistoryRejectsReplayedOrOutOfOrderPageReceipts` checks repeated
IDs, stale requests with new IDs, equal times, and new launches.

`testColdOpeningAndDistantLinkPublishFreshNativeInstallations` is a short
diagnostic: open, distant link, and return using the same fresh-install checks.
It saves records and PNGs; success does not establish full-workload p95.

Cold measurements use ten fresh application/WebKit processes starting from the
board. Warm measurements first visit both ends, then execute ten return trips.
Thresholds: cold p95 ≤3,000 ms; warm p95 ≤300 ms. These are Simulator
request-to-installation measurements, not touch-to-photon, FPS, CPU/GPU, or
system dropped-frame measurements.

After UI editing, `export-control.js` independently reads the saved marker on
Mac and starts a durable export job. Later calls with its ID read
`nb.exportStatus`. Verify PDF publication and appearance separately;
`queued` is not complete. This scenario's export uses the agent API.

Retain source SHA, Release build, manifest, start/resume logs, XCTest attachments,
and xcresult. File existence and generator CPU tests do not establish acceptance.

## Per-process system tracing

When Time Profiler is explicitly selected, the driver creates
`system_trace.TraceHandshake` before the UI runner. Constructor inputs:
`session_id`, `control_directory`, `evidence_directory`, `simulator_udid`,
`expected_bundle_id`, `expected_executable_uuid`, and
`segment_time_limit_seconds`. Control/evidence directories must be new.
`start()` retains installed xctrace settings and sets Hangs threshold to 100 ms.
Pass `environment` to UI; `finish()` requires completed segments.
`cancel()` stops only this coordinator's recording.

- `NOTEBOOK_TRACE_SESSION_ID`: shared session UUID.
- `NOTEBOOK_TRACE_CONTROL_DIRECTORY`: private absolute exchange directory for
  UI runner and host coordinator; the application does not read it.

`NotebookSystemTraceIdentitySurface` exposes diagnostic identity only for the
private acceptance bundle with explicit session/manifest. It uses the current
PID, loaded main Mach-O LC_UUID, and a per-process launch ID. It takes no input
and does not declare UI readiness.

After actual launch, XCTest reads identity and sends READY with a new segment
UUID. The host validates Simulator container, bundle, installed Mach-O UUID,
PID executable, and process creation time, then starts
`xctrace record --device UDID --attach PID`.

A unique Darwin notification is registered through public libnotify before
recording. Only `--notify-tracing-started` from the still-live owned xctrace
permits STARTED. Log text is insufficient. XCTest rechecks identity before
gestures. Before termination it sends END and waits for CLOSED. Each launch gets
its own segment, with at most 16 sequential segments.

During recording, polling uses only cheap `kill(pid,0)` liveness checks.
Full identity checks happen before/start/end/after. Recorder death, start timeout,
identity changes, wrong UUID, or missing END fail explicitly. PID reuse cannot
transfer recording to a future process. `session.json` preserves
`primaryError` and separate `cleanupErrors`; failed cleanup never promotes
a failed segment to CLOSED or completed.

Each segment retains command, workload interval, identity, settings, logs,
`.trace`, and original TOC. Historically observed schema names include
`time-profile`, `potential-hangs`, and `hangs-threshold`. Unknown schemas
remain `captured_unassessed`; export errors preserve evidence and fail the
lifecycle. A known 250 ms threshold cannot replace 100 ms. Recognized TOC alone
does not prove absence of hangs: assess actual rows, main-thread coverage, and
workload intervals. This route does not report dropped display frames.

## Instrument checks and historical failures

```sh
python3 -m unittest discover -s Tests/NotebookDocumentAcceptance -p test_system_trace.py -v
```

On September 14, 2026, 16 CPU checks and Swift 6 semantic checks passed.
Fake xctrace exercised ordering/failures only. The real 07:35–07:36 UTC smoke
validated the live PID but DVT Instruments failed tap configuration/start.
Evidence in `.build/v6-trace-diagnosis/` records a failed capture.

On September 15, the log-string barrier was replaced by public notification.
A real Mac recorder notified after 1.965 seconds without printing the expected
log line. Eighteen CPU/notification contracts passed, including real libnotify,
name isolation, cleanup, and rejection of log-only readiness. The separate
Simulator probe in `.build/profiler-simulator-notification-diagnostic` still
received no event within 20 seconds. Mac recording did not establish Simulator
CPU/GPU/frame acceptance.

These are dated results; consult [verification](../../docs/verification.md) for
later receipts and current limitations.

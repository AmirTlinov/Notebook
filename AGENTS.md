# Notebook: ownership and verification

```text
Notebook/
|-- Sources/NotebookCore/            # Content, SQLite, causal actions, and delivery.
|-- Sources/NotebookCodex/           # Codex adapter; does not own model execution.
|-- Sources/NotebookArchiveTransfer/ # External copy converter, separate from apps.
|-- Applications/Shared/             # App model, write queue, camera, ink, documents.
|-- Applications/iPad/               # iPad workspace and system input.
|-- Applications/Mac/                # Mac window, input, IPC, and trusted connection.
|-- Applications/WebResources/       # WebKit document and program presentation.
|-- MCP/                            # Shared-workspace tools through the Mac owner.
|-- Tests/                          # Core, MCP, Codex, and verification contracts.
|-- Applications/*Tests/             # Native checks and gesture scenarios.
`-- verify.sh                       # Change-scoped checks; --full is full acceptance.
```

Product and interaction decisions follow [PHILOSOPHY.md](PHILOSOPHY.md).

## Working with real content

Live applications read the current format. Historical archives remain in independent
backups: Amir's September 11 decision does not authorize restoring or merging them
into the current workspace. Updating the installed pair preserves containers,
identities, and keys. Never run a newly built helper against a historical archive.
MCP contract checks use an isolated `NOTEBOOK_HOME`. Live checks use MCP from the
installed, admitted helper.

## Find the owner

- Content, addressed writes, delivery: `Sources/NotebookCore/`,
  [spatial replication](docs/spatial-replication-contract.md),
  [replication owner window](docs/replication-owner-window.md),
  [transport](docs/transport-contract.md).
- Ink, camera, composition, memory: `Applications/Shared/`,
  [performance](docs/performance.md),
  [page ink](docs/page-ink-conflict-contract.md),
  [scene allocation](docs/scene-allocation-contract.md).
- Documents, links, WebKit: [navigation](docs/document-link-navigation.md),
  [printed pages](docs/document-page-fragments.md),
  [programs](docs/document-program-fragments.md),
  [render evidence](docs/live-document-render-boundary.md).
- Shared context and agent actions: [collaboration](docs/collaboration.md),
  [shared context](docs/shared-context-contract.md), and the relevant
  `docs/agent-*-contract.md`.
- Projects, conversations, Codex: [bridge](docs/codex-desktop-bridge.md),
  [runtime](docs/agent-runtime-contract.md).
- Builds, pairing, transfer: [release](docs/release-build-contract.md),
  [installation and pairing](docs/installation-pairing.md),
  [archive transfer](docs/archive-transfer.md).
- Open conditions and results: [reliability](docs/reliability-transition.md),
  [verification](docs/verification.md). Keep tasks and actual status in Linear.

Choose the relevant route. Code owns behavior, the focused document explains its
contract, and tests exercise it; this map provides navigation.

## Verification and completion

Install iPad application changes on the physical iPad and check them there.
Do not use simulators unless the user explicitly selects that route for the task.

For an ordinary change, choose the defect regression and the affected user scenario.
`./verify.sh --plan` proposes a starting scope; `--only --profile ... --test ...`
makes it explicit. An unknown route calls for engineering judgment, not a full run
or another map entry. See [verification selection](docs/release-build-contract.md#verification-selection).

Check UI changes with the affected gesture. A 100,000-item workload is needed when
the corresponding algorithm changes. `./verify.sh --full` is a separate full
acceptance route. Run only one Xcode runner at a time.
Evidence applies to unchanged sources and states its actual scope.

Fix failures caused by your change and complete the selected checks. Commit a
verified slice with a conventional commit and push when a remote is available.
Local PASS and installation do not establish physical acceptance. Full acceptance
requires system frame, CPU/GPU, and memory measurements, ten scenario repetitions,
and 30 minutes of joint work; CADisplayLink does not measure FPS.
Record exact results and remaining limitations in [verification](docs/verification.md).

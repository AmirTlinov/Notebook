# Codex in Notebook: conversation ownership and delivery

Notebook does not execute a model. One `NotebookCodexHost` owns the bundled official
Codex App Server; workspace-scoped `NotebookCodexSidecar` routes use that host.
Codex owns task history, model, working directory, tools and permission policy.
Notebook has no separate model executor or OAuth implementation. Device-code login
is handled by Codex; credentials remain on Mac.

Historical `AgentRequest` records remain address-readable for archive transfer via
`AgentArchive` / `NotebookAgentArchive`. Their retired dispatcher is not a live
execution path, and an old request ID authorizes no new edit. Current edits use
the ordinary `CollaborationStore`, versions and causal undo.

## Owners

- `NotebookChatController`: selected task, draft and bounded presentation; owned
  by the model rather than panel visibility. Collapsing chat does not stop a turn.
- `NotebookStore` / `NotebookPersistenceQueue`: local `chat_jobs` and `chat_panel`
  in the same WAL, respecting accepted Pencil priority. These are delivery/UI state,
  not shared content revisions or a second Codex history.
- `SharedContext` / `AgentPinnedSource`: immutable human-indicated content and PNG
  evidence at `collaboration/attention/<context>/<reference>.json`, delivered through
  normal content replication. `nb.attention` validates the image hash and reports
  unavailable historical pixels rather than substituting a fresh screenshot.
- `NearbySync`: authenticated chat delivery through the current
  [wire contract](transport-contract.md). A reserved human-control slot precedes
  ordinary chat; coalesced conversation events have lower priority than receipts,
  contact and presence.
- `NotebookCodexSidecar`: durable attempts before native RPC. Existing tasks retain
  native UUIDs; creating one does not invent a Notebook-specific permission profile.

## Sending and uncertain outcomes

Send synchronously fixes text, task and physical indication before the first await.
The model retains accepted preparation through closure; later draft/task changes
cannot redirect it. Input UUID and payload are persisted before transmission.
Reusing a UUID with different content fails. SQLite acceptance order, not device
wall time, orders first delivery.

Sidecar records `saved → attempting` before RPC and `accepted` with the real turn
ID afterward. Retrying delivery reads the existing receipt. On restart an unfinished
attempt becomes `uncertain`. Reconciliation pages canonical history for the exact
`clientUserMessageId`; a positive match resolves it. Missing IDs, read failures or
absence from one page never authorize another execution.

One event-woken drain owns the durable journal. New admission, native state and
completion wake it; idle has no polling timer. A timer belongs only to a pending
retry/reconciliation deadline. Stop/approval priority and exact attempts remain
unchanged.

Every view and in-flight operation owns an observation UUID. It is registered
before attach waits; close, switch, revoke, detach and shutdown release that exact
UUID. Late attach cannot reselect a closed view or release its replacement.
Releasing observation never interrupts an accepted native turn.

The queue admits at most 128 unfinished inputs and fails explicitly when full.
Ordinary input to a busy task waits. Explicit steer names `expectedTurnId`;
completion of that turn cannot turn it into a new turn. Stop names one exact turn.

Permissions, commands, file approvals and questions require an explicit human
decision. Decision identity binds author/task/turn/native request; stop identity
binds author/task/turn. Repeated taps, collapse or restart read the same action.
A contrary decision cannot overwrite the first. Definitive pre-send rejection
closes as rejected; ambiguous delivery remains uncertain. Unsupported forms never
auto-approve. Current question and permission rendering belongs to
[the bridge](codex-desktop-bridge.md).

## Interface and context

The native chat window preserves position and size separately from paper camera.
The composer stays outside conversation scrolling; keyboard appearance changes
available chat area, not paper geometry. Collapsed controls return to the tool
region rather than following a disappearing keyboard. See [chat window](chat-window.md).

One budgeted WebKit renders sanitized Markdown/MathJax for the conversation.
Messages retain native IDs, accessibility speaker labels and explicit truncation.
Pending outgoing cards come from the same durable queue, not another editable
history; accepted client ID/receipt removes them.

The agent receives current physical context and any fixed indication. Selection
does not implicitly restrict all tools or move the camera after a reply.
Explicit visual explanation uses [temporary presentation](agent-presentation-contract.md).
The surface contract is injected into an admitted task without starting a user
turn; reads and window resizing do not reinject it.

Projects, catalogs, public work status, model selection, structured attachments and
history paging use native Codex identities. Project edits send only changed fields
through a durable job and `project/update`. After an uncertain update, `project/read`
may confirm the requested state; mismatch does not authorize overwriting later
changes. Renaming roots in settings does not move files.

Dictation inserts once into the originating draft; voice uses that same selected
conversation. Both retain their own explicit lifecycle under the chat owner:
[voice contract](codex-voice.md).

## Distribution and external setup

Mac bundles official Codex, Node and a self-contained Notebook MCP package.
Embedded chat uses workspace-scoped MCP without changing global configuration.
Before native start/resume it reads effective Codex policy for cwd: disabled tools,
filters and restrictions remain enforced. Catalog/account access does not require
external MCP registration.

External Desktop/CLI → Notebook setup is an explicit Mac menu action.
`registerNotebookTools` uses official `config/batchWrite` with expectedVersion and
readback, changing only command, args and NOTEBOOK_SOCKET. Filters, timeouts and
preferences survive. Startup does not rewrite global MCP configuration; isolated
builds cannot run production setup.

Catalog auth reads use `account/read` with `refreshToken: false` and expose only the
needed sign-in state, not email/tokens. Explicit account UI is host-owned. Missing
auth rejects new-task creation before `thread/start` without changing providers
or closing existing tasks.

## Verification scope

Focused checks cover TLS delivery, duplicate/uncertain attempts, exact approvals/
stops, draft persistence, context images, rendering and native adapter behavior.
Historical full runs and installed builds prove only their own source snapshots.
Current installation, open GUI-183 acceptance and physical voice/Pencil limits are
reported in [verification](verification.md), not inferred from local PASS.

[Detailed historical runtime evidence](https://github.com/AmirTlinov/Notebook/blob/1723ec2be6f6b8dda29e3a575fd6376fff03e093/docs/agent-runtime-contract.md).

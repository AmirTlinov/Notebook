# Real collaboration acceptance in Simulator

`NotebookCollaborationAcceptanceUITests` launches only the signed private bundle
`com.amirtlinov.notebook.acceptance` with `NOTEBOOK_ACCEPTANCE_MANIFEST`.
Before launch, pair the isolated apps through the ordinary UI, connect the Mac
to real Codex, and publish/deliver/show an `acceptance-controls` widget through
`nb.transaction`. The scenario uses `notebook_context` and
`notebook_execute`; the server also exposes the separate package-import tool.
The test does not create trust, read SQLite/model state, or substitute chat
responses or receipts.

The control is a web element with complete state `{count, slider, text}`.
Its AX controls are `Acceptance increment`, `Acceptance slider`, and
`Acceptance text`; visible output is `Acceptance count: N`. Button/text input
commit complete state through `notebook.commit`; received changes render on
`notebookstate`. The agent resolves the board UUID from context. Leave visible
empty board space beside the widget for long hold.

## Scenarios

The main scenario and CAS regression each allow 600 seconds.
`notebook_acceptance.py` gives these exact methods a 660-second outer timeout
and records `timeoutSeconds`:

- `NotebookAcceptanceUITests/NotebookCollaborationAcceptanceUITests/testCreatedMaterialRetainsHumanEditsThroughAgentUndoAndCancellation`
- `NotebookAcceptanceUITests/NotebookCollaborationAcceptanceUITests/testConcurrentHumanStateRejectsStaleAgentWriteAndSurvivesItsUndo`

The first test selects a region by real hold/drag, checks the context counter, and
sends a natural request to Codex. After Send, the person increments the original
counter. The agent must open the submitted pixels, read the old value, await new
live state, and reread the same attention SHA before creating an interactive
document.

UI then opens that document and verifies 0 → 1 on the first actual tap.
The person opens source, adds text, saves, and waits for installation. A later
request exports that exact saved version with formula, SVG, and link.
The job and PDF are verified independently through public APIs.
The agent continues saved 1 to 101 in one transaction; the person taps to 102.
The agent's stale CAS must fail with `revision_conflict`; selective undo of
the agent's +100 preserves the later human value 102. Stopping the next real
read-only turn must leave the document intact.

### Offline and recovery

The outer runner stops only the exact private Mac process.
`testOfflineOutgoingAndDraftSurviveRelaunchInTheSameConversation` requires the
actual offline banner, queues one outgoing message, retains a separate unsent
draft, relaunches iPad, and compares conversation/outgoing IDs and exact text.

After the same private Mac binary restarts with the same manifest,
`testReconnectedConversationDeliversOnceAndRetainsUnsentDraft` waits for a real
Codex reply, empty outbox, unchanged draft, and retained 102. These methods and
`testUseCreatedDocumentFromTheExistingRealConversation` /
`testContinueSavedDocumentFromTheExistingRealConversation` also receive 660
seconds, but no trace attachment without a launch handshake.

Recovery reads the previous creation receipt from the same transcript; it never
creates again. After Save it reads the prior export; if 102 is already shown,
it reads the prior CAS/undo outcome rather than applying +100 again.
A failed original run remains failed even if recovery succeeds.

Observe the response through one immutable AX snapshot; disappearing indices
do not alone establish an application fault. Stop may precede any action, so an
absent action group is valid. Independently check the same turn with Codex.

### Concurrent state regression

The agent first changes widget text and emits the same transaction's immutable
`saved.receipt.revisions` and `saved.receipt.id`. Do not derive expected
versions from a later read that could already include human changes.

Readiness requires the visible `Agent ready …` text in the actual field and
the current turn's Stop button. Hidden commentary or prompt echo is insufficient.
UI changes count and text through tap, keyboard, Cmd+A, and typing.
The agent then writes with its earlier expected version, receives
`revision_conflict`, and undoes only its original action. Both human values
must survive. The test never repairs an incorrectly admitted stale write.

`nb.undo` updates the original action receipt:
`undoReceiptID == effectActionID`. Preserve actual `publication.saved`,
`receipt.undo.completedAt` (Apple reference-date numeric value), `restored`,
and `preservedCount`; do not invent a separate undo action ID.

## Conversation and evidence identity

Creation/CAS scenarios each create a fresh chat and nonce. Recovery/offline/
reconnect continue that chat. Read existing conversation/task IDs, then select
New Chat once. The receipt must open a new UUID with an empty transcript.
An empty conversation may not yet appear in Codex history.

Replace only a recognizable leftover acceptance draft and verify exact prompt
text before Send. An unknown draft stops the scenario before replacement.
Open the addressed document cover through the ordinary double-click path.

Agent output includes actual context/reference/action/document/program IDs,
hashes, versions, errors, undo result, and real `notebook_execute` run IDs.
Emit post-commit expected state before awaiting human input, then actual CAS and
undo outputs. Agent-reported JSON remains labeled
`agent-reported-…-public-addresses-unverified`; it alone does not establish
persistence or display. Separate attachments retain UI values and screenshots.
Missing responses, attention pixels, or controls remain failures.

After UI execution, independently verify through public tools:

1. Reread `nb.attention({contextID,referenceID})`, display its artifact with
   `emitImage`, and compare `expectedSHA256` and old pixels with the pre-Send frame.
2. Resume each real run ID to read output/effects without re-execution. Compare
   the original post-commit expected version with the rejected CAS input.
   Read every needed page of `nb.action`, including accepted operations,
   CAS error, and undo outcome.
3. Read the created document/program: first tap saved 1; continuation/undo/Stop
   retained 102. Compare original widget count/text with post-undo UI evidence.
4. Verify saving, delivery, and actual shown version separately through
   publication/presentation receipts. Cached images do not prove presentation.
5. Retain commit/source SHA, build manifest, xcresult, video, real run IDs, and
   all unverified or failed stages.

## Trace and type checking

Optional system tracing uses `NotebookSystemTraceHandshake`: identity per
actual launch, READY → Darwin start notification → gestures → END.
Neither video nor CADisplayLink measures system FPS. Record exact outcomes in
[verification](../../docs/verification.md).

`python3 Tests/NotebookCollaborationAcceptance/typecheck.py` checks Swift 6
semantics without taking the Simulator runner. It records command, compiler,
both source hashes before/after, and `uiExecuted:false`.

Prompts bound a single JavaScript wait to 30 seconds. A subsequent run carries
the already emitted expected/state, without repeating the first effect or
replacing expected with fresh state. Timeout and real tool errors remain visible;
the harness does not disable QuickJS limits.

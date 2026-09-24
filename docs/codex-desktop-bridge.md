# Codex without a required Desktop window

`CodexAppServer` is a persistent stdio client of the bundled official App Server.
It uses native auth, projects, history, models, tools and permissions without
opening a Desktop window or replacing existing task settings.
The checked-in adapter and bundled-runtime manifest define the supported protocol;
external API references are not a promise of compatibility with an arbitrary version.

## Host and task ownership

`NotebookCodexHost` owns one App Server per Mac app. Workspace
`NotebookCodexSidecar` instances route delivery, not separate model processes.
Mac calls the route directly; iPad uses authenticated Notebook transport.
Up to eight workspace owners retain distinct IPC addresses, so switching windows
does not redirect an active agent's tools.

`thread/resume` acquires Codex's own exclusive writer. “Already has an active
writer” is an explicit refusal; history remains readable. Notebook neither evicts
the other process nor creates a replacement task. Catalog reads do not resume
every listed task. Closing the panel leaves the connection and active turn alive;
inactive completed tasks can leave the bounded working set.

A `thread/start` request remains pending until reply or connection closure, rather
than discarding a late ID after the ordinary 12-second read timeout.
Unknown create outcomes are not retried. Native writes persist attempts before RPC;
positive `clientUserMessageId` evidence resolves uncertain sends.
Ordinary busy-task messages queue; explicit steer and stop target the exact turn.
An explicit native refusal while attaching a task rejects the saved input before
dispatch; transient unavailability leaves it queued. The UI reports missing
confirmation, not an inferred device location or Codex acceptance.

## Bounded protocol and questions

`CodexRPC` supports at most 16 pending requests, 8 MiB JSONL frames and a ten-second
partial-frame deadline. `CodexAppServerState` retains up to 64 public messages,
separate recent acceptance receipts and 32 questions. Hidden reasoning is not
exposed. History pages contain native items rather than entire multiday turns;
late reads cannot replace newer events. Truncation is explicit.

Native string/numeric question IDs survive unchanged. Human decisions may approve
once or for a duration offered by Codex. A supported
`codex_approval_kind: mcp_tool_call` form shows approval/denial and only offered
session/always scopes; persistent approval names that tool, not universal access.
Unsupported forms never auto-consent. Completion comes from Codex's event, not
merely writing to a pipe.

Snapshots carry all native question IDs and one full question. The common Mac/iPad
picker reads another question by connection generation and native ID. A decision
from an old generation cannot answer a reused ID.

Process-output persistence does not block the JSONL reader. One per-process mailbox
holds at most 512 KiB including its active write and preserves terminal-event order.
Overflow reports incomplete output, requests Stop and never reruns the command.

## Permissions, model and attachments

Task permission controls show native profiles returned by `permissionProfile/list`.
`thread/settings/update` changes the selected task's subsequent-turn policy only.
Full access requires explicit confirmation of its consequences. Existing questions,
other tasks, global settings and macOS application rights remain separate.
Uncertain updates are reconciled by reads, not repeated grants.

Models and supported effort come from `model/list`, not a fixed list.
A durable `setModel` command updates model/effort without changing permissions or
interrupting the current reply. Displayed values come from resume/settings events.
Context usage uses `last.totalTokens` and `modelContextWindow` from
`thread/tokenUsage/updated`; missing data is unknown, never zero or a guessed percent.

The composer adds Mac files/folders, skills, installed plugins and connected apps.
`skills/list` is cwd-scoped; `plugin/installed` supplies installed plugins;
`app/installed` / `app/read` supplies apps. Catalog listing neither installs nor
grants access. Draft attachments are saved per computer and included atomically
with the message UUID. Only the sent draft version is cleared. Native structured
skill/mention inputs preserve the actual identities.

The composer keeps model, effort, context, dictation, voice and send/stop controls.
Narrow layouts use another row or an accessible processor icon instead of hiding
voice actions. Stop replaces send during a turn; the plus menu offers explicit steer
or send-after-reply. It does not create a second stop owner.

On iPad, New Chat opens a local draft immediately, retaining its text and
attachments; it performs no remote creation. Sending from the catalogue starts
a projectless draft rather than sending to the previously selected, hidden chat.
Only the first Send saves a creation job and its frozen first message atomically.
The latter is local outbox metadata, not a new transport command. Receiving a
confirmed creation atomically releases one ordinary send to its actual thread ID,
using the saved message ID, attention and attachments. A restart, duplicate receipt
or later selection cannot duplicate or redirect it. Unknown creation outcomes stay
visible without retry; rejected/explicitly abandoned creations can return their
message to the editor. A creation receipt selects its chat only while that pending
draft is still selected.

## History and quiet updates

One `NotebookChatController.messages` projection merges native IDs. Older
`thread/items/list` pages are inserted near shared IDs, preserving scroll anchor
and pixel offset. Reconnect/return fills the gap to the last shown ID without
executing work again. New conversations begin at the live tail.

Catalogs refresh only loaded windows. Visible chat lists refresh every ten seconds,
projects every fifteen; hidden lists/folders do not poll. Activity summaries read
at most eight tasks at a time. Chats and Projects retain independent cursors,
expanded folders, pages and drafts. Actual project/worktree membership comes from
Codex; an unknown project is not guessed from a similar path.

Conversation events coalesce over 100 ms and bind to subscription, trusted computer
and connection generation. A ten-second control read recovers a missed final event.
They use a lower-priority transport lane than delivery receipts and input.

`CodexUserMessageDisplay` removes only the complete recognized native file-mention
wrapper before truncation. Quoted/partial wrappers and agent answers remain intact.
Filenames are safe labels, not loaded thumbnails or permission to open Mac paths.
Canonical message IDs, attachments and request content remain unchanged.

Native `realtime_delegation` displays its input, not a second user message from
transcript deltas or tail flush. `flushTranscriptTailOnSessionEnd` is disabled.
Adjacent comments/tools from one turn form one expandable work row, retaining
individual IDs/details. `NotebookChatWorkStatus` uses only current public activity.
Reduce Motion makes the active accent static.

## Async view fences

File opens have monotonically new opening identities, even when reopening the
same file. Slow old results cannot restore a closed or replaced document.
Refresh rechecks address, open generation, base revision, conflict and write/rename
activity, merging against the latest draft. Old failures and annotation reads cannot
affect another file or resurrect dismissed review.

Terminal read/start/stop/input results bind to their view session/project/process.
Unknown input remains blocked only for its original process. Changing views never
reexecutes it. Collapse changes persisted window visibility/height, not process
lifecycle or paper camera.

## Isolated adapter verification

Private harness config uses TOML basic-string escaping, not JSON escaping.
A bootstrap process reads effective config; the test runtime disables inherited
MCPs, plugins and apps and enables only its scoped Notebook. Native model/account/
permission settings are not replaced. These are process-local overrides, not edits
to user configuration.

After initialize and before start/resume, effective enabled servers and exact socket
are checked. Start/resume receive the same private cwd/config. The public API offers
no atomic config-read plus start transaction: a concurrent global addition strictly
between checks is not claimed impossible. Actual task tools are checked separately.
For the ordinary workspace-scoped endpoint, unset optional fields returned as
`null` by `config/read` are omitted from explicit start/resume overrides; configured
tool filters, timeouts and disabled state retain their values.

Startup failure exposes stage and exit code, not raw stderr, arguments or account
data. Optional real-runtime probes require
`NOTEBOOK_CODEX_SCOPE_PROBE_MANIFEST` and `NOTEBOOK_CODEX_SCOPE_PROBE_TOOLS`;
without those explicit private inputs they skip. They verify argv/config round trips,
not a model turn.

Use a private task/root for live approval, denial, stop, history and duplicate-send
checks. Installed-pair and physical acceptance remain separate:
[verification](verification.md), [runtime](agent-runtime-contract.md),
[remote work](codex-remote-work.md).

Protocol reference: [OpenAI App Server](https://learn.chatgpt.com/docs/app-server).

# Project commands and terminal in chat

The terminal expands below the conversation and composer. `NotebookTerminalSplit`
starts at half the available height and preserves the chosen fraction for the
selected computer. Keyboard constraints are temporary and do not move the camera.

Explicit opening reuses a live session or creates `zsh -il` in the project root.
`NotebookRunRequest.command == nil` means an interactive shell; an empty string is
not a command. Mount, restoration, and computer switching only read existing runs.
After exit, starting another shell is explicit. A project command stores and executes
the entered text under its full computer/project/root address.

`MacNotebookProjectRuns` accepts requests through the existing trusted transport
and persistence queue. Run UUID equals the first `NotebookChatInput` UUID.
Receipt retry cannot create another process. Input whose outcome is unknown is
not replayed; unsent input remains local.

## Execution and output

`CodexAppServer` uses documented `command/exec` with PTY on its persistent
connection; no model call is needed. Codex owns permissions. The working directory
must match a real project on that Mac. There are at most four active processes,
one per root. Restart waits for the previous process to exit; an old run reference
cannot stop a newer process.

Mac stores output in 8,192-byte pieces, up to 1 MiB per run. A response contains
at most 48 KiB across 64 records with an exact decimal cursor. A visible active
session polls the next output after 80 ms. Dropped buffer prefixes are explicit.
Completed runs retain the latest 24 entries; command receipt retention is separate.

The bundled xterm.js consumes bytes, not HTML, without CDN, image, clipboard, or
link-opening add-ons. Parsing a block finishes before the next one is delivered.
WebKit holds a normal resource lease and retires when collapsed. Restored output
cannot send terminal response sequences back into the process. Human contact focuses
xterm's own textarea; live output preserves concurrent typing.
Unknown input remains fenced to its process UUID, including after reopen.
A truncated buffer does not promise reconstruction of every full-screen TUI.

Collapse, board navigation, and iPad disconnect end observation only. Mac-helper
shutdown closes the process-owning App Server connection; restored runs become
interrupted and do not restart automatically. Failed output persistence stops the
affected process and retains unconfirmed completion for later storage.

The terminal control shows active-process status even when collapsed. The existing
chat loop checks every second during activity and every ten seconds otherwise.
Each output subscription has its own identity; cancelling an old one cannot release
a replacement reader.

## Verification

The `project-runs` profile checks admission, replay, unknown input, restart, bounds,
computer addressing, and camera independence. `NotebookRunControllerTests` uses
real WebKit/xterm. `notebook-codex-proof run <new-receipt.json>` exercises an isolated
real PTY, UTF-8, resize, long execution, exit, shell prompt, and Ctrl-C.
Gesture fixtures may use an isolated echo peer; that is not a real remote-shell or
full physical-pair receipt. See [verification](verification.md).

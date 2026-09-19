# Adding another Mac

For normal setup, open Notebook on the new Mac using the same Apple Account.
The [account-owned connection](installation-pairing.md) establishes trust and
workspace discovery. Each Mac keeps its own identity, local drafts, processes,
and window state. Historical archives are outside this route.

Never clone another Mac's actor identity or copy its trust keys to impersonate it.
Adding a machine does not authorize replacing the current iPad workspace.

## Explicit current-workspace preparation

The external converter retains an explicit enrollment route for an authorized,
independent copy of the current workspace. It is not an automatic startup step
or a requirement to restore a historical archive.

`ArchiveComputerPreparation` accepts a fresh independent copy of the current
iPad and its valid admission receipt, creates a separate working destination,
and calls `prepareDeviceSnapshot`. Shared records are preserved; local jobs,
windows, file drafts, terminal input, and output do not move to the new computer.
The source and admission are checked afterward. Nonempty destinations and reused
device identities are rejected.

The new journal starts with a complete current baseline. Its incoming iPad cursor
follows the copied state, so old changes are not replayed over current content.
`NotebookArchiveAdmission.enrollment` binds the original pair, current content,
and new Mac. It admits only that new Mac's data; it does not establish network trust.

The converter's explicit commands are:

```text
notebook-archive-transfer --prepare-computer ABSOLUTE_REQUEST --output NEW_ABSOLUTE_DIRECTORY
notebook-archive-transfer --admit-computer ABSOLUTE_REPORT ABSOLUTE_NEW_MAC_RECEIPT --output NEW_ABSOLUTE_JSON
```

The request uses `currentIPad`, `freshMac`, and `mac` with role, bundle ID, and a
new actor ID. Preparation is offline and performs no installation or pairing.
Activation requires the verified empty destination and an actual activation receipt
before admission. Follow [archive-transfer](archive-transfer.md) for its safeguards.
Distribute admission only to the new Mac. Network trust follows the current
Apple Account mechanism; the former invitation/confirmation instructions are retired.

## Historical evidence and remaining scope

On September 16, a second Mac received a signed build and a prepared current-workspace
copy. Its installed MCP returned a ready observation with the expected workspace but
a disconnected connection. A real ScriptService run completed through that MCP.
This established local activation and execution, not network pairing or display
on iPad. Evidence lived under `.build/seven-slices-second-mac/`.

Earlier SSH/tunnel failures were superseded by that run. They are not current
blockers. Real second-Mac switching, reconnection, equal-path isolation, and trust
revocation require their own up-to-date physical evidence.
See [verification](verification.md) for history and current release boundaries.

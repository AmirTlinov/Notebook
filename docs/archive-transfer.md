# External archive preparation

This is an **explicit offline conversion procedure**, not part of an ordinary
application update. On September 11, 2026, Amir canceled restoration of historical
archives. They remain independent backups and must not be imported, merged or
deleted without a new request. Current application data continues in place.

`notebook-archive-transfer` reads an independent copy of an old file archive and
prepares a new directory outside installed apps. It is not a dependency of Core,
iPad, Mac or MCP. Applications read the current format only; a separately prepared
archive is admitted by bootstrap before model creation.

## Single archive

```sh
swift run notebook-archive-transfer \
  --source /absolute/path/to/independent-backup \
  --output /absolute/path/to/new-prepared-directory \
  --workspace-id 11111111-2222-4333-8444-555555555555
```

The UUID is illustrative. Select a destination identity once. The output must not
exist or lie inside the source/live archive. Symlinks are rejected; inputs remain
unchanged. This command does not pair devices.

Input requires complete `WorkspaceIndex/3`, `SessionPresence/4`, collaboration
history format 2 and empty or `NotebookInk/1` ink on live sheets. Unknown formats,
missing owners and unsupported journals fail. Admission limits are 100,000 items,
100,000 sheets and 512 MiB per owner; these are not performance guarantees.

Core constructors preserve physical UUIDs, membership and order while introducing
the current causal/order fields. Selection moves to `SessionPresence/5`.
Binary ink becomes `NotebookInk/3` without redrawing: PNG bases, original action
counts, UUIDs, points, pen properties and undone actions survive. Missing legacy
sequence/activity fields receive their historical meaning. Raw live PencilKit is
not accepted as current app storage.

An empty service entry may recover only the existing action description matched
by UUID, context, date, author and original causal clock. No text is generated.
An empty human question or unmatched entry fails. Changes are listed in the report.
Orphan sheet/document files remain in the source copy and are reported, not revived.
All source-file hashes, including derived images and old backups, are inventoried.
Keep the independent source together with the result.

`NotebookCheckpoint` validates complete bodies, geometry, order, presence and
history dependencies. `installCheckpoint` accepts an empty destination with the
same workspace ID. One SQL transaction publishes content, history, provenance and
delivery state. Before-commit failure rolls back; after-commit ambiguity leaves a
complete readable result and never permits overwriting it.

Every prepared value is read back and compared, then source hashes are rechecked.
Only then is the private temporary directory renamed to the new destination.
A concurrently created destination is preserved; failure deletes only the
converter's own temporary directory. Output contains `archive/` and `report.json`.
The report deliberately keeps `inputQuiescenceProven: false` and
`installedApplicationsChanged: false`.

## Combining independent legacy and current copies

```sh
swift run notebook-archive-transfer \
  --legacy-ipad /absolute/path/to/old-ipad-backup \
  --legacy-mac /absolute/path/to/old-mac-backup \
  --current /absolute/path/to/new-app-backup \
  --output /absolute/path/to/new-combined-directory
```

This explicitly authorized mode copies the entire current archive, preserves its
workspace ID and adds legacy content through `receiveCollaboration`. It preserves
current presence rather than importing old selection/camera/context. Existing
requests, pinned sources, stops, drafts and unknown addressed records outside the
three merged owners must retain their hashes.

Legacy Mac/iPad catalogs, trees, documents, states and history must agree. Each Mac
spatial-ink UUID must exist on iPad with identical immutable points; only a later
state of the same action is allowed. Different PNG bases require matching retained
pre-migration PencilKit bytes, dimensions, drawing version and base-action count,
with no later actions. The converter explicitly selects the iPad PNG and records
both hashes and the common source. Real `PKDrawing` decoding and stroke-count
validation reject identical corrupt bytes. This proves common provenance, not
pixel or visual equality.

The factory root is the only permitted shared physical identity. Colliding items,
sheets, strokes, root members or history fail; even ambiguous UUID mentions in text
are conservatively rejected rather than rewritten. `importingIndependent`
preserves owner geometry and versions. Only added root membership and combined
order receive a new human import version.

Complete readback compares both sources' content. Current records outside
`workspace.json`, `board.json` and `spatial-ink.json` retain their original hashes.
All three source copies are rehashed. The result is an offline candidate, not a
device identity, pairing grant, installed app or proof that in-memory input drained.

## Preparing and admitting a pair

`--prepare-pair /absolute/request.json --output /absolute/new-pair` accepts
`legacyIPad`, `legacyMac`, `currentIPad`, one `transitionID` and explicit
`iPad` / `mac` destinations with `role`, `bundleID` and `actorID`.

Retained identities are `com.amirtlinov.notebook.preview` and
`com.amirtlinov.notebook.mac`; actors come from each destination's own settings.
The Mac candidate preserves all shared addressed records, including unknown ones,
but does not inherit another device's drafts, jobs, actor, network cursors,
settings or Keychain. This is initial archive conversion, not replacement of a
working current Mac with its later local history.

Each destination contains `candidate/` and `transition.json`. The manifest binds
destination, source/prepared file hashes, workspace and shared logical content.
SQL integrity, blobs and the complete checkpoint are checked before publication.

`NotebookApplicationLaunch` waits for `NotebookArchiveActivation` before creating
a model. Its sibling control directory is `Notebook.activation/`. Bootstrap checks
destination, inputs and free space, then durably flushes files, manifest and
directories **on the destination device**. Matching hashes or a Mac copy do not
replace destination `fsync` / `F_FULLFSYNC`.

One same-volume `RENAME_SWAP` exchanges directories after revalidation. The
original remains in `Notebook.activation/candidate/`; independent backups remain
untouched. A marker identifies whether the swap occurred. Recovery completes
forward, re-flushing files if needed; it never swaps a later archive backward.

Durable `activation.json` receipts from both devices are admitted using:

```sh
swift run notebook-archive-transfer \
  --admit-pair /absolute/ipad-activation.json /absolute/mac-activation.json \
  --output /absolute/new-admission.json
```

Roles/actors must differ and transition/shared content must match. Each device
durably saves `admission.json` before model, sync or agent starts. Subsequent
launches read small receipts and the marker; later SQL writes are not compared to
or replaced by the old prepared snapshot. Corrupt admission fails without rollback.

Production MCP registration belongs only to the admitted installed Mac at
`~/Applications/Notebook.app`; test models do not register production tools.
`Applications/install-preview.sh` remains a first-Lab installer and rejects an
existing installation. Transfer itself neither builds nor installs applications.

## Verification and historical limits

`NotebookArchiveActivationTests`, `ArchivePairPreparationTests`,
`NotebookArchiveLaunchTests`, `NotebookCheckpointTests` and
`ArchiveTransferTests` use synthetic inputs to check atomicity, recovery, strict
readback, identities, source preservation and refusal of corrupt or ambiguous
data. They do not prove installation or historical input completeness.

The September 11 clean-install decision superseded the old migration checklist:
historical content was preserved independently, not imported. Old requirements for
a fresh paused copy, Amir's visual comparison and final old-bundle removal describe
that abandoned transition, not completed migration evidence or current release
prerequisites. See [preservation provenance](current-mac-preservation.md),
[verification](verification.md) and the
[original transfer record](https://github.com/AmirTlinov/Notebook/blob/1723ec2be6f6b8dda29e3a575fd6376fff03e093/docs/archive-transfer.md).

Archive admission and device trust are separate. Once admitted, devices connect
through the private Apple Account directory; installers do not generate pairing
grants. See [automatic connection](installation-pairing.md) and
[additional-computer preparation](computer-enrollment.md).

# Historical Mac data preservation — September 11, 2026

This is provenance for independent copies, not a restoration or release procedure.
On September 11 at 15:45 MSK, the installed Mac helper already used the current
SQLite format. Its earlier activation receipt named 19 records; live storage had
1,179, including document `B8AB0A3D-19AC-431E-8460-6451C64D793E`.
An activation receipt does not fingerprint subsequent work.

The preservation root is:
`/Users/amir/Documents/Notebook Backups/2026-09-11-124530-current-mac-preservation`.

- `mac-live-sql-snapshot`: SQLite online backup through a read-only connection.
  `quick_check` returned `ok`; all 1,179 canonical records had independently
  verified blobs and SHA-256. Evidence: `current-record-proof.json` and
  `preservation.json`.
- `mac-retained-preactivation`: independent copy of the former file archive from
  `Notebook.activation/candidate`, 789 files / 179,429,247 bytes. Before/copy/after
  inventories matched; evidence: `retained-preactivation-proof.json`.

The application stayed running; storage and trust were unchanged. These durable
copies are not a final snapshot after a coordinated drawing pause and do not
prove every historically accepted stroke.

Amir subsequently canceled restoration and kept these archives in reserve.
Workspace `FAAAC405-8EF9-4FB9-9B93-CBD876FA97A4` must retain its later content.
The September 10 Lab copy's workspace `17248CEA-63FD-42D3-AC4F-D6C5F13DED14`
identifies that backup, not the current iPad. Neither restoration nor archive
merging belongs to an ordinary release. Experimental four-way consolidation was
not included or applied.

See [archive transfer](archive-transfer.md) and [release procedure](release-build-contract.md).

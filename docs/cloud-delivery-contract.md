# Private cloud delivery

## Ownership

Each device owns its SQLite store. `NotebookStore` owns content and causal merge;
`NotebookPersistenceQueue` owns application writes. `NearbySync` and
`NotebookCloudSync` deliver the same immutable manifests and SHA-256 blobs.
The SQLite file itself is never synchronized.

`NotebookStore.applyDelivery` is the common entry. `applyCloudDelivery` adds account
validation and removal of the accepted staging package in the same transaction.
Cloud delivery preserves field versions, ink, placement, undo and public CAS
preconditions. Direct transport owns low-latency presence and Codex interaction.
The same CloudSync actor coalesces independent inbound and outbound runs through
the ordinary writer. Each inbox round selects one head per exact source generation.
A contact rejection waits on the input owner's accepted idle boundary; a semantic
rejection remains staged until a real material commit, and missing dependencies
resume when content arrives. None advances that source's cursor or blocks another
source or outgoing preparation. ACKs and cloud bookkeeping publish no material wake.
The resident reason cache holds at most 128 exact sources. Overflow keeps its
envelopes in the existing inbox and aggregates only wake kinds. A finite sweep
continues to later sources and sleeps after an unchanged rejected pass; input
idle, fetched dependencies, actual material or explicit Retry starts another pass.
CloudKit does not deliver chat, audio, terminal, drafts, jobs or presence and
cannot issue a `shownOnIPad` receipt.

## Delivery identity and checkpoints

`NotebookReplicationDelivery` identifies the source device and journal generation,
sequence, immutable transaction UUID, manifest hash, byte count and snapshot flag.
Transaction UUID + hash are deduplicated globally across channels. A received
transaction with a real effect is forwarded with the same identity and manifest;
local `change_records` separately describes actual merged addresses for view
invalidation. An empty effect creates no journal event. An echo of the local
generation creates no incoming self-cursor.

An existing journal's first generation equals its device ID and is persisted in
SQL without resetting acknowledged cursors. Explicit `prepareDeviceSnapshot`
creates a new generation and does not inherit enabled cloud transport. A continuing
source copy retains its covered generation and prefix.

A snapshot is one consistent SQL cut of shared records, explicit deletions and
ordering dependencies, followed by the journal tail. It merges rather than
replacing the database or declaring a winning device. Causal existence clocks
preserve deletions even without old change records. Snapshot coverage is stored
separately from the incoming cursor; covered old deltas need no individual
receipt, while new deltas still require contiguous order. History is not
automatically removed.

If a cloud checkpoint overtakes an offered LAN change, the shared owner confirms
coverage. LAN acknowledges the offered transaction's own ID and sequence, not a
future transaction's identity, and does not fetch its obsolete bodies again.

## CloudKit and staging

Container: `iCloud.com.amirtlinov.notebook`; database: **private**, bound to the
selected Apple Account; workspace zone: `Notebook-<workspace UUID>`.
[Automatic connection](installation-pairing.md) owns account admission and
workspace selection.

`Applications/CloudKit/Notebook.ckdb` defines:

- `NotebookDelivery`: wire version and a JSON envelope up to 4,096 bytes.
- `NotebookBlob`: complete hash, chunk offset/total, chunk SHA-256 and `CKAsset`.

These types need no public grants. CloudKit public-database RBAC and its automatic
`Users` type are not an alternate access path.

Chunks are at most 1 MiB; upload batches contain eight records. Manifest parts
retain the 16,384-address limit. Large snapshots use SQL indexes and bounded
parts, not one Swift array or cloud record. Raster bases and program dependencies
use the same content model.

`cloud_outbox`, `cloud_exports`, `cloud_uploaded`, `cloud_inbox`,
`cloud_chunks` and CKSyncEngine state are local SQL data. Each uploaded record's
ACK is durable; the outgoing prefix advances only after the entire delivery.
Pending engine work is rebuilt from the outbox after restart. An existing immutable
server record is accepted only when identity, metadata and digest match.

Outgoing preparation runs on a serial read worker. One WAL cut captures mutable
records, receipt roots and its journal prefix; dependency discovery then follows
immutable hashes in short reads. Blob storage retains old bodies without GC.
Ink discovery walks stored graph references without replaying measurements.
The derived disk spool is account/generation bound and can never publish content.
The worker authenticates each import batch before the normal writer copies one
manifest payload or inserts at most 64 chunk descriptors. Snapshot parts aim at
1 MiB; the existing 512-part/16,384-address limits can require larger parts near
the wire ceiling, still capped at 64 MiB. The root's ordering references can also
exceed 1 MiB. Encoding, hashing and spool reads stay outside writer admission.

Only a completely imported export is sendable or accepts ACKs. Restart resumes
its exact durable spool; a missing unsealed spool revokes the unexposed export
and rebuilds the cut. Stop/account change cancels new admission and joins the old
run, including any accepted writer result, before releasing its files. Sealing
releases the spool. Explicit Stop also closes local wake admission until account
activation/resume; a late accepted material event cannot reopen the stopped owner.
Idle preparation checks account, generation and journal work
before touching the spool path; only a later real plan retires unclaimed files,
including interrupted SQLite journals.

Incoming chunks may precede their envelope and arrive out of order. They are
persisted before returning from the fetch event and advancing the engine token.
Assembly runs outside the writer queue and Pencil handler; `stageBlob` checks the
complete SHA. Only the shared transaction publishes content after dependency and
owner validation. A staging failure stops the engine rather than acknowledging
lost data.

The OS controls background timing. Internet, quota and execution are not guaranteed.
“Sent to iCloud” means outgoing-record acknowledgment, not receipt or display on
another device.

## Account, release and operational boundaries

First confirmed account admission enables content delivery unless explicitly
disabled before. Every transfer rechecks account and workspace identity. Sign-out
or account change stops exchange without deleting local material or assigning it
to a new account. iCloud failure does not block the local writer or LAN.

Initial account lookup does not delay LAN startup. Before an engine exists, failed
offline startup retries only account lookup after 30 seconds or on a local save.
Once created, CKSyncEngine owns network retries. Disabling sync cancels pending
startup and retry.

Persistent content uses **Production**. Isolated native acceptance has neither
the user's container setting nor CloudKit entitlement. Release tooling validates
the exact container, Production and Push entitlements, real Apple Development
signatures and device-specific profiles on both platforms. Mac additionally
requires its embedded profile, current Provisioning UDID, expiry and permitted
certificate. XPC workers receive no cloud rights.

Initial deployment requires matching App IDs/capabilities, comparison of the
existing schema, Development validation followed by explicit Production deployment,
updated profiles and signed-pair validation. Do not reset an unknown schema or
overwrite an existing container. Authorized CloudKit Console is sufficient;
`cktool` management credentials belong in Keychain, never source or logs.

The historical September 17 schema/signing probes established deployment and
signatures, not end-to-end delivery. A real “iPad uploads, turns off, Mac receives
without LAN” scenario is separate evidence; consult [verification](verification.md).

References: [Apple access design](https://developer.apple.com/icloud/cloudkit/designing/),
[CKSyncEngine integration](https://developer.apple.com/videos/play/wwdc2023/10188/),
[cktool](https://developer.apple.com/icloud/ck-tool/),
[registered-device distribution](https://developer.apple.com/documentation/xcode/distributing-your-app-to-registered-devices),
[profile interpretation](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles).

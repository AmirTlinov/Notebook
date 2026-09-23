# Trusted iPad–Mac transport

Transport carries a selected shared workspace between devices admitted by the
private directory of one Apple Account and stored in Keychain. Bonjour discovers
endpoints; access comes from verified keys, identities and account admission.
See [automatic connection](installation-pairing.md).

## Current compatibility: wire 41, manifest 24

Both applications must use the same wire contract. Version 41 and manifest 24
carry causal page-ink visibility as well as exact compact measurement bodies,
including shared repetitions and tiled fields, rather than flat arrays. An old
snapshot cannot undo a later explicit repeat. Prior wire versions cannot join.
Current admission rejects prior manifest formats, including cloud delivery;
immutable manifests 3–23 remain inspectable as history,
not relabelled as current input. Already accepted transaction echoes retain
normal idempotent acknowledgement without applying their bodies again.
The existing Codex, TeX, package and native-content boundaries remain unchanged.
Package sources require manifest 10 or later and full TeX requires 11 or later.

Content, local containers, workspace/device identities and keys survive an
ordinary update. Installed build status belongs in [verification](verification.md);
a source version alone does not prove installation.

Bonjour advertises `notebook-v41-<UUID>-<generation>`; TXT `workspace` distinguishes
background workspace listeners sharing a Mac device ID. One transport owner
changes the advertisement generation on restart. Metadata grants no trust.

Before a format transition, outgoing shared writes must be acknowledged. Old
journal entries retain their format. A peer behind the transition floor needs a
current checkpoint; its cursor is never advanced artificially. Authenticated
`contentUnavailable` reports a specific upgrade/checkpoint reason without
acknowledging content. The final control frame has a bounded close deadline.
An unchanged incompatible advertisement does not restart exchange every two seconds.

Database admission 17 converts current page/spatial measurement rows and the
reachable pre/postimages named by current undo receipts in one writer transaction.
It retains all original blobs, IDs, clocks, keys and peer cursors. Local pinned
moments are not retargeted. Conversion refuses an unacknowledged peer; rollback
leaves the old admission version and content intact. The transition publishes
current-format rows and records its outgoing floor, never imports old archives.
A repeated open does not repeat conversion or publish another change.

Database admission 20 separates the disposable page-ink reference contribution
into immutable samples and a causal header, so Undo/Redo never hash an entire
stroke again. This index rebuild does not rewrite accepted records, body blobs,
local history or peer cursors. The existing drained-delivery transition records
the new outgoing floor; both applications still update together, not one old
writer beside the new gate semantics.

The migration drain check belongs to the replication owner. Incoming cursor keys
identify a device and possibly a journal generation; outgoing acknowledgements
identify the recipient device. Several incoming generations therefore share one
outgoing check, without deleting, rewriting or treating their incoming positions
as acknowledgements. A distinct historical recipient still blocks admission if
its outgoing writes are unacknowledged; unknown membership is not retirement.

An explicitly retired recipient is different from a disabled automatic connection.
`NotebookStore.retireReplicationPeer` records a local receipt containing the exact
workspace, source cursor and actual outgoing acknowledgement. Cold-launch
`--notebook-retire-peer` accepts only that selected workspace and cursor, before
migration or constructing the model. It never advances or removes a cursor,
changes content, imports an archive or deletes credentials. Other pending peers
still block conversion. The receipt excludes only this device from future direct
transport and cloud-inbox processing; queued historical deliveries remain stored
and unacknowledged. Restart and account-directory refresh cannot revive it.
A new replica does not inherit the local membership decision; a continuing device
keeps it. This operation requires an explicit owner decision, never a timeout or
an inferred absence.

## Authentication and encryption

`NotebookTransportTLS` uses Network.framework and Security with one pinned profile:
TLS 1.2, `TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256` (`0xCCAC`).
ECDHE provides forward secrecy; ChaCha20-Poly1305 provides authenticated
encryption; the pair uses a random 256-bit secret. Both ends verify the negotiated
version and cipher before Notebook messages. Resumption and early data are disabled.

System loopback tests established this profile on the supported SDK. External-PSK
TLS 1.3 did not complete that handshake and is not a supported alternative.
SDK or minimum-OS changes require positive and negative handshake checks.
Loopback success remains distinct from physical-pair acceptance.

`NotebookTransportAuthentication` binds both device UUIDs, the workspace and two
fresh 256-bit nonces using CryptoKit HMAC-SHA256. Both ends verify saved admission,
then exchange ready. Content and history cursors become available only afterward.
Keys use device-only Keychain protection. A local auto-connect prohibition is
persisted before publication and survives account refresh.

An explicitly admitted archive activation selects a new Keychain scope through
its transition ID. Ordinary updates retain that scope. Historical keys and
archives are neither read nor deleted by this path.

## Framing, backpressure and durability

`NotebookTransportSession` owns one TLS connection generation:

| Limit | Value |
|---|---:|
| Frame, including four-byte length | 256 KiB |
| Unacknowledged frames / bytes | 16 / 512 KiB |
| Reserved control capacity | 256 KiB |
| Encoded message queue | 1 MiB |
| Concurrent durable change offers | 2 |
| Connections | 8 |
| Blob transfer chunk | 32 KiB |
| Manifest / individual blob | 64 MiB / 256 MiB |

The receiver validates the length before requesting the body. Replaceable
transient slots retain the latest state instead of accumulating snapshots.
A temporary blob file belongs to one connection generation and hash. Invalid
length, order or SHA-256 discards the incomplete assembly. SQL ingests a verified
file by streaming; a large owner is not assembled in transport memory. Limits
produce errors, never silent truncation.

A receiver retains the returned dependency window (at most 16 hashes), rather
than querying it again after each file. Verified completed files share a staging
commit at the end of the window or once they reach 512 KiB; a larger streamed
blob flushes immediately. Temporary assembly is disposable, not another durable
copy. The SQL commit remains the durability boundary. Sender size and bytes come
from one read transaction; transport never keeps a SQL transaction across a
network await.

Incoming merge protects the native contact's actual page/board/cover material
and placement (or document content/state), using the existing canonical identity.
A conflicting merge rolls back content and cursor together and resumes after the
input owner accepts the tail. An independent page may commit during a board
contact; an idempotent echo needs no contact barrier. This storage admission is
not a claim that a new scene has already been presented.

A frame credit releases transport capacity. A durable `committed` response is sent
only after `NotebookTransportStorage.applyRemoteChange` completes the single SQL
transaction for content, causal merge, deduplication and incoming cursor.
Reconnect resumes from that cursor. A lost ACK neither loses a completed write
nor duplicates an action. Late transient events and disconnects cannot revive a
retired connection generation.

Program manifests and their complete dependency closure are validated before
publication or ACK, including retained competing source heads, original inverse
actions and completed undo. State strings resembling hashes are not dependencies.
Missing data leaves the previous content and cursor intact. Direct and cloud
delivery share this rule; see [cloud delivery](cloud-delivery-contract.md).

## Session selection and Codex traffic

Active-scene selection uses one replaceable transient slot after contact and
presence. Device identity, session sequence and connection generation prevent a
late message from restoring a cleared selection. An inactive scene publishes
unknown, not a saved viewport. Selection is session data, not durable content or
proof that an agent action was displayed.

Chat uses `NotebookChatEnvelope`, up to 192 KiB inside the existing frame.
The iPad retains one request and retries the same UUID until response or
disconnect. The SQL outgoing journal proves persistence; a transient frame does
not. Responses are routed to the same trusted peer and connection generation.
LAN, bounded Apple peer-to-peer discovery and relay belong to the same
`NearbySync` owner. See [agent runtime](agent-runtime-contract.md) and
[remote work](codex-remote-work.md).

## Local Mac IPC

`SocketIO` implements the private Unix channel between `NotebookIPCServer` and
`NotebookIPCClient`: socket-owner validation, bounded waits, interrupted-read
retry and length validation before allocation. Its limits are separate from TLS.

`stopAndDrain` closes admission and waits for readers and accepted writer commands.
Closing a socket is not completion of its SQL command. The server owns admitted
sockets before queued workers start, closes them synchronously on shutdown and
prevents late workers from reading released descriptors. Accepted writes retain
their owner until completion. Completion timing is measured under the server lock;
a repeated drain of an already-finished owner returns zero wait.

## Verification and references

`NotebookTransportSessionTests`, `NearbySyncTests`,
`NotebookTransportBlobTests` and `NotebookIPCTests` cover actual system handshakes,
incorrect secrets, proof/ready, bounded queues, chunk integrity, commit-before-ACK,
reconnect, stale generations, Unix socket permissions and accepted-command drain.
Exact runs and their scope are in [verification](verification.md).

Primary references: [Security PSK API](https://developer.apple.com/documentation/security/sec_protocol_options_add_pre_shared_key(_:_:_:)),
[Security cipher configuration](https://developer.apple.com/documentation/security/sec_protocol_options_append_tls_ciphersuite(_:_:)),
[negotiated cipher](https://developer.apple.com/documentation/security/sec_protocol_metadata_get_negotiated_tls_ciphersuite(_:)),
[RFC 7905](https://www.rfc-editor.org/rfc/rfc7905.html).

# Automatic connection of personal devices

Open Notebook on a Mac and iPad using the same Apple Account. That is the normal
connection flow. The Devices screen reports status; it is not an enrollment step.
First discovery requires iCloud. A saved pair can subsequently use the local
network without internet. Writing remains available without a Mac; chat and live
agent interaction require a reachable, running Mac.

## Trust owner

`NotebookAccountConnection` owns registration, account changes and network-error
retry. `NotebookAccountCloud` uses only the private database of
`iCloud.com.amirtlinov.notebook`: zone `NotebookAccount`, record
`NotebookDevices/devices`. Its `directory` field is **ENCRYPTED BYTES**.
Bonjour and cloud notifications do not grant trust.

`NotebookAccountDirectory` holds workspaces, registered devices and random
256-bit Mac–iPad pair keys within a workspace. CloudKit CAS
(`ifServerRecordUnchanged`) preserves concurrent registration and a single
canonical key. A saved device key may fill an unknown pair; after registration,
the private directory is authoritative. Both devices must be registered before
a key is issued.

`NotebookKeychainDeviceStore` atomically persists the account, keys and local
auto-connect prohibition, then reads them back. Protection remains device-only.
One-time decoding of the former format accepts completed trusted pairs only.
The live applications have no invitation, QR or manual-approval flow.

`NearbySync` starts sessions only for saved devices. Trust writes are ordered and
accepted writes finish during shutdown. Late completion cannot revive a stopped
owner. An unchanged directory does not rewrite Keychain or restart Bonjour.
A key change closes the old session before reconnecting. Disabling auto-connect
retains the key and survives account refresh.

## Account and cloud scheduling

One `NotebookCloudSync` / CKSyncEngine owns the private database, observing the
account zone and, when content sync is enabled, the selected workspace zone.
There is no second engine or independent push/subscription route. Account events
wake the CAS owner; the first observation explicitly fetches the account zone.
Delegates do not await their own registration task, and every await rechecks
owner generation.

Errors use bounded exponential backoff; foreground/network recovery allows a
retry. A healthy connection is not continuously polled. Account change or sign-out
stops exchange immediately and preserves local content. Materials and keys never
move automatically to another account.

Content sync starts with the first confirmed account unless the user previously
disabled it. Its switch controls content delivery, not device registration or
local deletion. The directory carries no chat, voice or terminal data.

## Workspace lifecycle

A new empty device automatically opens the account's default workspace.
Input accepted while account lookup is pending cancels this switch; independent
nonempty workspaces are not merged. An empty replica waits for actual content
instead of publishing a competing starter notebook or empty cloud snapshot.
The user can choose another workspace while loading.

Each workspace has a separate SQLite store and writer. `NotebookApplicationLaunch`
drains accepted input and the previous writer before opening or deleting one.
`NotebookWorkspaceLibrary` owns the local catalog and selected UUID. Destination
admission precedes saving selection. Removing the last workspace leaves the
chooser; it does not silently create a replacement.

Creation, naming and local use work without pairing. Published names use account
CAS; filenames and UUIDs are unchanged. Historical archives are not restored.
An installation activation marker, the common Codex working directory and an
independent archive are outside a workspace's deletion scope.

- **Delete from this device** removes local materials after confirmation and
  leaves the cloud copy. The confirmation warns that unsent changes can be lost.
- **Delete everywhere** first persists intent, then CAS-removes membership/keys
  and writes a UUID tombstone, then removes the cloud zone and local files.
  Interrupted deletion resumes the same intent. An offline device later reading
  the directory cannot register that UUID again and removes its local copy.

Directory format 2 reads format 1 once while preserving keys; an old application
cannot overwrite format 2. Update both applications together.

Explicit archive activation is a separate data-admission operation. Its transition
ID selects a new device-only Keychain scope; ordinary updates preserve the
existing one. See [archive transfer](archive-transfer.md).

## Release and verification

Current wire/manifest admission is specified by the
[transport contract](transport-contract.md). Signed builds use team `M94V58FCVP` and
preserve installed container identities. The `NotebookDevices` schema must be
deployed to Production.

`NotebookAccountDirectoryTests`, `NotebookDeviceTests`,
`NotebookAccountConnectionTests` and real TLS tests cover CAS, account changes,
Keychain persistence, admission, proof/ready and stopping late registration.
Compilation and local tests do not establish real CloudKit delivery or physical
iPad behavior. Installed-pair evidence is in [verification](verification.md).

Apple requires one engine per database:
[CKSyncEngine.Configuration.database](https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5/configuration/database).

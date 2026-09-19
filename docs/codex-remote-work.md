# One Codex task across Mac, iPad and remote transport

## Ownership and runtime

`NotebookApplicationLaunch.codexHost` owns one official stdio App Server.
Workspace sidecars own existing `chat_jobs` delivery; Mac task windows and iPad
use the same route. Codex owns projects, tasks, history, settings and processes.
Adding a Mac folder uses the official idempotency key from the durable action,
not a second project catalog or unsolicited worktree.

Up to eight workspace/IPC owners may remain open. Only inactive ones can be evicted.
Unfinished commands, uncertain outcomes or active execution block workspace deletion.
An active task is pinned to its workspace. External tools use the selected global
Notebook socket; Notebook-owned tasks receive their workspace socket at create/resume.

Another active Codex writer is a refusal, not takeover or cloning. History is still
readable. Attaching to a Desktop daemon is not a hidden fallback; the Desktop window
need not be closed, and closing Notebook's last window does not stop execution.

The bundled runtime pins official Codex **0.155.0** and Node **24.21.0**, validated
by archive hashes and vendor signatures. `prepare_notebook_codex.py` currently
admits arm64 and validates inventory before bundling:

```sh
python3 Applications/prepare_notebook_codex.py --stage "$PWD/.build/notebook-codex-runtime"
```

Replacement removes the old runtime as a unit. A permitted standard-location signed
CLI fallback is version-checked; private Desktop Node is not used. Never update a
running runtime in place: finish active tasks/terminals before pair replacement.
Current transport is wire 37; containers, keys and identities remain unchanged.

## Account

Mac and iPad account UI uses `account/login/start` with `chatgptDeviceCode` and
validates the official HTTPS URL. iPad displays the code/link; Codex on Mac receives
and stores tokens. Login cancellation uses loginId; logout is explicit and confirmed.
Replaying an attempt/revision neither starts a new ceremony nor signs out a later
account. Unknown limits remain unknown. Active work blocks account switching.

Admission and execution check public account identity. Changed type/email rejects
unstarted saved commands; a plan change is not an identity change. Uncertain
attempts never become fresh commands. Account validation does not wait for rate-limit
lookup. Revoking a device, signing out and stopping a turn are distinct actions.

## Internet route and selection

1. Establish existing account trust first.
2. Import an administrator-issued route JSON on Mac under Devices → iPad →
   Internet access. Routing capabilities live in Keychain, not content/SQL.
   The client capability reaches iPad over the already-trusted direct channel.
   Internet-only first enrollment is unsupported.
3. Mac opens an outbound TLS/443 CONNECT uplink. iPad uses app-scoped
   Network.framework HTTP CONNECT. Inside remains existing ECDHE-PSK/
   ChaCha20-Poly1305 TLS and proof/ready.
4. Relay connects only the two roles of one provisioned route. It has no pair key,
   ChatGPT tokens, Notebook commands or SSH/App Server endpoint.

LAN is tried first. After four seconds, peer-to-peer discovery gets a bounded
12-second window, then returns to LAN-only. Discovery stops once direct transport
is selected. Network changes debounce for three seconds; reconnect backs off to
32 seconds. Nearby status comes from the resolved selected endpoint, not Bonjour
hints. DataTransferReport records interface/counters without payloads or keys.
Loss of default internet path can still trigger bounded AWDL discovery.

Bonjour workspace TXT selects the proper listener among background owners sharing
a device ID; authentication still happens inside TLS.

iPad alone selects a channel. A candidate must pass TLS, identity, workspace,
protocol and ready. Within one network generation preference is LAN → nearby →
relay; a new authenticated network path may replace a stale one. Mac parks candidates
until the first selected iPad transient, then closes the old socket. This avoids
old EOF overtaking new selection. Stale errors cannot disconnect the new generation;
durable command IDs survive switching.

## Queues and failures

- Up to eight route workers let independent tasks proceed without waiting for
  another task's slow creation. Stop/decision bypass queued next-turn text.
- iPad has one ordinary request and one reserved human-control request. Retries
  preserve envelope/command IDs; native approval is fenced before await so two
  devices cannot send it twice.
- Existing transport limits apply: 32 KiB chunks, 1 MiB queued, 512 KiB unacknowledged
  with 256 KiB reserved control capacity, two manifests. Events coalesce at 100 ms.
  Credits are not durable acknowledgments; no second bulk store/channel exists.
- Files, conflicts, PTY, voice and content retain their existing owners and rights.
- Revocation closes channels and rejects new/unstarted commands, surviving cloud
  refresh. Relay revocation closes tunnels and old client credentials. Already
  accepted native work requires a separate Stop.
- iPad sleep/disconnect ends display, not Mac work. A sleeping/offline Mac is
  unavailable; there is no cloud executor or promised wake-on-WAN.
- App Server death ends live processes while preserving output. Reconnect never
  reruns arbitrary shell input. Unknown stays unknown until positive native evidence.
- Explicit Mac quit warns about active work; closing the last window does not.

Operations: [relay guide](../Relay/README.md). Evidence: [verification](verification.md).
Simulator/loopback does not prove AWDL or two physical networks; device-code
start/cancel does not prove a human-completed login.

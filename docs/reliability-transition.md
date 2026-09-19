# Reliability status and acceptance boundaries

This is a map of current contracts and unresolved acceptance, not a release log.
[September 8](audit-2026-09-08.md) and [September 13](audit-2026-09-13.md) audits are
historical baselines. Linear owns task state; [verification](verification.md) owns
exact source/build/install evidence.

## Data policy

Applications read the current SQLite format. Amir canceled historical restoration
on September 11; independent backups remain in reserve. They are not input to
ordinary tests or updates. In-place pair updates preserve current containers,
device/workspace identities and keys. An old activation receipt cannot replace
later content. See [preservation](current-mac-preservation.md),
[archive transfer](archive-transfer.md) and [release procedure](release-build-contract.md).

## Current ownership

| Behavior | Contract |
|---|---|
| Addressed transactional content and causal delivery | [Spatial replication](spatial-replication-contract.md), [owner windows](replication-owner-window.md) |
| Trust, reconnect, bounded transport and private cloud | [Transport](transport-contract.md), [automatic connection](installation-pairing.md), [cloud](cloud-delivery-contract.md) |
| Accepted geometry, native input and resources | [Scene allocation](scene-allocation-contract.md), [performance](performance.md) |
| Ink identity, drawing tools and undo | [Page ink](page-ink-conflict-contract.md), [graphics](editable-graphics-contract.md) |
| Canonical PDF/source and one program executor | [Paper](document-page-fragments.md), [programs](document-program-fragments.md) |
| Shared attention and durable agent effects | [Collaboration](collaboration.md), [SDK](notebook-javascript-api.md) |
| Native Codex work and account routing | [Runtime](agent-runtime-contract.md), [remote work](codex-remote-work.md) |

Accepted logical geometry owns body, frame and hit testing; delayed overview pixels
cannot move material backward. Background preparation cannot steal admitted contact.
Physical composition uses exact source/state/crop/density and real resource leases.
Persistence, delivery and shown evidence remain different facts.

## Open scope

As checked during this documentation update on September 19–20:

- [GUI-196](https://linear.app/main-cluster/issue/GUI-196): physical interaction/
  erased-material and related regression acceptance remains tracked independently.
- [GUI-197](https://linear.app/main-cluster/issue/GUI-197): causal convergence and
  human-continuation acceptance is not closed by merging unrelated UI changes.
- [GUI-183](https://linear.app/main-cluster/issue/GUI-183): remote Codex work has merged
  code and focused evidence; actual WAN/multidevice scope must retain its own receipt.
- GUI-240 was closed by Amir's explicit decision. This is not a statement that every
  GUI-250 physical performance/long-session condition passed.

Consult the linked issues for later state changes. Historical “Mac build 17”,
migration requirements and blanket full-verification gates no longer describe an
ordinary update. Focused checks plus the affected gesture are the default.
A full acceptance claim still needs system frame/CPU/GPU/memory measurements, ten
scenario repetitions and 30 minutes of collaborative use on the named immutable build.

[Complete former transition journal](https://github.com/AmirTlinov/Notebook/blob/1723ec2be6f6b8dda29e3a575fd6376fff03e093/docs/reliability-transition.md)
preserves historical findings, superseded plans and negative evidence without making
them current instructions.

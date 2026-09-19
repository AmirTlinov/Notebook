# Technical design and research map

Notebook is a shared material workspace with device-local presentation and one
authoritative owner for each behavior. Product direction is in
[PHILOSOPHY](../PHILOSOPHY.md); source ownership is in [AGENTS](../AGENTS.md).
This page explains the current technical choices. Detailed dated experiments remain
in Git rather than being repeated as current architecture.

## Input and physical space

UIKit/AppKit own native input; measured Pencil samples and shared Metal geometry
form the ink path. Prediction is temporary, late force updates are guarded, and
UUIDs/causal activity preserve accepted history. Eraser and pen share measurement/
render ownership. Camera and native material use one exact tiled-world projection.

A contact fixes its physical owner and basis until completion. Menus, text fields,
program controls, page curl and camera gestures follow explicit admission; background
rendering cannot steal a contact. Selection and manipulation live in one session.

- [World addresses](world-address-contract.md)
- [Ink and tools](page-ink-conflict-contract.md)
- [Selection and attention](shared-context-contract.md)
- [Camera performance](performance.md)

## Finite scene work

Spatial indexes bound traversal and workset, including dense overlap and nested
portals. Native camera motion transforms installed planes; source readiness and
density refine independently under one resource allocator. Derived tiles preserve
painter order without becoming editable content or detailed evidence.
Every real CPU/GPU/WebKit borrower retains its accounted lease until completion.

- [Large boards](board-scale.md)
- [Allocation and publication](scene-allocation-contract.md)
- [Board receipts](board-publication.md)
- [Heavy fixtures](load-fixtures.md)

## Documents and executable material

`NotebookTypesetter` produces one canonical PDF/SyncTeX artifact on both platforms.
Quartz draws paper; native UITextView/NSTextView edits addressed source.
Code/Side-by-side exposes assembled LaTeX, including explicit interactive-block
comments and package references. The old textarea/DOM paginator and independent
native Tectonic export path are not current owners.

WebKit owns bounded program viewports, package-origin assets and authored lifecycle,
state, semantic attention and export callbacks. One program context can span physical
page clips; passive pages borrow pixels rather than run duplicate programs.
Saved export captures source/state together; presented export requires exact frozen
attention evidence. No generic placeholder represents an interactive frame.

- [Canonical paper](document-page-fragments.md)
- [Program lifecycle and packages](document-program-fragments.md)
- [Links](document-link-navigation.md)
- [Export](document-export-contract.md)
- [Offline computation experiment](executable-ink.md): explicitly not a finished
  handwriting calculator

## Durable collaboration

SQLite/WAL is the content owner. Addressed commands check source versions and scope
inside one transaction; causal merge retains concurrent author heads, and undo
preserves later human adoption. Derived indexes support bounded reads without
creating another source of truth.

Direct TLS and private CloudKit carry immutable manifests/blob dependencies.
Account directory admission precedes content. Open item, camera/zoom, selection and
navigation remain device-local; sharing material does not redirect another device.

- [Replication](spatial-replication-contract.md)
- [Transport](transport-contract.md)
- [Cloud](cloud-delivery-contract.md)
- [Shared actions](collaboration.md)

## Agent runtime and evidence

The official bundled Codex App Server owns model execution, projects, task history,
auth and permissions. Notebook adds workspace routing and durable delivery, not its
own agent runtime. User SDK scripts run in bounded QuickJS/XPC with a separate trusted
markup/TypeScript preparation service. Reads, writes, package admission and explicit
presentation preserve their capability boundaries.

A saved action, received action, ready render, installed source and human observation
are different facts. Tests establish their named contract on their named source,
not automatic release readiness. Use [verification](verification.md) for actual scope
and [release procedure](release-build-contract.md) for current commands.

The complete earlier design notes, upstream links and historical measurements are
preserved in [the original research record](https://github.com/AmirTlinov/Notebook/blob/1723ec2be6f6b8dda29e3a575fd6376fff03e093/docs/research.md).
Old proposed interactions, compatibility assumptions and performance figures there
must be interpreted against their date and source revision.

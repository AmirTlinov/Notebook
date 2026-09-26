# Document links address physical pages

`DocumentPrintNavigation` reads actual PDF annotations and GoTo destinations after
canonical compilation. URI targets and page numbers come from that PDF, not an
independently measured DOM. Rectangles convert from PDF points into installed page
geometry. SyncTeX separately maps source lines.

Limits: 16,384 links, 4,096 bytes per URI and 1 MiB total URI bytes.
Markdown/LaTeX navigation is supported when represented in the canonical output;
arbitrary browser navigation is not silently treated as a printable link.

## Activation

A canonical fragment sends the original href with document/source/state/runtime,
generation, page and pixel identity. Terminal clicks carry a monotonically
increasing number; `userActivated` comes only from `event.isTrusted`.
`DocumentWebCoordinator` rejects repeated sequence, stale source, neighboring
pages and unmounted hosts.

New input admission and completion of an accepted click are distinct. Closing input
policy stops new hit tests immediately while retaining an accepted touch's UIKit
subtree through delivery. A late trusted click can complete only on that same
previously admitted canonical surface. Programmatic clicks require current admission;
they inherit no human completion right. There is no deferred coordinate replay.

`NotebookAppModel.activateDocumentLink` validates current content, open document
and originating page, resolves canonical layout and changes device-local reading
position through the existing presence owner. A preceding state commit is preserved
and does not falsely invalidate an unchanged source. Double-clicking a link does
not open the source editor.

`#` targets the first page; a named fragment targets its measured destination.
A missing destination reports an unavailable link rather than pretending success.
HTTP(S)/mailto uses system opening only after real user activation. Passive
preparation and scripted clicks cannot launch another application. File, executable
and relative cross-document URLs are rejected.

## Page preparation and handoff

`PageTurnActivity.PreparationDemand` distinguishes curl snapshots from live distant
navigation. `DocumentPagePresentationOwner` prepares the target, while
`DocumentProgramOwner` independently owns program checkpoints.

An addressed offscreen notebook/document keeps one workspace settlement. Its
closed cover first approaches the actual viewport; only then can its mounted
paper establish render readiness and authorize opening. Both animation stages
share the original duration, request identity and rollback origin. A closed document
also approaches while preparing when its cover is already partly visible but its
reading camera differs; visibility alone cannot serialize these independent stages.
The admitted preparation target is not culled by the old board camera. Offscreen preparation
is never reported as a displayed page, and cancellation retires both stages.
The prepared source demand is checked separately from the actual camera. A
canonical deletion/transfer proof is installed before retiring its mounted owner;
late input cannot restore the old placement. iPad ends that camera passage, while
the AppKit mouse owner validates the same semantic presence before both drag and
lift. Stationary paper refines its backing before opening, not after landing.
The existing native preparation channel refines the installed page at its actual
pose before its ready result can authorize a stationary opening. It revokes the
old movement-quality receipt synchronously; a later SwiftUI quality update does
not allocate the same backing again. The existing confirmation clock stays active
through both short stages, and returns to its idle cadence outside a pending passage.

The current paper remains interactive during preparation. The target gains input
only after native installation and publication of its current role.
`didInstall` retains the completed demand identity across SwiftUI updates.
Both gesture and external navigation capture that identity at admission. A second
contact may prepare the next sheet before the first one lands, but the first
completion acknowledges only its own captured preparation, never the newer demand.
Replacing source/target or closing cancels only that preparation; late completion
cannot acknowledge a newer demand.

Live handoff installs prepared paper, then mounts required program runtimes.
An interactive-block failure does not prevent reading text. A complete curl image
still requires every program's pixels; a failed composite does not poison later
live handoff. Internal paper WebKit scrolling is disabled; native camera/curl and
the source editor each retain their own scrolling owner.

## Checks

`DocumentLinkNavigationTests` and `DocumentLinkActivationTests` cover destination
indexing, schemes, generation guards, accepted-click completion and state-before-link
ordering. The UI scenario
`testDocumentLinksOpenTheMeasuredDistantPageAndReturnToContents` uses real taps,
including a missing target. A historical installed-pair check on 0.3.22 (25)
confirmed the contents-to-chapter gesture with Amir. It does not prove current
whole-system performance; see [verification](verification.md).

# Shared context: history, references and selection

## Immutable history

`SharedContextEntry` is an immutable indication or reply addressed by context UUID
and entry UUID. `VersionStamp` (counter, device author) and entry UUID define order.
An earlier-arriving reply does not renumber or rewrite stored entries.
`records.position` is not a second authorial order.

`appendContext` reads the root, direct reply parent and maximum causal counter,
then publishes one entry, its indexes and journal in one transaction.
`SharedContextAppend` returns that entry, not the whole conversation.

Incoming context addresses are read in batches of 64. Roots require matching UUID
and structure; existing entries accept only identical content. Deletion, changed
UUID, unknown parent or invalid counter rejects the entire delivery. Parents are
validated after all incoming entries are installed, independent of batch order.
Content, deduplication, receipt and cursor commit together. Full `SharedContext`
remains an external-transfer/checkpoint form.

## Bounded reads and authority

`context_entry_order` is a derived canonical index. Causal-order and author indexes
find page boundaries and the first human indication without scanning intervening
replies. A page is at most 64 entries / 4 MiB; one entry is at most 2 MiB.
Continuation binds to that context's revision, not camera or another context.

`context_references` stores entry address, reference identity and hash, not duplicate
reference bodies. Both indexes share the physical writer. Pinned-source validation
reads the exact human reference and canonical value; an agent-created reference
does not establish human authority.

Action scope retains the union of historical references. Duplicate references are
skipped by indexed hash lookup. One calculation admits at most 512 distinct
references and 4 MiB of source records; exceeding this returns
`context_reference_budget` before mutation. Placement and writes use the same read.
Action confirmation/undo checks the context and named entry without loading history.

External preparation rebuilds indexes only in an independent candidate, preserving
canonical bytes, historical positions, identities and cursors. Failed rebuilding
rolls back both tables. Activation validates definitions and every indexed author
and reference; missing/corrupt indexes reject admission.

## One selection owner

`NotebookSelectionSession` owns one current target: item, artifact, selected set,
lasso region, context or temporarily presented reference. A lasso region is an
explicit target, not an extra choice beside a nil target. Pending movement,
program/text focus and pinned references belong to that same selection.
`NotebookAgentQuestion` is its immutable reference value, not another controller.

Finger tap indicates material; actual body movement starts manipulation. Pencil
lasso addresses a region or whole objects according to its selected mode. A region
crossing open paper is clipped to that paper, not redirected to the hidden board. Camera and scale are fixed at contact start.
Dragging the same selected source neither adds another indication nor sends a message.

A tap's small ink-hit tolerance is not a clipping polygon. It selects the complete
accepted contact, including its same-surface spans and later erasures. The first
edit uses the existing conversion command without creating an outside remainder;
selection itself writes nothing. An explicit region lasso still clips its exact
contour.

Chat and companion use one small `NotebookContextCounter` for source count, reviewed
version and clearing. Paper shows a thin contour, without a floating question editor.
Chat size and counter actions do not change the Pencil contact or send destination.

A new tap replaces selection immediately; empty-paper tap or clear removes all of
it. Navigation ends manipulation but retains pinned reviewed content as context.
Late saves/history reads recheck selection identity and cannot resurrect replaced
frames. Send waits for new-source persistence; failure never restores an old selection.

Closed covers receive contact through `NotebookInteractionTouchView` only.
Artifacts, including native text, retain their own input. Covers and scene selection
consult the same exact visible-geometry picker; neither a selected bounding box nor
an erased hole independently intercepts a contact. Spatial element addresses
include board ID, so deferred work never substitutes the current camera's board.

## Session publication

`NotebookSelectionEnvelope` serializes the existing selection, physical surface,
device/session and increasing sequence. Camera, highlight and preview geometry
alone do not create a selection generation. Inactive scenes publish unknown while
retaining local selection; activation republishes it with a new sequence.

Mac accepts only the current authenticated connection/device/session and increasing
sequence. A stale disconnect cannot clear a new connection. The single local runtime
record is not replicated content, an undo action or a content cursor change.
Startup/disconnect makes it unknown. MCP reads that projection through ordinary
addressed reads.

## Direct geometry manipulation

One `NotebookElementControls` frame has four corner targets of 44×44 points;
delete stays outside them. Pencil outside controls reaches paper. One
`NotebookElementManipulation` value owns the full address, initial bounds, grabbed
corner, allowed extent, target field identity and world anchor.

Preview and committed geometry use the same calculation. The opposite corner is
fixed; minimum size/paper edges constrain only the dragged corner. Movement counts
from first contact, including pre-recognition motion. Body hold, corners and
accessibility actions use the same owner.

Cancellation, selection/camera/window change, a second finger or Pencil start
discards preview without restoring old stored geometry. Completion checks contact,
bounds, target identity and anchor; Core repeats that check inside SQL. A late
release cannot resurrect deleted content or move a replacement with the same local ID.
Transforms change relative placement while retaining measured material and masks.
A region retains its exact contour during preparation. Its first move, resize,
rotation, copy or deletion checks the captured native sources, ancestor bases and
ink revision, then splits/edits in one undoable command. A cancelled contact never
splits the document. Materialized multi-source fragments keep one selection and
working resize controls; all members use the same surface transform.

Accepted bounds and the actual owner frontier return together, including concurrent
neighbors. A truly deleted target clears selection after page admission; a temporary
unloaded range does not. Native editor completion also checks full address and
selection identity. `isPointing` is derived from the current accepted contact/region.

Rendering, handles and hit testing use the same admitted physical projection, with
no retained second drag offset. Background composition catches up independently.

## Evidence for displayed regions

`NotebookReferenceBasis` retains installed-ink evidence and per-element, placement,
board-header and order-neighbor contributions from one SQL cut. Capture replaces
only live contributions and accepted ink; static pixels and ancestors retain their
original basis. Deletion removes its contribution and joins former neighbors.
This is temporary displayed-material evidence, not another content index.

Persistence checks the result against SQL. Ordinary move/resize/delete can support
pointing without waiting for a new overview image. If an unseen region changed or a
stack reconstruction affected static pixels, the full region waits for consistent
composition rather than assigning a fresh hash to old pixels. Exact live-element
references remain available. New HTML becomes shown only after its image is ready.

## One-shot laser context

`NotebookLaserContext` retains the last five completed local indications for a
specific Mac and draft/task, each expiring after 30 monotonic seconds before
submission. Drawing alone writes nothing. Send reserves its exact batch through
preparation and consumes it only after durable admission; a failed write keeps the
prepared image addresses for Retry. Starting dictation does not consume it. A
different chat/computer never inherits it, and the crop-count clear action discards
unsent captures.

A message carries at most five frozen displayed images / 4 MiB total. Missing
evidence is not replaced with newly captured pixels. Persistence uses SharedContext
and AgentPinnedSource with `select: false`. Chat jobs carry evidence addresses;
PNGs use normal blob delivery. Mac waits for those exact images before the native
Codex turn. Frame/job limits remain unchanged.

The delivered packet belongs to that message and its idempotent retries, not future
drafts or automatic context.

## Checks

`SharedContextReadTests`, `SharedContextReplicationTests` and
`SharedContextReferenceTests` cover 100,000-entry histories, bounded reads, immutable
hashes, concurrent order, cross-batch parents, rejection and external index rebuilding.
These contracts do not establish physical display or whole-system performance.
See [verification](verification.md).

## Изображение при отправке в чат

Явное указание и выбранный физический фрагмент отправляются в native Codex как
реальный image input по существующему immutable evidence/blob пути, а не только
как инструкция вызвать `nb.attention`. Без явного указания отправка фиксирует
текущую установленную область Notebook тем же владельцем attention capture.
Если этот обычный вид ещё не готов, контекст явно сообщает отсутствие изображения;
метаданные камеры не выдаются за доказательство видимых пикселей. Выделение исходника
(document block без номера печатной страницы) и codeFragment остаются смысловым
контекстом, а не выдуманной картинкой.

Указка относится к точному Mac и local draft либо native thread, включая первую
отправку нового чата. Один contact переносит один композиционный кроп, без дублирующих
картинок обложек внутри него. Ошибка обязательного кропа запрещает отправку без него.
Подготовленный пакет сохраняет те же адреса изображений при повторе неудавшейся
записи сообщения; только подтверждённая локальная запись потребляет указания.
Выделение и указка проверяются вместе в общем бюджете изображений до приёма
сообщения. Превышение откатывает новый контекст и не оставляет бесхозных PNG;
пользователь может убрать лишнее и повторить тот же текст. Это локальная подготовка,
а не новый запрет принимать доставляемый запрос раньше его изображений на Mac.

Повтор использует прежний immutable пакет только при прежнем явном намерении:
тот же адрес беседы/текст, вложения, selection ID и поколение указки. Снятие выбора
или удаление указания не воскрешает прежнюю картинку. Перед заменой неудавшейся
отправки существующий writer FIFO проверяет её точный durable ID: отсутствие
разрешает новый пакет, подтверждённая прежняя запись восстанавливает её квитанцию
без отправки изменённого черновика, неизвестный исход запрещает дубликат.
Истечение указки само по себе не меняет уже зафиксированное намерение Retry.

Фон бумаги — один векторный display-list (`Color` и линии `Path`), а не локальный
Canvas с неверным exposure под native camera transform. Координаты страницы,
масштабирование и immutable image capture от этого не получают нового владельца.

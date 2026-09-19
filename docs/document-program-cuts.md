# Physical program cuts

`DocumentLayoutRecord` binds each paper rectangle to its offset in the original
block. Two pages can have identical paper bounds while showing different parts of
one program. `sourceOffset` is required in the admitted layout and
`DocumentBlockRegion`, not an optional JavaScript hint.

The incoming offset must be finite, numeric and nonnegative; Boolean values are
not coordinates. Native admission converts it to the same physical units as the
rectangle and rejects unrepresentable values. Absence does not mean zero.
Whole-source versus page comparison checks offset with the same 1/32-point
rounding allowance. An inconsistent neighbor cannot replace accepted source layout.

Current offsets come from canonical print slots and SyncTeX. One
`DocumentBlockRuntime` owns the program; passive continuations borrow its pixels
without starting another executor. See [program fragments](document-program-fragments.md).
The former outstanding duplicate-iframe issue below is historical, not the current
ownership contract.

## Historical regression

`DocumentCutOriginTests` covered equal paper frames with different source offsets,
unit conversion, missing/nonnumeric offsets, overflow and inconsistent neighbors.
All five regressions failed against the old admission owner, then the focused
profile passed 118 Mac and 48 iPad tests without skips or runtime warnings.

A separate early negative test found a duplicate passive executor. Stock Mac WebKit
could capture valid pixels within its own bounds but outside its visible native
parent without resizing or a second launch. That finding did not prove Canvas/WebGL,
iPad input or complete lifecycle ownership; the later single-owner implementation
is documented in the linked contract.

Full source hashes, failed/interrupted attempts and image paths are retained in
[the original evidence](https://github.com/AmirTlinov/Notebook/blob/1723ec2be6f6b8dda29e3a575fd6376fff03e093/docs/document-program-cuts.md).

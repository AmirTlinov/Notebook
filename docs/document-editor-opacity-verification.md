# Historical source-editor opacity check — September 14, 2026

The former expanding source editor used a 0.7-alpha background, letting neighboring
paragraphs show through. An opaque white surface fixed legibility without changing
geometry, focus or persistence.

Real on-screen keyboard input and original before/after Simulator PNGs were visually
reviewed. Evidence:
`.build/document-editor-opacity-fix-v1/post-fix-visual-receipt.json`.

- Before source hash:
  `1504a41289cc91b82f5bb420443cf333fe6449b670533172e41519bc9fb9501e`.
- After source hash:
  `a8ddbd4924f128d9e3a77b8e0f510bd62659508255281c692133fa348113e807`.
  Built at HEAD `142b9f2`; no later commit is attributed to that build.

This was a narrow visual check. A separate full UI retry failed because the next
page did not prepare after Save; no working pair was updated by this attempt.
That historical failure is not a claim about the current native editor, whose
contract is [canonical paper and source](document-page-fragments.md).

[Original image identities and report](https://github.com/AmirTlinov/Notebook/blob/1723ec2be6f6b8dda29e3a575fd6376fff03e093/docs/document-editor-opacity-verification.md).

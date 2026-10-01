# Notebook panel checks

Chrome CUA used the actual bundled HTML and ext-apps2.0.3
AppBridge/PostMessageTransport with isolated RAM fixtures. This scope establishes
browser interaction and the SDK bridge. Codex mounting and native persistence
are separate checks.

Pointer and keyboard checks passed: host-delivered initial result; existing/new
text and Cmd+Enter; multiline frame growth; move/resize; shape/arrow creation;
human undo; polling after an agent update; model context; focus and toolbar in a
780×1000 viewport. Lost accepted-response retry kept the same arguments/actionID,
retained the editor draft, gated subsequent writes, and produced one insertion.
Browser console errors/warnings:0.

The final rich-text guard was checked separately: non-null format and nonempty
UTF-16 runs show readonly placeholders. Double-click, Enter, Delete and drag
produce no editor, handles or write. Plain text with null format and empty runs
still edits and saves. Partial appearance is readonly; erased material is hidden.

The final session guard was also checked through the actual SDK: foreign host
results during a draft and a lost-response pending write preserved surfaceA;
retry kept its arguments/actionID. An earlier held pollA arrived after explicit
card navigation to B/cursor100 and left B and its model context intact.

Final guard source SHA256:

| File | SHA256 |
|---|---|
| surface.ts | 5d8c9607000d9d16c24a4a559ed7e3202549e310fcb9d52ace608ffbdacf0f4b |
| panel.ts | 0676079573ae4422c0bc866e5e91d252f02928fba379262f3b593485331f33c1 |
| session.ts | 2fc8e667b7b368f4402cea0c7d3fb45a7905f8ab2308da93c8fb4d6a62ed19cd |
| build-panel.mjs | 2a17a538d8be8f5fd4cd8c638435773d04daf53a78eb375914605e5641de6785 |

The broader gesture pass preceded the readonly and session guards;
panel.ts and the bundler remained unchanged. mcpapps was unavailable
on the supported host retry. Native Codex inspection was rejected by the tool;
no alternate inspection route was used. Actual Codex UI acceptance remains open.

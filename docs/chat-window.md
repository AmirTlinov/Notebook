# Floating chat window

`NotebookChatWindow` stores preferred position and size in local window settings,
separate from the conversation, draft, and `SessionPresence`.
`NotebookChatWindowLayout` projects edge anchors into available window space.
Keyboard and rotation constrain the displayed frame temporarily while preserving
the preference and the board's mounted camera.

The header and collapsed companion move the window. The outer rims at all four
corners resize it through `NotebookChatResizeCorner`; nearby controls retain
their central hit targets. The gesture holds its starting frame. An available-area
change finishes the measured portion, and system cancellation releases input.
Top tools, the composer, and paper navigation remain reachable.

The terminal divides chat-window space using `NotebookTerminalSplit`; its saved
fraction survives temporary keyboard constraints. Files remain in the conversation's
collapsible side panel. These presentations never publish a board-camera change.

Account access is provided by the current chat/account surfaces; devices and
workspace history belong to the workspace library. The retired shared
“Chat actions” menu is not an additional owner.

`NotebookChatWindowTests` checks layout, bounds, saved preference, corner resizing,
and temporary constraints. Gesture scenarios cover moving, resizing, keyboard,
rotation, collapse, and cold restoration. See [verification](verification.md)
for the exact tested slice and physical acceptance limits.

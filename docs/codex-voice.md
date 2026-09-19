# Voice through Codex authentication

## One conversation owner

`NotebookVoiceController` belongs to `NotebookChatController`. Its media surface
is mounted at the window root, independent of expanded chat and board visibility.
Collapse does not end a call or move the camera. Controls show the pinned task,
state, microphone, playback and end action. Changing task/computer requires ending
the call first; ongoing speech is never silently redirected.

`MacNotebookVoice` uses the existing durable chat-input journal and single
`CodexAppServer`. It checks ChatGPT auth, resumes the selected task and calls
`thread/realtime/start` v3 with WebRTC. Call UUID, task and initiating device are
fixed. Another device cannot read SDP or stop it. Repeated receipt reads do not
restart calls; uncertain attempts remain uncertain.

## Explicit call and local wake address

Tapping the wave starts voice in the selected task after microphone admission.
It does not require Speech permission, a wake word or a menu. Holding it opens
language and the separate wake-for-call action without also triggering a tap;
VoiceOver has the equivalent action. Dictation and voice share microphone ownership.
The separate microphone button records an editable draft.

With a selected task and connection, foreground Notebook can automatically wait
for a dictation wake address. The microphone's context action explicitly disables
all local capture until re-enabled. Language, custom address and mute persist.
Collapsing chat releases text focus before moving controls so a departing keyboard
does not intercept the next voice tap.

`NotebookWakeAddress` owns recognition hints and matching. Supported Russian and
English forms include the localized “Listen/Hey, GPT” and bare “GPT”; Russian
recognition also accepts its documented phonetic spellings of Hey. Other languages
retain bare GPT unless configured. Exact recognized strings belong to source/tests,
not an independently maintained second list in this document.

Apple Speech is used **only for local wake recognition**, not draft transcription.
Both `supportsOnDeviceRecognition` and `requiresOnDeviceRecognition` are mandatory.
Missing permission, local model or supported locale prevents capture with an explicit
reason; there is no server-recognition fallback. Failure remains visible after
collapse until retry or dismissal.

System Speech callbacks do not inherit MainActor. Permission callbacks resume a
continuation; recognition copies text/timing/error into sendable values for its
actor. PCM processing and recognition do not wait for the UI actor.

`NotebookAcousticUtterance` identifies speech boundaries from continuous microphone
frames. A 200 ms pre-roll retains initial consonants, background estimation holds
30 samples and an 800 ms pause closes the local Speech request. Long unaddressed
speech is not periodically restarted with repeated tails. Wake classification
uses the utterance's original audio position, including when partial Speech results
have zero word timestamps. Recognized local words do not become the actual request;
Codex transcribes the audio. Noisy-room behavior still needs physical checking.

For wake-to-call, one WebKit capture feeds `voice-worklet.js`. Before wake there is
no WebRTC peer; up to 12 seconds of PCM remains local in memory. After wake, earlier
samples are dropped and the original address plus request is sent through the same
audio track once connected, never duplicated as text. Missing buffered start or
connection failure stops capture with an explanation, not partial automatic replay.
Delayed connection retains at most 40 seconds. Quiet speech is not discarded by a
guessed catch-up shortcut; delay and interruption must be evaluated together.

## Call termination and playback

During a call local wake listening is disabled so the agent cannot trigger itself.
WebRTC uses echo cancellation and Codex interruption. Mute stops the original
MediaStreamTrack and clears unsent local audio; unmute creates a new capture in
the same peer. Playback mute affects only the received stream.

End first stops local capture/WebRTC, then sends durable stop to Mac. Background,
disconnect and media-surface removal also stop capture and release WebKit.
Locked/background iPad calling is not supported. Native shutdown does not wait for
JavaScript: it disables WebKit microphone access and destroys the media page.
Until Mac confirms, UI distinguishes microphone off from call ended and retains
the call UUID. Unknown stop is reconciled by reads, not a second stop/call.
`flushTranscriptTailOnSessionEnd` is disabled so final service transcript does not
become another task.

## Companion and questions

`NotebookCompanion` is a compact view of the same conversation. Its writing button
opens the sole full composer; there is no second compact draft editor. It shows
actual work, useful replies and required questions. Dictation reuses its shell and
anchor with cancel, measured waveform, edit-stop and send.

At most two reply bubbles of six native-text lines are visible. Tapping opens the
same native message; close removes that bubble immediately. Automatic dismissal
uses 12–25 seconds based on length. Hidden replies remain in history/unread state
and never reappear when a later bubble closes. Required questions do not time out.

`NotebookChatReadPosition` persists reading IDs and display deadlines per computer/
task. View recreation, resizing, repeated events and restart do not reset them.
The existing chat controller keeps subscription and fills reconnect gaps while
collapsed. Companion dragging uses the writing control, not message text. Pencil
outside it stays with paper; layout never changes SessionPresence camera.
Reduce Motion makes the visual accent static without owning audio lifecycle.

## Dictation capture and delivery

`NotebookDictationController` retains recording across chat collapse. Manual tap
starts dictation without automatic sending. The draft stays mounted but input is
temporarily disabled; existing text/attachments survive. UI level history is capped
at 240 measured samples, with silence shown as dots. Stop opens chat and focuses
the recognized draft. Send fixes attention, camera, file and attachments before
awaiting transcription, then uses ordinary `sendChatMessage` after saving text.
Repeated taps cannot replace that decision or create another message.

Failure, cancellation or restart clears immediate-send intent. An explicit retry
opens the result for review; failed message persistence also leaves the draft.
`NotebookMicrophoneDictationCapture` owns system capture and
`NotebookDictationAudioStorage` owns ordered PCM analysis/AAC writing off the UI.
Completion is a distinct UUID/position/rate event, not inferred from a zero UI meter.
Background or audio interruption ends capture into draft review.

Limits: five minutes, mono AAC at the system input's 8–96 kHz, 64 kbit/s, 8 MiB.
Until insertion or cancellation, private `runtime/dictation/<author>` retains audio
and metadata on iPad; it is not replicated content.

Authenticated chat requests transfer at most 96 KiB per chunk. Mac validates device,
computer, length, order and SHA-256. Duplicate chunks/final receipts never repeat
transcription. One unfinished recording per device and four total are retained;
unused results expire after 15 minutes at the next request. Service failure preserves
audio for explicit retry. Cancellation stops capture immediately and durably records
its tombstone before deleting audio, blocking late text and restart resurrection.

`CodexAppServer.transcribeDictation` obtains current auth via
`getAuthStatus(includeToken: true)` and uploads only the recording to
`https://chatgpt.com/backend-api/transcribe`. This is an adapter to the observed
Codex client interface, not a stable public API promise. Tokens stay in Mac memory,
never iPad/files/logs; HTTP stores no cookies/cache, rejects redirects and bounds
errors. Only 401 permits one auth refresh, and account change prevents automatic
resubmission under a different identity. Contract change must fail explicitly
while preserving the recording.

The result is saved beside audio, then `insertChatDictation` atomically inserts text
and receipt UUID into the originating task's draft. Recovery cannot insert twice or
let an old panel save replace it. Task/computer/send/call changes wait for completion
or cancellation. A 32 KiB draft limit fails rather than silently truncating text.
Manual stop/transcription alone does not create a task.

## Wake-triggered dictation

One AVAudioEngine feeds a ten-second in-memory PCM pre-roll before wake, with no
file or upload. The same stream begins AAC at the identified utterance frame;
there is no second-microphone startup gap. The off-main queue admits 32 chunks,
normalizes interleaved/multichannel input to mono and reports two seconds without
frames as an input error. Missing frames/overflow stop rather than join unrelated
phrases.

Acoustic analysis continues without resetting background estimates. Different
start/continuation thresholds preserve quiet speech; UI RMS/peak levels never decide
completion. A request ends after 1.4 seconds of source-audio silence, including
silence already observed before wake recognition. Bare wake waits for the request;
after twelve empty seconds listening resumes without uploading an empty recording.
Only the address prefix is removed from returned transcription.

A complete request enters the ordinary send queue using recording UUID as message
UUID. Attention is fixed at wake; existing typed draft/attachments are preserved and
not appended. Normal completion stays collapsed and uses the existing companion.
Recovery checks that same queue entry. If sending was not durably accepted, explicit
retry opens review rather than restoring lost automatic-send context.

After completion/cancel/stop, foreground listening resumes only after rechecking task,
connection and voice ownership. `notebook.microphone-muted` always overrides it.
Pending recovery remains in review. One private `audio-diagnostics.json` records UUID,
rates/positions, RMS/peaks, background estimate, silence, processing delay and at most
240 samples—no text or audio. It is not replicated or sent to the model.

## Verification boundary

Synthetic PCM through real analysis/AAC and a live authenticated transcription probe
prove those routes, not a physical iPad microphone. A real WebKit probe retained a
complete synthetic utterance through delayed connection and obtained a voice answer;
it did not prove human audibility or noisy-room wake accuracy.

`NotebookVoiceControllerTests` uses the real AudioWorklet in a noninteractive 1×1
surface without a human microphone. Dedicated Simulator tests revoke microphone
access for the actual isolated test bundle before synthetic capture and verify that
precondition. Never apply privacy changes to a production bundle by copying an old
command. Tests cover continuity, pre-wake absence of a peer, mute/resume/dispose,
false wake, buffers, drafts and reading state. Full live voice with hardware Pencil
remains separate acceptance, including GUI-196/GUI-272 status in
[verification](verification.md).

References: [App Server](https://learn.chatgpt.com/docs/app-server),
[on-device availability](https://developer.apple.com/documentation/speech/sfspeechrecognizer/supportsondevicerecognition),
[on-device requirement](https://developer.apple.com/documentation/speech/sfspeechrecognitionrequest/requiresondevicerecognition).

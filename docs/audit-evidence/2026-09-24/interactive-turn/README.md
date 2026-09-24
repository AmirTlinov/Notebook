# Interactive page-turn ownership, September 24

Physical iPad Pro 11 (3rd generation), iOS 27 `24A435`, optimized native tests.
The test invokes the real `panned:` action with scripted recognizer values;
Metal presents actual images and UIKit captures intermediate pixels. This is not
hardware touch arbitration, screen scanout video, a system FPS trace, or acceptance
of the user's notebook. Production pair 195 failed Amir's physical acceptance.

| Receipt under `.build/` | Input SHA-256 | Result |
| --- | --- | --- |
| `gui295-interactive-reverse-baseline-v2` | `389853c885dd04d8d6de78c92852d56efd34f925e08a78f6bfe9f27df812d961` | 1 FAIL: shown endpoint did not commit after lift |
| `gui295-interactive-endpoint-fix` | `509ed53e9e6893a930d8ed185e2ebe578d48ef9d40d6cf58c4fad348a20de935` | 27 PASS, 1 FAIL: fulfilled command replays after reverse |
| `gui295-interactive-reverse-owner-fix` | `f54bcdb71dc4562dd473ace33411a4eaf80b96fa69d504662215f8f0f70c3fc6` | 28 PASS: endpoint + command consumption |
| `gui295-interactive-boundaries-and-latency` | See original `source-before.json` | 2 PASS, 1 FAIL: functional boundaries pass, strict timing fails |

The summaries, raw per-frame samples, and representative frame 32 are retained
here. Red is the requested reverse destination 0; blue is the source 1.
With only the endpoint fix, frames 24–28 are red/selected=0, frames 31–36 are
blue/selected=0, and from frame 37 the unrequested forward turn commits 1.
With both fixes the red leaf stays selected and visible after lift.

The first `gui295-interactive-reverse-baseline` attempt (without `-v2`) was an
invalid fixture: setting translation on an idle system recognizer did not drive
its action. It is not counted as an application failure. The fixture was replaced
by a recognizer overriding state/translation/velocity; the delegate now reads its
passed recognizer rather than a separate stored instance.

The expanded boundary test covers forward/reverse × complete/cancel × endpoint
presentation before/after lift. It also checks admission of the next gesture,
retirement of the display clock and exactly-once completion. The reverse pixel
test repeats three times, once releasing before the end of travel. Strict timing
remains a failing separate lane: 39.473–54.482 ms first response, 322.752–329.278 ms
landing, dropped/invalid receipts and missed 120 Hz intervals. It has not been
weakened. Raw submission/OS-presentation timing is included, not summarized as FPS.

Final affected-scenario verification: `.build/gui295-interactive-turn-final`, **43 iPad PASS**,
no failures, skips or runtime warnings; immutable input `46aef8fc92d9e513d10264a9e63e363443c14ac12d6135a0b6359897a4cff07c`.
Includes the full mounted SVG scene with interactive reversals, cold reference
and camera settlement, readiness during the held contact, cancellation, eviction,
peer order changes, trailing-page creation and drawing into the new leaf.
The separate strict latency failure above remains open.

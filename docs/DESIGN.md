# Control protocol

This implementation recreates the documented Windows desktop workflow, rather than the proprietary Codex runtime. It uses the same Windows primitives through an MIT-derived backend and a new DSH-native controller.

| Documented workflow | DSH implementation |
| --- | --- |
| Select returned app/window | Catalog app id and opaque window binding |
| Bind window identity | HWND, owning PID and process start time |
| Capture screenshot/accessibility | Snapshot token, bounded image, local element indexes, focused editable and document text |
| Act from current state | Required unconsumed observation token; coordinates in returned image pixels |
| Refresh after one action | Updated screenshot/UIA returned by every input |
| Recover uncertain effects | `outcome_unknown`, invalidate old observations, reobserve before any retry |
| Permission and cancellation | DSH approvals, explicit allowed apps, stop/resume settings, signal propagation |

## Execution

All calls share one controller queue. Each agent sees its own window ids and observations. An input increments the shared desktop epoch, invalidating every earlier observation. A window remains bound across title changes but not across PID/HWND/start-time identity changes.

The backend validates ownership immediately before operating. Element lookup stays under the bound window rather than falling back to desktop-wide RuntimeId search. Foreground coordinate input also checks that the hit-tested point belongs to the target window. Typing compares current editable focus/content with the prior observation before pasting. Set-value refuses non-editable/password controls and changed prior values.

The controller transforms screenshot pixels using capture origin and downscale ratio; moving the window adjusts the origin, while resizing requires a fresh capture. Backend legacy homing is disabled to prevent applying the correction twice. Captures flagged as possibly occluded cannot be used for coordinates.

Text insertion into an initially empty readable control and whole-value replacement poll for the exact expected result without resending input. Insertion into existing text is `dispatched` and must be inspected, since caret/selection position cannot be assumed. A timeout or failed refresh after dispatch reports unknown effects.

Cancellation terminates the owned STA worker. Interrupted input releases potentially held modifier/mouse state through a separate release-only helper; subsequent calls wait for cleanup. Failed cleanup blocks further backend calls until reload. Normal drag cleanup releases the mouse in `finally`. Stop also rejects already queued work, even if resume happens immediately.

Screenshots stay out of canonical JSON. The host verifies image capability, saves images in DSH attachments, and projects durable image references only if the canonical result has not been replaced or blocked by the tool pipeline. A text-only route receives explicit image-delivery diagnostics and loses coordinate capability for that observation.

## Boundaries

No browser protocol, extension, DOM or browser input is included. Known browser, terminal, credential, password-manager, security and locked-desktop surfaces are denied. Normal desktop apps are available by default. Optional selected-app mode uses session-scoped app approval unless the user saves an executable name in settings. Consequential actions require DSH action-time confirmation.

The plugin cannot infer every business consequence from a generic pixel click, and the model must classify consequential actions according to the injected skill. This is not an OS sandbox. App-catalog coverage and model visual reasoning differ from Codex; equivalent success rates require separate empirical evaluation.

References: [OpenAI computer use overview](https://learn.chatgpt.com/docs/computer-use), [computer-use execution loop](https://developers.openai.com/api/docs/guides/tools-computer-use). Native source provenance and redistribution permission are recorded in NOTICE and native/LICENSE.

## Desktop activity UI

A separate STA helper displays non-activating, mouse-transparent monitor edges, a status banner, and an agent cursor indicator. It is per-monitor DPI aware. The input backend emits cursor/activity events separately from request replies; these events never settle or corrupt an action response. It does not create an independent virtual input desktop.

The owner is the active observing agent. Turn completion/idle, manual stop, settings changes, and plugin disposal hide the UI; an idle expiry and parent-process check prevent abandoned indicators. Startup cancellation invalidates pending show calls, so a stopped task cannot display a delayed banner.

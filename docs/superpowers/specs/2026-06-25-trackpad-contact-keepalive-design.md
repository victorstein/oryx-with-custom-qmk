# Trackpad: keep the mouse layer alive while a finger rests (contact keep-alive) — design

**Date:** 2026-06-25
**Keyboard:** ZSA Voyager (`JRZ6Q`), Oryx + custom-QMK hybrid, Navigator trackpad.
**Host:** macOS. Build: GitHub Actions → Docker → QMK.
**Builds on:** `2026-06-19-mouse-layer-instant-off-on-typing-design.md` and the
`AUTOMOUSE_TIMEOUT` = 650ms bump. Both stay in force; this only changes what *keeps*
the auto-mouse layer warm, not what drops it.

## Problem

The auto-mouse layer (`AUTOMOUSE_LAYER = 5`) is kept warm by **motion**: the `automouse`
module refreshes its `last_activity` timer only when accumulated trackpad delta crosses
`AUTOMOUSE_THRESHOLD`, or while keys are held on the layer. A finger resting on the
trackpad **without moving** emits `dx = dy = 0`, which never refreshes the timer — so a
motionless-but-present finger is indistinguishable from "no finger," and the layer times
out after 650ms even though the finger never lifted.

The user wants: **while a finger is in contact with the trackpad (moving *or* still), the
mouse layer stays alive.** The 650ms timeout should begin only once the finger *lifts*.

## Why this needs a firmware-module patch (not a keymap change)

The trackpad and auto-mouse are two **QMK community modules**, declared in
`JRZ6Q/keymap.json` (`"modules": ["zsa/oryx", "zsa/navigator_trackpad", "zsa/automouse",
"zsa/defaults"]`). They are **not** in this repo. They live in `zsa/qmk_modules`, pinned
via a nested git submodule `modules/zsa` inside `zsa/qmk_firmware`, and materialize at
`qmk_firmware/modules/zsa/<name>/` only during the CI build.

Relevant facts established from `zsa/qmk_modules` (`main`, e.g. SHA `2e0fc66`):

- The contact bit **already exists and is read every frame** in the trackpad module:
  `navigator_trackpad/navigator_trackpad_ptp.c` computes `finger0_present =
  sensor_report.fingers[0].tip` and a live contact count (`cur_n`).
- The trackpad feeds auto-mouse via `automouse_report_motion(dx, dy, buttons)` — **deltas
  only**. The contact bit is never forwarded.
- `automouse/automouse.c` refreshes `last_activity` only on (a) motion crossing the
  threshold, (b) `held_keys > 0`, or (c) a keypress while active. **Never on contact.**
- The contact bit is a function-local in the trackpad module and is **not exposed** to the
  keymap. The trackpad runs as a HID digitizer (`DIGITIZER_MODE = touchpad`), so the
  keymap gets no `report_mouse_t` delta hook to infer contact from either.

Therefore the fix cannot live in `keymap.c`. It requires a small change in **both**
modules: the trackpad must forward "finger present," and automouse must treat that as
activity. Patching only one is insufficient (trackpad alone → automouse ignores it;
automouse alone → it never receives a contact signal).

## Decision — behavior

**Alive while touching.** Keep `AUTOMOUSE_LAYER` active as long as a finger is in contact
(moving or still). Activation is **unchanged** — still motion-to-activate (the user
explicitly did *not* want touch-to-activate). Once active, contact keeps the layer warm.
On lift, the existing 650ms timeout runs and the layer drops. Typing a non-click key still
drops the layer instantly (existing `keymap.c` guard, untouched).

| Event | Result |
|---|---|
| Finger moves (crosses threshold) | layer activates (unchanged) |
| Finger present, moving or **still**, layer already active | `last_activity` refreshed → layer stays alive |
| Finger present but layer **not** active (e.g. just resting, no prior motion) | nothing — no activation (motion-to-activate preserved) |
| Finger lifts | `last_activity` stops refreshing → 650ms → layer drops |
| Non-click key typed while warm | layer drops instantly (existing keymap guard) |

## Decision — code shape

Two additive module patches, mirroring the existing `held_keys` keep-alive pattern so the
interaction with the keymap's instant-drop is automatically safe (see Recovery).

### Patch A — `automouse` module (`automouse/automouse.c`, `automouse.h`)

Add a module-level contact flag and a tiny public entry point, then fold the flag into the
existing keep-alive condition exactly like `held_keys`:

```c
// automouse.h — public surface
void automouse_report_contact(bool finger_present);

// automouse.c
static bool finger_present = false;

void automouse_report_contact(bool present) {
    finger_present = present;
}

// inside the existing timeout/keep-alive block (currently ~automouse.c:135):
//   was:  if (state.is_active && state.held_keys > 0)
//   now:  if (state.is_active && (state.held_keys > 0 || finger_present))
//             state.last_activity = timer_read();
```

Critically, this refreshes `last_activity` **only while `state.is_active`** and **never
calls `layer_on`** — identical to the `held_keys` branch. Contact can keep the layer warm
but can never re-assert a layer the keymap has dropped.

### Patch B — `navigator_trackpad` module (`navigator_trackpad/navigator_trackpad_ptp.c`)

At the existing contact site (where `cur_n` / `finger0_present` is already computed,
~line 476, the same block that calls `automouse_report_motion`), add one line so it runs
every frame for both the "finger(s) present" and "all lifted" states — placed once after
`cur_n` is known, covering the `if (cur_n > 0) … else …` either way:

```c
automouse_report_contact(cur_n > 0);
```

### `keymap.c`

**No changes.** The instant-drop-on-typing guard and `layer_state_set_user` yield are
untouched and still take precedence.

## Recovery / interaction with the existing instant-drop (resolved, not open)

The prior spec (`2026-06-19…`, "Recovery") established that the automouse keep-alive branch
"updates `last_activity` but never calls `layer_on`," and that the layer is re-asserted
**only** by new motion crossing the threshold. Our contact keep-alive mirrors that branch
exactly, so the potentially-worrying edge case is benign:

- User mouses → layer active → types a non-click key → keymap `layer_off`s the layer.
- Finger keeps resting. Our contact keep-alive refreshes `last_activity` (module
  `is_active` stays `true`), but because it **never** calls `layer_on`, the layer **stays
  off**. It comes back only on the next motion (`automouse_activate` → `layer_on`) — the
  same recovery rule the keymap already relies on.
- Finger lifts → `last_activity` stops refreshing → module timeout → `automouse_deactivate`
  (a no-op `layer_off`). Counters balanced.

So contact only ever *extends the warm window while the layer is genuinely active*; it
cannot fight or undo the keymap's typing-drop.

## Delivery — patch files applied in CI (float on latest)

The module source is fetched fresh on every build (`git submodule update --init --remote`
pulls `qmk_modules` latest), so the change cannot be committed as module files. It lives in
this repo as patch files plus one CI step that applies them into the fetched tree.

```
patches/
  automouse-contact.patch            # Patch A
  navigator-trackpad-contact.patch   # Patch B
```

- Each patch header records the `qmk_modules` SHA it was authored against.
- A new step in `.github/workflows/fetch-and-build-layout.yml`, **after** the submodule
  checkout and **before** `make`, applies both patches to
  `qmk_firmware/modules/zsa/{automouse,navigator_trackpad}/`.
- **Loud failure:** if `git apply` fails (ZSA moved the surrounding code), the step exits
  non-zero with a message naming the failing patch and the upstream file to re-diff
  against. Red build, no artifact — never a silent stale-code ship.
- **Idempotency guard:** the step first greps the upstream source for a sentinel
  (`automouse_report_contact`). If present, ZSA has shipped native contact support — the
  step **skips** the patch with a notice instead of failing or double-applying.
- Patches are kept **additive** (new function appended at end-of-file; single-line
  call-site insert with distinctive context) to minimize how often upstream edits collide.

**Rationale (float, not pin):** the user chose to keep auto-syncing ZSA's latest modules
and accept occasional red builds, fixed by refreshing the patch context (~5 min). Failures
are safe (red build, clear error) and caught proactively by the nightly canary below,
*before* a build is actually needed.

## Proactive monitoring — nightly canary

A **separate, scheduled, read-only** GitHub Actions workflow
(`.github/workflows/patch-canary.yml`) that detects patch breakage on a schedule rather
than at the moment a real build is needed.

- **Schedule:** daily, early morning (`on: schedule: cron`, UTC — one line, user-tweakable).
- **Read-only:** checks out, updates `modules/zsa` to ZSA latest, applies the two patches,
  and attempts the build. It does **not** run the Oryx fetch/merge/commit/push steps — it
  never mutates the repo. The real signal is the `git apply` step; the compile is bonus
  confidence.
- **Failure → notification (both native, zero-secret):**
  - **GitHub issue:** on failure, open or **update a single** tracked issue
    (deduped — title acts as the key) with the failing-run link and the upstream file to
    re-diff. Uses the built-in `GITHUB_TOKEN`; no external secrets.
  - **GitHub email:** GitHub's automatic scheduled-workflow-failure email to the repo owner
    (on by default; no setup).
- **Upstream-shipped-native case:** if the idempotency sentinel trips, the canary reports
  "upstream may have added contact support natively — patch skipped" (a notice, not a
  failure), so we know to retire the patch.
- Dedupe avoids daily inbox spam: while broken, the canary updates the same issue each
  morning until the patch is refreshed and the build goes green.

## Behavior after change

- Mouse, then rest a finger on the pad without moving → layer stays warm indefinitely;
  `W`/`E`/`R` remain clicks. Previously it dropped after 650ms.
- Lift the finger → 650ms later the layer drops (unchanged timeout).
- Type a non-click key while warm → layer drops instantly (unchanged keymap guard), even
  with a finger still resting (contact never re-asserts a dropped layer).
- Move again after any drop → layer re-activates on threshold (unchanged).

## Notes / risks / out of scope

- **Float risk (accepted):** `git apply` breaks whenever ZSA edits the code around our two
  touchpoints — files they are actively iterating on. Expect periodic red builds in the
  near term. Mitigated by additive patches, loud failure, and the nightly canary. Not
  silent: always a red build with a clear error.
- **Multi-finger:** `cur_n > 0` treats any contact as "present," which is the intended
  semantics (a resting finger of any index keeps the layer warm). Two-finger scroll while
  resting is therefore also covered.
- **No config / LED / layout changes.** `keymap.c`, `config.h`, `ledmap` untouched.
- **Merge safety:** all changes live in this repo's `patches/` and `.github/workflows/`,
  outside the Oryx-merged keymap files — no interaction with `git merge -Xignore-all-space
  oryx`.
- **Verification:** cannot compile locally; verified by static review, the patch applying
  cleanly against the recorded `qmk_modules` SHA, and the GitHub Action Docker build
  producing an artifact. Functional check (resting finger keeps layer warm) is on-device
  after flashing.
- **Pin option deferred:** if periodic refreshes become annoying, pinning `modules/zsa` to
  a tested SHA eliminates surprise breakage at the cost of manual update cadence. Out of
  scope here; the canary makes float tolerable.
```

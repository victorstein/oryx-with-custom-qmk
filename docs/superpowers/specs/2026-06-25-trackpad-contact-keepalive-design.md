# Trackpad: keep the mouse layer alive while a finger rests (contact keep-alive) — design

**Date:** 2026-06-25
**Revision:** v2 — incorporates two-reviewer findings (firmware logic + CI/blast-radius).
Material changes from v1: self-decaying contact signal (not a pure latch), `is_active`↔layer
reconcile, corrected build-resolution model (modules are firmware-pinned, *not* floating
main), and `patch`-based in-container apply with geometry/firmware guards.
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

- The trackpad module `navigator_trackpad/navigator_trackpad_ptp.c` reads a live contact
  count `cur_n` each frame and feeds auto-mouse via `automouse_report_motion(dx, dy,
  buttons)` — **deltas only**, gated on a matching contact id. (Note: the separate
  `finger0_present = sensor_report.fingers[0].tip` at ~`:431` feeds the mouse-mode fallback
  tap detector, *not* the PTP automouse path — the patch keys off `cur_n`.)
- `automouse/automouse.c` keep-alive (`:136-138`) refreshes `last_activity` only on (a)
  motion crossing the threshold, (b) `held_keys > 0`, or (c) a keypress while active.
  **Never on contact.** `AUTOMOUSE_ONESHOT` is **not** defined in this build (`config.h`
  has only `AUTOMOUSE_LAYER 5`, `AUTOMOUSE_TIMEOUT 650`, `AUTOMOUSE_THRESHOLD 10`), so the
  patch lands on the active non-oneshot path.
- The trackpad runs as a HID digitizer (`DIGITIZER_MODE = touchpad`), so the keymap gets no
  `report_mouse_t` delta hook to infer contact from either.

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

Two additive module patches. The contact signal is a **self-decaying timestamp**, not a
pure latch, and automouse **reconciles `is_active` against the real layer state** — these
two properties close the failure modes found in review (see Pitfalls).

### Patch A — `automouse` module (`automouse/automouse.c`, `automouse.h`)

```c
// automouse.h — public surface
void automouse_report_contact(bool finger_present);

// automouse.c
#define AUTOMOUSE_CONTACT_STALE_MS 120   // > trackpad poll interval; tune in plan

static bool     finger_present = false;
static uint16_t last_contact   = 0;

void automouse_report_contact(bool present) {
    finger_present = present;            // mirror is_enabled guard if upstream uses one
    if (present) last_contact = timer_read();
}

// inside the existing timeout/keep-alive block (automouse.c:136-138):
//   was:  if (state.is_active && state.held_keys > 0)
//   now:  if (state.is_active && (state.held_keys > 0 ||
//             (finger_present && timer_elapsed(last_contact) < AUTOMOUSE_CONTACT_STALE_MS)))
//             state.last_activity = timer_read();

// is_active ↔ layer reconcile (fixes typed-off resurrection): before the keep-alive,
// if the layer was dropped externally (e.g. the keymap typing-guard), sync down so the
// motion accumulators get reset and a resting finger can't re-cross threshold:
//   if (state.is_active && !layer_state_is(AUTOMOUSE_LAYER)) automouse_deactivate();
```

Two load-bearing properties:
1. **Self-decaying:** keep-alive counts contact only while `timer_elapsed(last_contact) <
   AUTOMOUSE_CONTACT_STALE_MS`. If the trackpad task stops reporting for *any* reason
   (bus error, disconnect) the signal goes stale on its own and the 650ms timeout proceeds
   — no stuck-on layer.
2. **Never re-asserts a dropped layer:** keep-alive only refreshes `last_activity` (never
   `layer_on`), and the reconcile actively deactivates when the layer is externally off, so
   accumulated jitter cannot resurrect the layer the keymap just dropped.

### Patch B — `navigator_trackpad` module (`navigator_trackpad/navigator_trackpad_ptp.c`)

At the existing contact site (where `cur_n` is computed, ~line 476, the block that calls
`automouse_report_motion`), add one line so it runs every frame for both the
"finger(s) present" and "all lifted" states — placed once after `cur_n` is known:

```c
automouse_report_contact(cur_n > 0);
```

Note the call site sits *after* several early `return false` paths (poll throttle,
`!trackpad_init` disconnect, read-failure). That is exactly why the automouse-side staleness
timeout (property 1 above) is required: those exits mean the call may not fire on a lift
that coincides with a bus error.

### `keymap.c`

**No changes.** The instant-drop-on-typing guard and `layer_state_set_user` yield are
untouched and still take precedence.

## Recovery / interaction with the existing instant-drop

The prior spec (`2026-06-19…`, "Recovery") established that the layer is re-asserted **only**
by new motion crossing the threshold. With the reconcile added here, the typed-off path is
now provably clean:

- User mouses → layer active → types a non-click key → keymap `layer_off`s the layer.
- Next automouse task tick observes `is_active && !layer_state_is(AUTOMOUSE_LAYER)` →
  `automouse_deactivate()` → `is_active = false`, motion accumulators zeroed.
- Finger keeps resting: `finger_present` is true but keep-alive is gated on `is_active`
  (now false) → no-op. Critically, with accumulators reset, residual sensor jitter can no
  longer creep across `AUTOMOUSE_THRESHOLD` to call `layer_on`. The layer **stays off**
  until a real new motion gesture — the same recovery rule the keymap relies on.
- Finger lifts → contact goes stale/false → module timeout → `automouse_deactivate` (no-op).

So contact only ever extends the warm window while the layer is genuinely active, and can
neither fight nor undo the keymap's typing-drop.

## Build-resolution model (corrected from v1)

**The modules are effectively pinned by firmware version, not floating on `qmk_modules`
main.** The workflow's `--remote` (`fetch-and-build-layout.yml:83`) acts on the *outer*
`qmk_firmware` submodule and is then overridden by `git checkout -B firmware${VERSION}
origin/firmware${VERSION}` (`:85`). `modules/zsa` is checked out by `git submodule update
--init --recursive` (`:86`, **no `--remote`**), so it lands at the SHA **pinned by the
`firmwareXX` branch**.

Consequences:
- Module source drifts **only** when (a) Oryx bumps `qmkVersion` → a new `firmwareXX`
  branch, or (b) ZSA re-pins `modules/zsa` within `firmwareXX`. So patch breakage is
  **infrequent**, clustered around firmware-version bumps — not a steady stream.
- The canary must reproduce this **exact** resolution (the `firmwareXX` pin), or it tests a
  different SHA than the real build and yields false positives/negatives.

## Delivery — patch files applied in CI

The module source is fetched during CI (not committed in this repo), so the change lives as
patch files plus one CI step that applies them into the fetched tree.

```
patches/
  automouse-contact.patch            # Patch A
  navigator-trackpad-contact.patch   # Patch B
```

- Each patch header records the `qmk_modules` SHA it was authored against.
- **Apply mechanism — `patch -p1`, in-container, after `qmk setup`, before `make`.**
  The build runs `docker run -v ./qmk_firmware:/root … "qmk setup … ; make …"`
  (`fetch-and-build-layout.yml:112-115`). The mounted tree's `.git` is a dangling gitfile
  (superproject `.git` is not mounted), so **`git apply` cannot run in-container** — use
  `patch -p1`, which needs no git repo. Patches are copied into the mounted tree first
  (host: `cp -r patches qmk_firmware/_patches`), then applied inside the heredoc **after
  `qmk setup`/`doctor`** (which would otherwise re-sync and could clobber a host-applied
  patch) and **before `make`**. `_patches` lives only in the throwaway build tree and is
  never committed.
- **Guard (blast-radius containment):** the apply runs **only** when
  `layout_id == JRZ6Q` **and** `firmware_version >= 24` **and** both
  `qmk_firmware/modules/zsa/automouse` and `…/navigator_trackpad` exist. Otherwise it
  **skips with a notice** (never fails) — so other geometries (moonlander/ergodox/planck),
  other layout IDs, and legacy firmware <24 that don't use these modules build untouched.
- **Loud failure:** if `patch` fails to apply (upstream moved the surrounding code), the
  step exits non-zero naming the failing patch and the upstream file to re-diff against.
  Red build, no artifact — never a silent stale-code ship.
- **Idempotency guard:** before applying, grep the upstream source for the sentinel
  `automouse_report_contact`. If present, ZSA shipped native contact support → **skip** with
  a notice instead of failing or double-applying.
- Patches kept **additive** (new function appended at end-of-file; single-line call-site
  insert with distinctive context) to minimize collision with upstream edits.
- **Placement:** the apply step goes after the workflow's last `push` (`:90`). Nothing
  commits the patched tree — `git add qmk_firmware` stages only the submodule gitlink SHA,
  never working-tree file content — so patched modules can never leak into the repo.

## Proactive monitoring — nightly canary

A **separate, scheduled, read-only** workflow (`.github/workflows/patch-canary.yml`) that
detects patch breakage on a schedule rather than at the moment a real build is needed. Given
the corrected build model, it will be **mostly idle**, firing meaningfully around
firmware-version bumps or ZSA re-pins — cheap insurance, not a daily fire alarm.

- **Schedule:** daily, early morning (`on: schedule: cron`, UTC — one line, user-tweakable).
  `schedule:` triggers run only on the **default branch's** copy, so the workflow and
  `patches/` must live on `main` (they will).
- **Resolves modules exactly as the build does:** `submodule update --init` qmk_firmware →
  `checkout firmware${VERSION}` → `submodule update --init --recursive` (**no `--remote`**),
  then `patch -p1`. Uses the committed `JRZ6Q/` layout to `make` (bonus compile).
- **Permissions:** `contents: read`, `issues: write`. No push, no Oryx fetch/merge/commit —
  truly read-only.
- **Failure → notification (both native, zero-secret):**
  - **GitHub issue:** open or **update a single deduped** issue (`gh issue list --search
    'in:title "<fixed title>"' --state open` → create-or-comment) with the failing-run link
    and the upstream file to re-diff. The body **states which step failed (apply vs
    compile)** so unrelated toolchain/upstream build breakage isn't misattributed to "patch
    broke." Uses built-in `GITHUB_TOKEN`.
  - **GitHub email:** GitHub's automatic scheduled-workflow-failure email to the repo owner.
- **Upstream-shipped-native case:** if the sentinel trips, report "upstream may have added
  contact support natively — patch skipped" as a **notice, not a failure**, so we know to
  retire the patch.

## Behavior after change

- Mouse, then rest a finger without moving → layer stays warm indefinitely; `W`/`E`/`R`
  remain clicks. Previously dropped after 650ms.
- Lift the finger → 650ms later the layer drops (unchanged timeout).
- Type a non-click key while warm → layer drops instantly (unchanged keymap guard), even
  with a finger still resting (reconcile + reset prevents resurrection).
- Move again after any drop → layer re-activates on threshold (unchanged).
- Bus error / disconnect while resting → contact goes stale within ~120ms → layer follows
  the normal 650ms timeout rather than sticking on.

## Pitfalls found in review (and how this design closes them)

- **[MAJOR] Stuck-on via bus error.** The trackpad contact call sits after early
  `return false` paths; a glitch while a finger rests could leave a pure latch stuck true →
  layer warm forever. **Closed by** the self-decaying timestamp (`AUTOMOUSE_CONTACT_STALE_MS`).
- **[MAJOR] Jitter resurrects a typed-off layer.** Keeping `is_active` true forever stops
  `automouse_deactivate` from resetting the motion accumulators, so resting-finger jitter
  could re-cross threshold and `layer_on` a layer the keymap just dropped. **Closed by** the
  `is_active`↔layer reconcile that deactivates (and resets accumulators) when the layer is
  externally off.
- **[MAJOR] In-container `git apply` fails / setup clobber / patch visibility.** **Closed by**
  `patch -p1` on patches copied into the mounted tree, applied after `qmk setup`, before
  `make`.
- **[MAJOR] Unconditional apply breaks unrelated builds.** **Closed by** the
  layout+firmware+dir-existence guard with skip-with-notice.
- **[MAJOR] Canary tests the wrong SHA.** **Closed by** reproducing the `firmwareXX`-pinned
  resolution rather than `--remote`/main.

## Notes / risks / out of scope

- **Breakage cadence (corrected):** infrequent — only on firmware-version bumps or ZSA
  re-pins, not steady main churn. Caught by the canary before a real build is needed; fixed
  by refreshing patch context (~5 min). Always a red build with a clear error, never silent.
- **Multi-finger / palm:** `cur_n > 0` treats any contact as present (intended — any resting
  finger keeps the layer warm; covers two-finger scroll-rest). A resting palm also keeps it
  warm by design; the accumulator reset above prevents palm jitter from resurrecting a
  dropped layer.
- **`AUTOMOUSE_CONTACT_STALE_MS`** must sit above `NAVIGATOR_TRACKPAD_POLL_INTERVAL_MS`;
  exact value confirmed against the poll interval in the implementation plan.
- **No config / LED / layout changes.** `keymap.c`, `config.h`, `ledmap` untouched.
- **Merge safety:** `patches/` and `.github/workflows/` are added on `main`, never touched
  on `oryx`, so `git merge -Xignore-all-space oryx` cannot conflict. `.gitignore` only
  ignores `.idea`/`*.iml`, so both are tracked cleanly.
- **Verification:** cannot compile locally; verified by static review, patch applying cleanly
  against the recorded `qmk_modules` SHA, and the Action's Docker build producing an
  artifact. Functional checks (resting finger keeps layer warm; bus-error decay; typed-off
  stays off) are on-device after flashing.
- **Pin option deferred:** explicitly pinning `modules/zsa` to a tested SHA would remove even
  the firmware-bump breakage window, at the cost of manual update cadence. Out of scope; the
  modules are already firmware-pinned and the canary covers the residual risk.

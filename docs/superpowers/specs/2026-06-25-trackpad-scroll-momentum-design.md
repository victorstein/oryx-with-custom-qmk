# Trackpad: two-finger scroll momentum / kinetic coasting (Phase 2) — design

**Date:** 2026-06-25
**Revision:** v2 — **reworked after an adversarial review found the v1 design non-functional.**
Two v1 blockers, both confirmed against the real module:
1. The task (`navigator_trackpad_ptp_task`) does **not** call `process_fallback_mouse` on
   no-contact frames — once the pad is idle it short-circuits (`if (host_contacts.count == 0)
   return false;`, line 411-414). So a coast placed in `process_fallback_mouse` runs for one
   frame then never again. **Fix: drive the coast from the task's idle branch.**
2. Real two-finger lifts are **staggered** (one finger crosses the lift threshold first → a
   `finger_count == 1` frame), which wiped the velocity and missed the `finger_count == 0`
   seed gate → momentum never fired. **Fix: capture velocity during scroll, retain it across
   the lift, and use a short "lift grace" that bridges `2→1→0` while suppressing the cursor.**
Plus v1 minors fixed here: raise the velocity EMA weight (fast short flicks under-seeded);
guard the EMA writes so `TRACKPAD_SCROLL_MOMENTUM 0` is a true no-op.

**Keyboard:** ZSA Voyager (`JRZ6Q`). **Host:** macOS. Build: GitHub Actions → Docker → QMK.
**Builds on:** `2026-06-25-trackpad-two-finger-scroll-design.md` (Phase 1 scroll). Extends the
existing `patches/navigator-trackpad-twofinger-scroll.patch`.

## Goal

Kinetic/momentum scrolling: a two-finger flick keeps scrolling after the fingers lift,
decaying to a stop; touching the pad or clicking catches it. Bundled with a further
scroll-sensitivity reduction (`0.06f → 0.04f`).

## Architecture (corrected)

Momentum spans **two** functions in `navigator_trackpad_ptp.c`:
- **`process_fallback_mouse`** (runs while contacts are present): captures a smoothed scroll
  **velocity** during a 2-finger gesture; on the lift bridges the staggered `2→1→0` with a
  **lift grace**; on full lift **arms a coast** if the flick was fast enough.
- **`navigator_trackpad_ptp_task`** idle branch (the only code that runs every ~5 ms with no
  contact): calls a new static **`scroll_coast_tick()`** that decays the velocity and emits a
  wheel report each tick until it dies — this is what makes the coast actually move.

A coast is **caught** by a new contact (handled in `process_fallback_mouse` when a read
resumes) or a held click (checked in `scroll_coast_tick`). Per-tick exponential decay (the
5 ms tick is fixed-rate, so no timestamp math). Momentum honors `TRACKPAD_SCROLL_NATURAL` and
`TRACKPAD_SCROLL_SENSITIVITY` (velocity is the already-signed, already-scaled increment).

## Behavior

| Event | Result |
|---|---|
| Two fingers scroll, then lift (2→1→0 or 2→0) | scroll coasts, decaying (~0.95/tick, medium) — the staggered single-finger frame does **not** kill it |
| Lift velocity below `TRACKPAD_SCROLL_MOMENTUM_MIN` | no coast — stops where lifted |
| Residual single finger during the lift (within grace) | cursor **suppressed** (it's a lift, not a point) — no cursor twitch |
| Single finger still down **after** the grace | treated as intentional pointing — cursor resumes, arm cleared |
| Touch the pad while coasting | coast stops instantly; that contact resumes cursor/scroll |
| Hold a click (`W`/`E`/`R`) while coasting | coast stops |
| `TRACKPAD_SCROLL_MOMENTUM 0` | exact Phase 1 behavior (scroll stops on lift) |
| Direction / speed | inherits `TRACKPAD_SCROLL_NATURAL` + `TRACKPAD_SCROLL_SENSITIVITY` |

## Config knobs (all `#ifndef`, tunable in `config.h`)

```c
#ifndef TRACKPAD_SCROLL_MOMENTUM
#    define TRACKPAD_SCROLL_MOMENTUM 1          // master on/off
#endif
#ifndef TRACKPAD_SCROLL_DECAY
#    define TRACKPAD_SCROLL_DECAY 0.95f         // velocity *= DECAY per 5ms tick (higher = floatier)
#endif
#ifndef TRACKPAD_SCROLL_MOMENTUM_MIN
#    define TRACKPAD_SCROLL_MOMENTUM_MIN 0.05f  // start/stop velocity threshold (wheel-units/tick)
#endif
#ifndef TRACKPAD_SCROLL_LIFT_GRACE_MS
#    define TRACKPAD_SCROLL_LIFT_GRACE_MS 90    // window after scroll where a residual finger = lift, not point
#endif
#define _NT_SCROLL_VEL_ALPHA 0.5f               // internal EMA weight (raised from v1's 0.35 — short flicks)
```

## Code shape

### `scroll_state` additions

```c
    float    vel_v;             // smoothed scroll velocity (wheel-units/tick)
    float    vel_h;
    bool     coasting;          // a coast is in progress (driven by the task idle loop)
    bool     lift_armed;        // recently scrolling; eligible to start a coast on full lift
    uint32_t last_scroll_time;  // timer of the last 2-finger emit (for the lift grace)
```

### `scroll_coast_tick()` — define before the task (after `clamp_to_int8`)

```c
#if TRACKPAD_SCROLL_MOMENTUM
// One momentum step: decay velocity, emit a wheel report, stop below the threshold.
// Driven from the task idle branch so it runs while no finger is on the pad.
static void scroll_coast_tick(void) {
    if (mousekey_get_report().buttons != 0) {   // a held click catches the coast
        scroll_state.coasting = false;
        scroll_state.vel_v = scroll_state.vel_h = 0.0f;
        return;
    }
    scroll_state.vel_v *= TRACKPAD_SCROLL_DECAY;
    scroll_state.vel_h *= TRACKPAD_SCROLL_DECAY;
    if (fabsf(scroll_state.vel_v) < TRACKPAD_SCROLL_MOMENTUM_MIN &&
        fabsf(scroll_state.vel_h) < TRACKPAD_SCROLL_MOMENTUM_MIN) {
        scroll_state.coasting = false;
        scroll_state.vel_v = scroll_state.vel_h = 0.0f;
        scroll_state.v_accum = scroll_state.h_accum = 0.0f;
        return;
    }
    scroll_state.v_accum += scroll_state.vel_v;   // reuse the Phase-1 fractional accumulator
    scroll_state.h_accum += scroll_state.vel_h;
    int8_t v = clamp_to_int8((int32_t)scroll_state.v_accum);
    int8_t h = clamp_to_int8((int32_t)scroll_state.h_accum);
    scroll_state.v_accum -= v;
    scroll_state.h_accum -= h;
    if (v != 0 || h != 0) {
        report_mouse_t r = {0};
        r.v = v; r.h = h;            // buttons left 0 (no click — checked above)
        host_mouse_send(&r);
    }
}
#endif
```

### `process_fallback_mouse` — capture velocity, bridge the lift, arm the coast

- **Top:** `#if TRACKPAD_SCROLL_MOMENTUM` — a finger contact catches a coast:
  `if (scroll_state.coasting && finger_count >= 1) scroll_state.coasting = false;`
- **Active-scroll steady path** (`finger_count == 2`, after the existing accumulate): also
  (guarded) update velocity + arm:
  ```c
  scroll_state.vel_v = _NT_SCROLL_VEL_ALPHA * inc_v + (1.0f - _NT_SCROLL_VEL_ALPHA) * scroll_state.vel_v;
  scroll_state.vel_h = _NT_SCROLL_VEL_ALPHA * inc_h + (1.0f - _NT_SCROLL_VEL_ALPHA) * scroll_state.vel_h;
  scroll_state.lift_armed       = true;
  scroll_state.last_scroll_time = timer_read32();
  ```
  The enter-scroll block clears `coasting`, `vel_*`, and `lift_armed` (fresh gesture).
- **Leaving the gesture** (the existing `if (scroll_state.active)` block): clear
  `active/settled`, reset `v_accum/h_accum` and `mouse_state.tracking` — but **do NOT** wipe
  `vel_*` / `lift_armed` (needed below).
- **Lift grace + arm (guarded), inserted before the single-finger cursor logic:**
  ```c
  if (scroll_state.lift_armed) {
      if (finger_count == 0) {                 // full lift → arm a coast if fast enough
          if (fabsf(scroll_state.vel_v) >= TRACKPAD_SCROLL_MOMENTUM_MIN ||
              fabsf(scroll_state.vel_h) >= TRACKPAD_SCROLL_MOMENTUM_MIN) {
              scroll_state.coasting = true;    // the task idle loop drives it from here
          }
          scroll_state.lift_armed = false;
          scroll_state.v_accum = scroll_state.h_accum = 0.0f;  // fresh accumulator for the coast
          return;
      }
      if (timer_elapsed32(scroll_state.last_scroll_time) < TRACKPAD_SCROLL_LIFT_GRACE_MS) {
          return;                              // residual finger during the lift → suppress cursor
      }
      scroll_state.lift_armed = false;         // grace expired with a finger down → intentional point
      scroll_state.vel_v = scroll_state.vel_h = 0.0f;
  }
  ```
  Note: `finger_count == 0` only reaches `process_fallback_mouse` on the lift-off-confirm
  fall-through (zeroed report) — exactly the moment all fingers are gone — so that is where
  the coast is armed.

### Task idle branch — drive the coast (`navigator_trackpad_ptp_task`, ~line 411)

```c
if (host_contacts.count == 0) {
    no_data_frames = 0;
#if TRACKPAD_SCROLL_MOMENTUM
    if (scroll_state.coasting) {
        scroll_coast_tick();
        return false;
    }
#endif
    return false;
}
```
(`scroll_state.coasting` is only ever set in mode 0; a mode change calls `reset_mouse_state`
which clears it. `scroll_state` is a file-static, visible to the task.)

### `reset_mouse_state()` — clear all momentum state

Add `coasting = false; lift_armed = false; vel_v = vel_h = 0.0f;` to the existing scroll reset.

## Delivery

- **Extend `patches/navigator-trackpad-twofinger-scroll.patch`** with the above (defines, the
  `scroll_coast_tick` function, the `process_fallback_mouse` additions, the **task idle
  branch** edit, the `reset_mouse_state` additions). Re-author against pristine
  `qmk_modules @ 2e0fc66` with the current scroll patch applied, add momentum, regenerate.
  Sentinel stays `TRACKPAD_SCROLL_SENSITIVITY`; apply script / canary / build / README
  unchanged.
- **`JRZ6Q/config.h`**: `TRACKPAD_SCROLL_SENSITIVITY 0.06f → 0.04f`.

## Verification

1. Patch applies alone + stacked against the pinned SHA.
2. Local Docker compile of `zsa/voyager:JRZ6Q` — confirms `fabsf`, `scroll_coast_tick`, the
   task-branch edit, and the `#if` paths compile (incl. `TRACKPAD_SCROLL_MOMENTUM 0`).
3. On-device: a two-finger flick + lift coasts and decays (medium); touch/click catches it;
   slow/precise scroll doesn't coast; **no cursor twitch on lift**; `W`/`E`/`R` + single-finger
   cursor unaffected. Tune `TRACKPAD_SCROLL_DECAY` (coast length), `_MOMENTUM_MIN` (how firm a
   flick starts/holds it), `_LIFT_GRACE_MS` (if a fast 1-finger move right after scrolling
   feels laggy) — one-line `config.h` + rebuild.

## Pitfalls / risks

- **Velocity quality (minor):** EMA α raised to 0.5 so a 2-3 frame flick seeds usefully; very
  short flicks still under-seed — accepted, tunable via on-device feel of `_MOMENTUM_MIN`.
- **Auto-mouse layer drops mid-coast (cosmetic):** a coast can outlive the 250 ms auto-mouse
  timeout, so the layer reverts mid-coast. Harmless — `scroll_coast_tick` emits `buttons = 0`,
  and you're scrolling, not clicking. Not gating the coast on the layer.
- **Lift-grace vs. fast scroll→drag (minor):** a single-finger move within `_LIFT_GRACE_MS`
  (90 ms) after a scroll is suppressed; a real point resumes after the grace. Tunable.
- **Mode-flip mid-coast (rare):** if the host switches to PTP (Navigator.app launched) during
  a sub-second coast, a few stray wheel events may emit before the next read triggers
  `reset_mouse_state`. Negligible.
- **Stair-step at the coast tail:** integer HID wheel; macOS smooths it. Accepted (Phase-1 same).

## Out of scope

Axis-locking, rubber-band/bounce (macOS owns it), 3-finger gestures. No core/HID changes; no
`keymap.c` changes; no new patch file or workflow change.

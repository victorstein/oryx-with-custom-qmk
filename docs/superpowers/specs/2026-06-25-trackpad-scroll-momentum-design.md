# Trackpad: two-finger scroll momentum / kinetic coasting (Phase 2) — design

**Date:** 2026-06-25
**Keyboard:** ZSA Voyager (`JRZ6Q`), Oryx + custom-QMK hybrid, Navigator trackpad.
**Host:** macOS. Build: GitHub Actions → Docker → QMK.
**Builds on:** `2026-06-25-trackpad-two-finger-scroll-design.md` (Phase 1 scroll). Extends the
existing `patches/navigator-trackpad-twofinger-scroll.patch` (which already does centroid →
wheel via `host_mouse_send`, `TRACKPAD_SCROLL_SENSITIVITY`, `TRACKPAD_SCROLL_NATURAL`).

## Goal

Add **kinetic/momentum scrolling**: a two-finger flick keeps scrolling after the fingers
lift, decaying to a stop — the Phase 2 polish deferred from the Phase 1 spec. Bundled with a
further scroll-sensitivity reduction (`0.06f → 0.04f`) in the same firmware.

## Why it's feasible (established)

The trackpad task (`navigator_trackpad_ptp_task`) fires every ~5 ms **regardless of
contact** (it's gated on a poll timer, not on a finger being present). In mode 0 it calls
`process_fallback_mouse` every tick, so a coast loop can run on the empty (no-finger) ticks
after a lift and keep emitting wheel reports. HID wheel is integer-stepped, so the coast uses
the module's existing fractional-accumulator → `clamp_to_int8` pattern.

## Decision — model

Exponential decay with a **smoothed lift-off velocity**. Per fixed 5 ms tick, multiply the
velocity by a decay constant — no timestamp math needed (the tick is fixed-rate). Velocity at
lift is an EMA of the recent per-tick wheel increment (not just the last frame, which can be
noisy as the finger decelerates). Rejected: linear decay (feels abrupt); a time-based
friction model (overkill for a fixed tick). Momentum honors `TRACKPAD_SCROLL_NATURAL` and
`TRACKPAD_SCROLL_SENSITIVITY` (it coasts the already-signed, already-scaled increment).

## Decision — behavior

| Event | Result |
|---|---|
| Two fingers scroll, then **lift both** (2→0) | scroll coasts, decaying (~0.95/tick ≈ medium) |
| Lift velocity **below** `TRACKPAD_SCROLL_MOMENTUM_MIN` | no coast — stops where lifted (precise scrolling stays precise) |
| **Touch the pad** (1 or 2 fingers) while coasting | coast stops instantly; that finger resumes cursor/scroll |
| **Hold a click** (`W`/`E`/`R`) while coasting | coast stops |
| Lift only **one** of two fingers (2→1) | no coast (likely a transition, not a fling) |
| Momentum disabled (`TRACKPAD_SCROLL_MOMENTUM 0`) | Phase 1 behavior (scroll stops on lift) |
| Direction / speed | inherits `TRACKPAD_SCROLL_NATURAL` + `TRACKPAD_SCROLL_SENSITIVITY` |

## Decision — code shape

All changes extend `process_fallback_mouse` in `navigator_trackpad_ptp.c` (the same function
the Phase 1 scroll patch edits) plus its state struct and the scroll defines. No new patch
file, no workflow change.

### New defines (near the existing `TRACKPAD_SCROLL_*` defines)

```c
#ifndef TRACKPAD_SCROLL_MOMENTUM
#    define TRACKPAD_SCROLL_MOMENTUM 1        // master on/off for kinetic coasting
#endif
#ifndef TRACKPAD_SCROLL_DECAY
#    define TRACKPAD_SCROLL_DECAY 0.95f       // velocity *= DECAY per 5ms tick (higher = floatier)
#endif
#ifndef TRACKPAD_SCROLL_MOMENTUM_MIN
#    define TRACKPAD_SCROLL_MOMENTUM_MIN 0.05f  // start/stop velocity threshold (wheel-units/tick)
#endif
#define _NT_SCROLL_VEL_ALPHA 0.35f            // internal EMA weight for lift-off velocity
```

### `scroll_state` additions

```c
    float vel_v;      // smoothed scroll velocity (wheel-units/tick) for momentum
    float vel_h;
    bool  coasting;
```

### Active-scroll branch — track velocity

In the steady 2-finger emit path, after computing the increment:
```c
float inc_v = (float)(_NT_SCROLL_SIGN * -raw_dy) * TRACKPAD_SCROLL_SENSITIVITY;
float inc_h = (float)(_NT_SCROLL_SIGN *  raw_dx) * TRACKPAD_SCROLL_SENSITIVITY;
scroll_state.v_accum += inc_v;
scroll_state.h_accum += inc_h;
scroll_state.vel_v = _NT_SCROLL_VEL_ALPHA * inc_v + (1.0f - _NT_SCROLL_VEL_ALPHA) * scroll_state.vel_v;
scroll_state.vel_h = _NT_SCROLL_VEL_ALPHA * inc_h + (1.0f - _NT_SCROLL_VEL_ALPHA) * scroll_state.vel_h;
```
The enter-scroll block (`!scroll_state.active`) also zeroes `vel_v/vel_h` and clears
`coasting` (a fresh gesture overrides a coast).

### Top of `process_fallback_mouse` — coast handling (guarded by `#if TRACKPAD_SCROLL_MOMENTUM`)

```c
uint8_t finger_count = sensor_report->fingers[0].tip + sensor_report->fingers[1].tip;

// A held click cancels any coast (you're about to interact).
if (scroll_state.coasting && mousekey_get_report().buttons != 0) {
    scroll_state.coasting = false;
}

if (finger_count == 2) {
    scroll_state.coasting = false;   // active scroll overrides a coast
    ... existing active-scroll logic + velocity EMA ...
    return;
}

// Catch-to-stop: a finger touching ends the coast, then fall through to cursor logic.
if (scroll_state.coasting && finger_count >= 1) {
    scroll_state.coasting = false;
}

// Pure coast tick (no fingers down).
if (scroll_state.coasting) {
    scroll_state.vel_v *= TRACKPAD_SCROLL_DECAY;
    scroll_state.vel_h *= TRACKPAD_SCROLL_DECAY;
    if (fabsf(scroll_state.vel_v) < TRACKPAD_SCROLL_MOMENTUM_MIN &&
        fabsf(scroll_state.vel_h) < TRACKPAD_SCROLL_MOMENTUM_MIN) {
        scroll_state.coasting = false;
        scroll_state.v_accum = scroll_state.h_accum = 0.0f;
        scroll_state.vel_v   = scroll_state.vel_h   = 0.0f;
    } else {
        scroll_state.v_accum += scroll_state.vel_v;
        scroll_state.h_accum += scroll_state.vel_h;
        int8_t v = clamp_to_int8((int32_t)scroll_state.v_accum);
        int8_t h = clamp_to_int8((int32_t)scroll_state.h_accum);
        scroll_state.v_accum -= v;
        scroll_state.h_accum -= h;
        if (v != 0 || h != 0) {
            report_mouse_t r = {0};
            r.buttons = mousekey_get_report().buttons;  // preserve held W/E/R
            r.v = v; r.h = h;
            host_mouse_send(&r);
        }
        return;
    }
}
```

### Exit-scroll block — seed the coast on a full lift

The Phase 1 exit-scroll reset becomes: on `2→0` with velocity ≥ threshold, start coasting
(keep `vel_*` and the `*_accum` carry, return); otherwise reset as before.
```c
if (scroll_state.active) {
    scroll_state.active  = false;
    scroll_state.settled = false;
    mouse_state.tracking = false;
#if TRACKPAD_SCROLL_MOMENTUM
    if (finger_count == 0 &&
        (fabsf(scroll_state.vel_v) >= TRACKPAD_SCROLL_MOMENTUM_MIN ||
         fabsf(scroll_state.vel_h) >= TRACKPAD_SCROLL_MOMENTUM_MIN)) {
        scroll_state.coasting = true;   // vel_* holds lift velocity; coast begins next tick
        return;
    }
#endif
    scroll_state.v_accum = scroll_state.h_accum = 0.0f;
    scroll_state.vel_v   = scroll_state.vel_h   = 0.0f;
}
```

### `reset_mouse_state()` (mode change) also clears coast/velocity

Add `scroll_state.coasting = false; scroll_state.vel_v = 0.0f; scroll_state.vel_h = 0.0f;` to
the existing scroll-state reset.

## Decision — delivery

- **Extend `patches/navigator-trackpad-twofinger-scroll.patch`** with the momentum additions
  (re-author against the pinned `qmk_modules @ 2e0fc66` with the current scroll patch applied,
  then add momentum, regenerate). Sentinel stays `TRACKPAD_SCROLL_SENSITIVITY`. No new patch
  file; the apply script / canary / build pick it up unchanged.
- **`JRZ6Q/config.h`**: lower `TRACKPAD_SCROLL_SENSITIVITY` `0.06f → 0.04f` (shipped together).
  Momentum knobs stay at their patch defaults unless tuned on-device.

## Verification

1. Patch applies alone + stacked against pinned SHA.
2. Local Docker compile of `zsa/voyager:JRZ6Q` (the build/canary path) — confirms `fabsf`,
   `host_mouse_send`, `mousekey_get_report` resolve and the `#if` branches compile.
3. On-device: flick two fingers + lift → scroll coasts and decays; touch the pad or click →
   stops instantly; slow/precise scroll lift → no coast; `W`/`E`/`R` clicks and single-finger
   cursor unaffected. Tune `TRACKPAD_SCROLL_DECAY` (coast length) and
   `TRACKPAD_SCROLL_MOMENTUM_MIN` (sensitivity of start/stop) — one-line `config.h` + rebuild.

## Pitfalls / risks (feel, not feasibility)

- **Decay / threshold are pure on-device tuning** — defaults are starting points.
- **Stair-step at the coast tail:** at very low velocity the integer wheel emits sparse single
  clicks; macOS smooths it. Accepted (same coarseness as Phase 1).
- **Auto-mouse layer during coast:** the coast emits via `host_mouse_send` (HID), which does
  NOT feed automouse — so coasting does not keep the auto-mouse layer warm by itself (the
  layer follows the existing contact/motion rules). Consistent with Phase 1.
- **Catch latency:** a touch is caught within one ~5 ms tick — imperceptible.

## Out of scope

- Horizontal-only or axis-locked momentum (coast carries whatever 2D velocity it had).
- Rubber-band / bounce at document ends (macOS owns that for HID wheel; nothing to do).
- No core/HID changes; no `keymap.c` changes; no new patch file or workflow change.

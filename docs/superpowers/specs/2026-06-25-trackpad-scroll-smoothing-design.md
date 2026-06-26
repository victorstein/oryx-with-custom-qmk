# Trackpad Scroll Smoothing (B2) — Design

**Date:** 2026-06-25
**Status:** Approved for planning
**Depends on:** the existing two-finger scroll + momentum patch (`patches/navigator-trackpad-twofinger-scroll.patch`)

## Problem

Two-finger scroll on the ZSA Voyager + Navigator trackpad feels chunky/stair-stepped on
macOS — it lurches in discrete jumps instead of tracking the finger continuously.

### Why (root cause, confirmed in code)

Scroll is emitted as a **standard integer mouse-wheel report** (`report_mouse_t.v/.h`,
`int8_t`, via `host_mouse_send`). The smallest event macOS will act on is **1 whole line** —
there is no sub-line precision. macOS animates each wheel line with its own easing, then
stalls until the next event. When wheel events arrive **unevenly**, the animations don't
overlap and the motion reads as a stair-step.

The active-scroll path emits straight from the **raw per-frame centroid delta**:

```c
scroll_state.v_accum += inc_v;          // inc_v = raw_dy this frame × sensitivity
int8_t v = clamp_to_int8((int32_t)scroll_state.v_accum);
```

Frame-to-frame variation in `raw_dy` therefore times the wheel clicks unevenly. The code
*already computes* a smoothed velocity (`vel_v`, an EMA) but uses it **only to seed the
momentum coast** — never to drive live emission. The coast emits from that smooth velocity,
which is why coasting reads smoother than an active finger drag.

### Why not "real" high-resolution scroll

The HID Resolution Multiplier (QMK `POINTING_DEVICE_HIRES_SCROLL_ENABLE`) gives sub-line
precision on Windows/Linux, **but macOS does not honor it** — macOS applies its own smoothing
and ignores the device's resolution hint. Genuinely smooth wheel scroll on macOS requires a
host-side helper (Mac Mouse Fix, Mos, discrete-scroll, BetterMouse). That conflicts with the
project's north-star goal of running **app-free** (the whole reason we're replacing
Navigator.app). So sub-line precision is off the table for an app-free firmware solution;
the realistic lever is **even event cadence**, which feeds macOS's own smoother a regular
stream.

## Goal

Make active two-finger scroll feel as smooth as the firmware path allows on macOS, **without
changing scroll speed**, **without an HID descriptor change**, and **without any host-side
app**.

Explicit non-goal: matching a true high-resolution trackpad. A faint residual step at very
low sensitivity is accepted (user decision: "meter only, keep slow speed"). The residual is
governed by the 1-line floor, which only a speed increase could remove; speed is preserved.

## Approach

Drive **active** scroll emission from the **smoothed velocity** (`vel_v/vel_h`), the same
velocity → accumulator → emit pipeline the momentum coast already uses. Even-sized steps
arriving at the steady poll cadence give macOS's smoother a regular stream to animate.

This is a one-mechanism change plus one small refactor:

1. **Emit from velocity, not raw delta.** In `process_fallback_mouse`, after updating the
   velocity EMA, accumulate `vel_v/vel_h` into `v_accum/h_accum` and emit the whole part —
   instead of accumulating the raw per-frame `inc_v/inc_h`. The coast's emit logic is the
   template.

2. **Decouple the velocity EMA from the momentum guard.** The EMA update is currently inside
   `#if TRACKPAD_SCROLL_MOMENTUM`. Smoothing must work even with momentum disabled, so the
   EMA (and the smoothed emission) become unconditional; the coast (`scroll_coast_tick`,
   lift-arming, the task idle-branch driver) remains layered on top behind
   `TRACKPAD_SCROLL_MOMENTUM` as today.

### New tunable

```c
#ifndef TRACKPAD_SCROLL_SMOOTHING
#    define TRACKPAD_SCROLL_SMOOTHING 0.5f   // EMA alpha for scroll velocity; lower = smoother but laggier
#endif
```

- Replaces the current internal `_NT_SCROLL_VEL_ALPHA 0.5f` constant, which becomes this
  overridable knob. `0.5f` preserves today's coast-seed behavior as the starting point;
  the on-device tuning loop will likely lower it for more smoothing.
- `#ifndef`-guarded and overridable in `JRZ6Q/config.h`, oryx-merge-safe, exactly like
  `TRACKPAD_SCROLL_SENSITIVITY` / `_DECAY` / etc.
- Default **on** (smoothing is the feature). Setting alpha to `1.0f` reproduces the current
  raw-delta behavior (no smoothing) — i.e. the knob also serves as the disable.

### Why this preserves speed

An EMA of velocity is unbiased in steady state: integrated over a sustained scroll, output
displacement equals input displacement, so total scroll distance — and therefore speed — is
unchanged. The only difference is a small lag at gesture start (output ramps up over a few
ticks) and a small residual at gesture end (which already flows into the lift-grace/coast
handling that consumes `vel_*`). Neither changes steady-state speed.

## Components / data flow

```
trackpad poll → process_fallback_mouse()
  finger_count == 2:
    raw_dx/dy  = centroid delta this frame
    inc_v/h    = raw_dy/dx × SCROLL_SENSITIVITY        (unchanged)
    vel_v/h    = SMOOTHING·inc + (1−SMOOTHING)·vel_v/h  (EMA — now unconditional)
    v_accum/h += vel_v/h                                (CHANGED: was += inc_v/h)
    emit whole part of accum via host_mouse_send        (unchanged mechanism)
  lift / coast:
    unchanged — coast still seeds from vel_*, drives from task idle branch
```

Single file touched: `patches/navigator-trackpad-twofinger-scroll.patch`.

## Blast radius

- **One patch file.** `automouse-contact.patch` and `navigator-trackpad-contact.patch` are
  untouched.
- **Existing canary covers it.** `patches/*.patch` is globbed by `apply-contact-patches.sh`
  and the weekly `patch-canary.yml`; no new canary work.
- **Config surface.** One new `#ifndef` knob in the module; `JRZ6Q/config.h` gains an
  optional override line. Oryx branch does not define it → merge-safe.
- **Momentum interaction.** `vel_*` semantics are unchanged (still the smoothed velocity), so
  coast seeding, lift-arming, and the lift-grace continue to work. The only structural change
  is moving the EMA update out of the `#if TRACKPAD_SCROLL_MOMENTUM` guard.

## Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| EMA lag makes start/stop feel soft | Medium | Moderate default alpha (0.5); on-device tunable; alpha=1.0 reverts to current feel |
| Smoothing insufficient at sensitivity 0.016 (1-line floor) | Expected | Accepted by design ("meter only, keep slow speed"); speed bump available later as a one-liner |
| Refactor breaks the momentum-off build | Low | Guard matrix compile test (below) |
| Slight distance drift from EMA start/stop transients | Low | Unbiased in steady state; residual consumed by existing lift/coast |

## Testing

No automated test can assert "feels smooth"; acceptance is partly perceptual. Verification:

1. **Guard-matrix local Docker compile** — must build in all four combinations:
   - momentum on  × smoothing on (default)
   - momentum off × smoothing on
   - momentum on  × smoothing off (alpha 1.0)
   - momentum off × smoothing off
2. **Patch idempotency** — `apply-contact-patches.sh` re-run is a no-op (existing
   grep-sentinel + `patch -N`).
3. **On-device feel** — flash, confirm active two-finger scroll is visibly smoother than the
   current build, scroll speed is unchanged, and momentum coast still launches/decays as
   before.
4. **(Optional) cadence capture** — a host-side scroll-event logger should show evenly-spaced
   wheel events during a steady drag, where the current build shows clustered/gapped events.

## Out of scope

- HID descriptor / Resolution Multiplier changes (macOS ignores them).
- Any host-side helper app.
- Changing scroll speed or sensitivity (stays a separate, already-existing knob).
- Horizontal-vs-vertical smoothing asymmetry (single shared alpha; YAGNI).

# Trackpad: native two-finger scroll + cursor-speed tune (Phase 1) — design

**Date:** 2026-06-25
**Keyboard:** ZSA Voyager (`JRZ6Q`), Oryx + custom-QMK hybrid, Navigator trackpad.
**Host:** macOS. Build: GitHub Actions → Docker → QMK.
**Builds on:** `2026-06-25-trackpad-contact-keepalive-design.md` (the CI patch mechanism,
the canary, `scripts/apply-contact-patches.sh`) and the `config.h` overrides
(`AUTOMOUSE_TIMEOUT 250`, `TRACKPAD_TAP_TERM_MS 0`).

## Goal

Make the trackpad fully usable on macOS **without ZSA's Navigator.app**, so it can be
uninstalled. Navigator.app currently owns three host-side behaviors; this removes the need
for it:

- **Tap-to-click** — already disabled (`TRACKPAD_TAP_TERM_MS 0`); its removal is the *goal*.
- **Cursor speed** — a `config.h` tune (no patch).
- **Two-finger scroll** — the one real feature to build in firmware.

**Phase 1 (this spec):** two-finger scroll (vertical + horizontal) + cursor-speed tune.
This alone lets the user uninstall Navigator.app. **Momentum/kinetic scroll is Phase 2**
(separate spec), tuned against how Phase 1 feels on-device.

## Why this is possible (established by investigation + on-device test)

- The trackpad has two host-selected input modes (`digitizer_touchpad_get_input_mode()`):
  `TRACKPAD_INPUT_MODE_MOUSE = 0` and `TRACKPAD_INPUT_MODE_PTP = 3`
  (`navigator_trackpad_ptp.c:65-66`). Navigator.app switches it to PTP and synthesizes all
  gestures host-side. macOS doesn't speak PTP, so **without the app the device sits in mouse
  mode (0)** and the firmware's `process_fallback_mouse()` drives the cursor — **confirmed
  on-device** (cursor still works with the app quit; taps no longer click).
- In mode 0 the cursor is sent via a custom `report_digitizer_touchpad_mouse_t
  {report_id, buttons, x, y}` (QMK core `report.h:283-291`) — **no wheel field**.
- **But this board also exposes a dedicated standard QMK mouse HID interface *with* a wheel**
  (`keyboards/zsa/voyager/keyboard.json`: `mousekey:true`, `usb.shared_endpoint.mouse:false`
  → standalone `MouseReport` descriptor incl. `Usage(0x38) Wheel` and AC-Pan horizontal,
  `usb_descriptor.c:122-224`). This is the same interface the `W`/`E`/`R` `KC_MS_BTN*`
  clicks already use and macOS already honors. `report_mouse_t` (`report.h:216`) carries
  `.v` (vertical wheel) and `.h` (horizontal wheel).
- The sensor is locked to PTP packet mode at init (`cirque_gen6_set_ptp_mode()`,
  `navigator_trackpad_common.c:302`) **regardless of HID input mode**, so even in mode 0,
  `process_fallback_mouse` receives **both** `fingers[0]` and `fingers[1]` absolute
  contacts. (The hardware `scrollDelta` field is only set on the relative `0x06` packet,
  which is never read in this build — so scroll must be computed in software from the two
  contacts, **not** from `scrollDelta`.)

## Decision — emission path (Option B)

Emit two-finger scroll as `report_mouse_t.v`/`.h` via **`host_mouse_send()`** on the
existing dedicated mouse interface. **No HID-descriptor change, no re-enumeration, no core
fork** — the wheel-capable interface already exists and macOS already consumes it. Cursor
stays on the digitizer interface; wheel rides the mouse interface; macOS merges them (it
already does cursor-from-digitizer + buttons-from-mouse).

Rejected: extending the digitizer touchpad-mouse report/descriptor to add a wheel — that
edits two vendored QMK-core files, changes a USB descriptor (re-enumeration risk), and adds
an unknown (whether macOS's mouse-fallback parser honors a wheel there). More surface, no
benefit.

## Decision — behavior

| Input | Result |
|---|---|
| 1 finger moving | cursor move (existing path, unchanged) |
| 2 fingers moving | scroll: avg vertical Δ → `v`, avg horizontal Δ → `h`; cursor does **not** move |
| 2 fingers, still | no scroll (below movement threshold) |
| 2 fingers lift | scroll stops immediately (momentum is Phase 2) |
| Scroll direction / smoothing | inherited from **macOS** scroll settings (standard HID wheel) |
| Tap (1- or 2-finger) | no click (`TRACKPAD_TAP_TERM_MS 0`; two-finger right-click intentionally not added) |
| `W`/`E`/`R` clicks | unaffected (wheel reports preserve button state) |

## Decision — code shape

A patch to `navigator_trackpad_ptp.c`, all changes confined to the mode-0 path
(`process_fallback_mouse`, `navigator_trackpad_ptp.c:210`). No other mode is touched, so the
patch is fully dormant while Navigator.app holds the device in PTP mode.

### Two-finger detection + scroll branch (inside `process_fallback_mouse`)

```c
// finger count from the two absolute contacts the sensor always streams
uint8_t n = sensor_report->fingers[0].tip + sensor_report->fingers[1].tip;

if (n == 2) {
    // --- two-finger scroll ---
    // Average the two contacts' movement since last frame, keyed on finger .id so a
    // packet slot-swap doesn't produce a jump (the module already keys on id elsewhere).
    // Suppress cursor movement; accumulate fractional wheel; emit integer clicks.
    //   scroll_accum_v += avg_dy * TRACKPAD_SCROLL_SENSITIVITY;
    //   scroll_accum_h += avg_dx * TRACKPAD_SCROLL_SENSITIVITY;
    //   int8_t v = clamp_to_int8((int32_t)scroll_accum_v); scroll_accum_v -= v;
    //   int8_t h = clamp_to_int8((int32_t)scroll_accum_h); scroll_accum_h -= h;
    //   if (v || h) { report_mouse_t r = {0}; r.v = v; r.h = h;
    //                 r.buttons = current_mouse_buttons();  // preserve W/E/R (see note)
    //                 host_mouse_send(&r); }
} else if (n == 1) {
    // --- existing single-finger cursor path, unchanged ---
}
// n == 0 → existing finger-up handling; reset scroll state + accumulators on 2→other
```

Reuses the module's existing fractional-accumulator → integer-step technique
(`mouse_state.dx_accum/dy_accum`, `:287-294`) and `clamp_to_int8()` (`:202-206`).

Guards / robustness:
- **Settle time** at the start of a two-finger gesture (mirror the existing
  `TRACKPAD_TAP_SETTLE_TIME_MS` idea) so initial-contact jitter isn't scrolled.
- **Separation sanity check**: ignore as "scroll" if the two contacts are implausibly far
  apart / close (palm or thumb-base), to avoid false scroll. Tunable threshold.
- **Slot-swap safety**: track per-contact previous position keyed on `fingers[].id`; if a
  contact is new (id changed), seed its position without emitting a delta that frame.
- **Mode reset**: the existing `reset_mouse_state()` (`:187`) gains a reset of the new
  scroll accumulators/velocity so a mode change can't leave stale state.

### Button-sharing note

`report_mouse_t` is shared with mousekey (`W`/`E`/`R` = `KC_MS_BTN*`). A wheel report with
`buttons = 0` would momentarily release a held click. **Resolution:** set `r.buttons` to the
current mouse-button state when sending wheel (read it from the mousekey report), so wheel
events never disturb buttons. If reading the live button state proves awkward in the module
context, the accepted fallback is to leave `buttons = 0` and treat "scroll while holding a
click" as a rare unsupported combo — the implementation plan picks one and documents it.

### Tunable constant (patch-side)

```c
#ifndef TRACKPAD_SCROLL_SENSITIVITY
#    define TRACKPAD_SCROLL_SENSITIVITY 0.10f  // sensor-units → wheel-clicks; tune on-device
#endif
```

### Cursor speed (`config.h`, no patch)

The module declares mode-0 cursor shaping `#ifndef`-guarded (`navigator_trackpad/config.h`):
`TRACKPAD_MOUSE_SENSITIVITY` (0.3f), `TRACKPAD_MOUSE_ACCELERATION` (1.1f). Override in
`JRZ6Q/config.h` exactly like `AUTOMOUSE_TIMEOUT` (oryx doesn't define them → survives the
merge):

```c
#define TRACKPAD_MOUSE_SENSITIVITY 0.6f    // starting point; dial in on-device (~0.5–0.8)
#define TRACKPAD_MOUSE_ACCELERATION 1.3f
```

These affect **only** mode-0 cursor (the no-app world we're building for); they're inert
while Navigator.app holds PTP mode.

## Decision — delivery

Reuses the established CI patch mechanism.

- **`patches/navigator-trackpad-twofinger-scroll.patch`** (new) — the scroll branch +
  `TRACKPAD_SCROLL_SENSITIVITY`. Authored against the same pinned `qmk_modules` SHA recorded
  in `patches/README.md` (currently `2e0fc66`). Touches a different region of
  `navigator_trackpad_ptp.c` than the contact patch (`process_fallback_mouse` vs the PTP
  automouse-feed block), so the two patches apply independently.
- **`scripts/apply-contact-patches.sh`** — generalize from the hardcoded two-name loop to
  **apply every `patches/*.patch` (sorted)**, each with the existing loud-fail
  (`CONTACT_PATCH_APPLY_FAILED` + `::error::`). Replace the single automouse-symbol
  idempotency sentinel with a **per-patch already-applied check**: if
  `patch -p1 -d <modules/zsa> --dry-run --reverse < p` succeeds, the patch is already
  applied → skip; else if a forward `--dry-run` succeeds → apply; else → loud fail. This
  scales to any number of patches and keeps idempotency for local re-runs. (Trade-off: drops
  the "upstream shipped the symbol natively → skip-with-notice" nicety; that case now
  surfaces as a loud apply failure the canary flags, which is acceptable.)
- **`JRZ6Q/config.h`** — add the cursor-speed defines (and optionally a
  `TRACKPAD_SCROLL_SENSITIVITY` override if the patch default needs tuning).
- **`patches/README.md`** — list the new patch + its target file.
- Build workflow and canary already pass the whole `patches/` dir to the apply script, so
  no workflow change is needed beyond the generalized script.

## Verification

Same ladder as contact keep-alive:
1. Patch applies cleanly against the pinned SHA (apply script, local + canary).
2. Local Docker compile of `zsa/voyager:JRZ6Q` succeeds (the script's compile path).
3. On-device after flashing (with Navigator.app **quit**, then uninstalled):
   - Two fingers → scroll, vertical and horizontal, correct direction (macOS natural-scroll
     setting applies).
   - One finger → cursor unaffected; no cursor drift during a two-finger scroll.
   - Cursor speed feels right (tune `TRACKPAD_MOUSE_SENSITIVITY`/`ACCELERATION`).
   - `W`/`E`/`R` clicks still work; scrolling while not clicking is clean.
   - Tap still does nothing.
4. Tuning constants (`TRACKPAD_SCROLL_SENSITIVITY`, cursor speed) are `#ifndef`/`config.h`
   one-liners → rebuild without patch churn.

## Pitfalls / risks (feel, not feasibility)

- **macOS honoring wheel** on the mouse interface while cursor is on the digitizer interface
  — expected (buttons already work), but only flashing confirms direction + acceleration.
- **Two-finger robustness** — slot-swaps (→ key on id), touch-down jitter (→ settle time),
  palm/thumb false-scroll (→ separation check). All tunable.
- **Button-sharing** — wheel reports must preserve button state (see note) or accept the
  rare scroll-while-clicking combo.
- **Stepped wheel coarseness** — HID wheel is integer-stepped; macOS smooths it but it won't
  match the app's pixel-precise scroll. Accepted for Phase 1; momentum (Phase 2) and
  sensitivity tuning improve feel.

## Out of scope (Phase 1)

- **Momentum / kinetic coasting** — Phase 2, a separate spec, after Phase 1 feel is known.
- **Two-finger tap → right-click** — explicitly not wanted (tap is being removed).
- **Inertia/natural-direction reimplementation** — unnecessary; macOS owns it for HID wheel.
- No core/HID-descriptor changes. No `keymap.c` changes.

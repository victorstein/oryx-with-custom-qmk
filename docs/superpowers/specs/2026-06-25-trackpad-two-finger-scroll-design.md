# Trackpad: native two-finger scroll + cursor-speed tune (Phase 1) — design

**Date:** 2026-06-25
**Revision:** v2 — incorporates two-reviewer findings (firmware logic + delivery/blast-radius).
Material changes from v1: mandate button-preservation via `mousekey_get_report().buttons`;
`process_fallback_mouse` is a **restructure** (id-keying re-implemented inside it, slot-0
cursor actively suppressed when 2 fingers down); document that two-finger scroll **activates
the auto-mouse layer** (accepted for Phase 1); idempotency uses a **portable per-patch grep
sentinel** (not `patch --reverse`, which lies on macOS BSD patch); correct the cursor-speed
override mechanism (macro redefinition, benign `-Wmacro-redefined`, `#undef` to silence).
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

A patch to `navigator_trackpad_ptp.c`. The scroll logic lives in the mode-0 path
(`process_fallback_mouse`, `navigator_trackpad_ptp.c:210`), which only runs in mouse mode
(0), so the patch is fully dormant while Navigator.app holds the device in PTP mode.

**This is a restructure of `process_fallback_mouse`, not just an added branch** (reviewer
finding). Two things make it more than a bolt-on:
1. The function receives only the **raw** `sensor_report` (plus slot-0 presence) — *not* the
   id-keyed contact list that `navigator_trackpad_ptp_task` builds (`:438-460`). So the
   two-finger path must read `sensor_report->fingers[0..1].{id,tip,x,y}` and maintain **its
   own** per-id previous-position state. (Finger `.id` is stable across packet slot-swaps,
   `:434-437`.)
2. The existing single-finger path keys off **slot 0** and currently runs whenever slot-0 is
   present — *including while a second finger is down*. So the restructure must **actively
   suppress** the slot-0 cursor logic when two fingers are present, not just add an `else`.

### Two-finger detection + scroll branch (inside `process_fallback_mouse`)

```c
// finger count from the two absolute contacts the sensor always streams
uint8_t n = sensor_report->fingers[0].tip + sensor_report->fingers[1].tip;

if (n == 2) {
    // --- two-finger scroll --- (slot-0 cursor path is skipped this frame)
    // Average the two contacts' movement since last frame, keyed on finger .id (maintain a
    // small per-id prev-pos map local to this function). Accumulate fractional wheel,
    // emit integer clicks, preserve held mouse buttons:
    //   scroll_accum_v += avg_dy * TRACKPAD_SCROLL_SENSITIVITY;
    //   scroll_accum_h += avg_dx * TRACKPAD_SCROLL_SENSITIVITY;
    //   int8_t v = clamp_to_int8((int32_t)scroll_accum_v); scroll_accum_v -= v;
    //   int8_t h = clamp_to_int8((int32_t)scroll_accum_h); scroll_accum_h -= h;
    //   if (v || h) {
    //       report_mouse_t r = {0};
    //       r.buttons = mousekey_get_report().buttons;   // preserve W/E/R (mandatory)
    //       r.v = v; r.h = h;
    //       host_mouse_send(&r);
    //   }
} else if (n == 1) {
    // --- existing single-finger cursor path, unchanged ---
}
// n == 0 → existing finger-up handling
```

Reuses the module's existing fractional-accumulator → integer-step technique
(`mouse_state.dx_accum/dy_accum`, `:287-294`) and `clamp_to_int8()` (`:202-206`).

Guards / robustness:
- **Settle time** at the start of a two-finger gesture (mirror the existing
  `TRACKPAD_TAP_SETTLE_TIME_MS` idea) so initial-contact jitter isn't scrolled.
- **Separation sanity check**: ignore as "scroll" if the two contacts are implausibly far
  apart / close (palm or thumb-base), to avoid false scroll. Tunable threshold.
- **Slot-swap / new-contact safety**: track per-contact previous position keyed on
  `fingers[].id`; when a contact id is newly seen, **seed its position without emitting a
  delta** that frame.
- **Per-transition resets (not just on mode change):** clear the scroll accumulators and
  per-id prev-pos whenever finger count drops below 2 (`2→1`, `2→0`) so a stale delta can't
  leak when one finger lifts mid-scroll. `reset_mouse_state()` (`:186`, runs only on
  input-mode change) *also* gains a reset of the new scroll state — but the per-transition
  resets inside `process_fallback_mouse` are the load-bearing ones.

### Button-sharing — preserve held buttons (mandatory)

`report_mouse_t` is shared with mousekey (`W`/`E`/`R` = `KC_MS_BTN*`), and `host_mouse_send`
sends the **full** report — so a wheel report with `buttons = 0` would release a held click.
There is a clean public getter (`mousekey_get_report()`, `mousekey.h:203`) that holds the
live button bits for the full press duration, and QMK's loop is cooperative (race-free read).
So the wheel report **must** set `r.buttons = mousekey_get_report().buttons`. (The v1 "accept
a rare release" fallback is dropped — it's unnecessary.) Reverse-clobber is also safe:
`mousekey_task` only re-sends when its own report changed, so it won't cancel our wheel.

### Interaction with the auto-mouse layer (accepted Phase-1 behavior)

The auto-mouse motion feed (`automouse_report_motion`, in the PTP-path block at `:465-494`)
runs every frame regardless of input mode and watches `cur[0]` motion. During a two-finger
scroll `cur[0]` is moving, so **scroll will activate / keep warm `AUTOMOUSE_LAYER`** (turning
`W`/`E`/`R` into clicks). The scroll *emission* (`host_mouse_send`) does **not** feed
automouse, so there is no thrash loop — but the layer does come on.

For Phase 1 this is **accepted and documented**, not gated: suppressing it cleanly means
editing the automouse-feed block (the contact patch's region), which would couple the two
patches and break "author the scroll patch against the pristine `process_fallback_mouse`
region." The instant-drop-on-typing guard mitigates stray `W`/`E`/`R`-as-click. **If it
annoys on-device, Phase 2 gates the feed on `cur_n < 2`** (a separate, clearly-scoped change
to the feed block).

### Tunable constant (patch-side)

```c
#ifndef TRACKPAD_SCROLL_SENSITIVITY
#    define TRACKPAD_SCROLL_SENSITIVITY 0.10f  // sensor-units → wheel-clicks; tune on-device
#endif
```

### Cursor speed (`config.h`, no patch)

The module declares mode-0 cursor shaping `#ifndef`-guarded (`navigator_trackpad/config.h`):
`TRACKPAD_MOUSE_SENSITIVITY` (0.3f), `TRACKPAD_MOUSE_ACCELERATION` (1.1f). Override in
`JRZ6Q/config.h` (oryx doesn't define them → survives the merge):

```c
#undef  TRACKPAD_MOUSE_SENSITIVITY          // silence the redefinition warning (see note)
#define TRACKPAD_MOUSE_SENSITIVITY 0.6f     // starting point; dial in on-device (~0.5–0.8)
#undef  TRACKPAD_MOUSE_ACCELERATION
#define TRACKPAD_MOUSE_ACCELERATION 1.3f
```

**Override mechanism (corrected from v1 — not the same as `AUTOMOUSE_TIMEOUT`):** the ZSA
build appends community-module `config.h` files to `CONFIG_H` *first*
(`builddefs/build_keyboard.mk:382`) and the keymap `config.h` *last* (`:507`), all forced via
`-include` in order (`common_rules.mk:274`). So `navigator_trackpad/config.h`'s `#ifndef`
fires first (sets 0.3f) and `JRZ6Q/config.h` then **redefines** it — the override wins, but
through macro *redefinition*, producing a benign `-Wmacro-redefined` warning. (Contrast
`AUTOMOUSE_TIMEOUT`, whose `#ifndef` lives in `automouse.h`, `#include`d *after* the config
chain → a clean skip with no warning.) The repo/Dockerfile build with no `-Werror`
(confirmed), so it compiles; the `#undef` above silences the warning cleanly.

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
  **apply every `patches/*.patch` (sorted)**. Per patch: `[ -e "$p" ] || continue` (POSIX
  nullglob guard); **idempotency via a portable per-patch grep sentinel** (the distinctive
  symbol the patch introduces — `automouse_report_contact` for the contact patch,
  `TRACKPAD_SCROLL_SENSITIVITY` for the scroll patch) — if the sentinel is already present in
  the modules tree, skip; else forward `patch --dry-run` then apply, with the existing
  loud-fail (`CONTACT_PATCH_APPLY_FAILED` + `::error::`, which the canary greps —
  `patch-canary.yml:69` — so it MUST stay). Keep the dry-run probes inside `if`/`elif` so
  `set -e` doesn't abort on a non-zero probe.
  - **Do NOT use `patch -R/--reverse` for the idempotency probe** (v1 plan): on macOS BSD
    `patch` it auto-answers the "Ignore -R?" prompt and returns 0 regardless of state, so on
    a pristine tree it would skip every patch and falsely report success — breaking the
    documented *local* verify. `grep` is implementation-independent and works on both GNU
    (CI) and BSD (local macOS) patch. The sentinel approach also **keeps** the "upstream
    shipped the symbol natively → skip" behavior for free.
  - The apply *loop* is glob-generalized (no script edit to add a patch); the per-patch
    sentinel is a small association the script carries (a patch without a registered sentinel
    falls back to forward-apply, loud-failing if already applied — fine, since CI trees are
    always fresh and the local refresh procedure clones fresh).
- **`JRZ6Q/config.h`** — add the cursor-speed defines (and optionally a
  `TRACKPAD_SCROLL_SENSITIVITY` override if the patch default needs tuning).
- **`patches/README.md`** — list the new patch + its target file + a regen line; and update
  the script header/sentinel **comments** (they describe the old single-sentinel behavior).
- Build workflow and canary already `cp -r patches …` and pass the dir to the apply script
  (`fetch-and-build-layout.yml:117,128`; `patch-canary.yml:50,63`), so a new `*.patch` is
  auto-picked-up — **no workflow change needed** beyond the generalized script.

**Blast-radius note (accepted):** the build applies all patches "or the build fails (exit 1)".
A future upstream bump that breaks the **scroll** patch would abort the whole JRZ6Q build —
taking down the **live, in-`main` contact-keepalive feature** too (no artifact), not just
scroll. Sorted order applies the contact patches first, so scroll can't block *their* apply,
but a scroll failure still aborts after they're applied. Accepted given the weekly canary
catches drift before a real build is needed; the scroll patch is under the same canary
discipline (the canary compiles JRZ6Q with all patches). Non-JRZ6Q / firmware<24 builds stay
untouched (the build gate + the script's module-absent skip are unchanged).

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
- **Button-sharing** — wheel reports preserve button state via `mousekey_get_report().buttons`
  (mandatory; see note).
- **Stepped wheel coarseness** — HID wheel is integer-stepped; macOS smooths it but it won't
  match the app's pixel-precise scroll. Accepted for Phase 1; momentum (Phase 2) and
  sensitivity tuning improve feel.
- **Wheel width is governed by `WHEEL_EXTENDED_REPORT`** (not `MOUSE_EXTENDED_REPORT`, which
  is x/y). Neither is defined here → `.v`/`.h` are int8 → `clamp_to_int8()` is correct. Don't
  enable the wrong macro when tuning.
- **Rotation coupling (no-op here, note it):** the cursor path applies `NT_ROTATE_DELTA`
  (`:273`); `NAVIGATOR_TRACKPAD_ROTATION` defaults to 0 with no override, so it compiles to a
  no-op. If a rotation is ever configured, apply the same `NT_ROTATE_DELTA` to the averaged
  scroll delta so scroll axes track cursor axes.

## Source citation corrections (v2)
`report_mouse_t` / the digitizer report structs are in **`tmk_core/protocol/report.h`** (the
line numbers cited — `:216`, `:283-291` — are for that file, not `quantum/report.h`).
`reset_mouse_state` is at `navigator_trackpad_ptp.c:186`.

## Out of scope (Phase 1)

- **Momentum / kinetic coasting** — Phase 2, a separate spec, after Phase 1 feel is known.
- **Two-finger tap → right-click** — explicitly not wanted (tap is being removed).
- **Inertia/natural-direction reimplementation** — unnecessary; macOS owns it for HID wheel.
- No core/HID-descriptor changes. No `keymap.c` changes.

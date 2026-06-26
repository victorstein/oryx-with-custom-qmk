# Trackpad Scroll Momentum (Phase 2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Kinetic/momentum coasting for the firmware two-finger scroll (flick + lift → decays to a stop; touch/click catches it), bundled with a further sensitivity reduction.

**Architecture:** Extend `patches/navigator-trackpad-twofinger-scroll.patch`. Momentum spans two functions: `process_fallback_mouse` captures velocity + bridges the staggered lift (lift-grace), and the **task idle branch** (`navigator_trackpad_ptp_task`) drives a `scroll_coast_tick()` each ~5ms poll while no finger is present (the only code that runs during idle). No new patch file / workflow change.

**Tech Stack:** QMK community module (C), POSIX `sh`, `patch(1)`, GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-06-25-trackpad-scroll-momentum-design.md` (v3 — passed adversarial re-review).

**Build target:** `firmware25` → `modules/zsa @ 2e0fc66b0f2102ff899e0d985a5be65283fe7578`.

**Key facts:**
- This **extends** the merged Phase 1 scroll patch — author against pristine `qmk_modules @ 2e0fc66` **with the current scroll patch applied first** (Task 1). Sentinel stays `TRACKPAD_SCROLL_SENSITIVITY`; apply script / canary / build / README unchanged.
- All edits are in `navigator_trackpad/navigator_trackpad_ptp.c`. `math.h` (`fabsf`) + `quantum.h` (`host_mouse_send`, `mousekey_get_report`, `digitizer_touchpad_get_input_mode` is `extern`'d at the top of the file) are available; `clamp_to_int8`, `timer_read32/elapsed32` already used.
- Momentum is `#if TRACKPAD_SCROLL_MOMENTUM`-guarded so disabled = exact Phase 1.

---

## File Structure

| Path | Modify | Responsibility |
|---|---|---|
| `patches/navigator-trackpad-twofinger-scroll.patch` | Regenerate | Momentum: velocity capture + lift-grace in `process_fallback_mouse`, `scroll_coast_tick`, the task idle-branch coast driver |
| `JRZ6Q/config.h` | Modify | `TRACKPAD_SCROLL_SENSITIVITY 0.06f → 0.04f` |

---

## Task 1: Branch + scratch with the current scroll patch applied

- [ ] **Step 1: Branch + pristine scratch + apply current scroll patch**

```bash
cd /Volumes/stein/Documents/development/personal/oryx-with-custom-qmk
git checkout main && git pull --ff-only
git checkout -b feature/trackpad-scroll-momentum
SCRATCH=/private/tmp/claude-501/-Volumes-stein-Documents-development-personal-oryx-with-custom-qmk/7a8c34fa-230d-422e-8365-da0318d12917/scratchpad
rm -rf "$SCRATCH/qmk_modules"
git clone -q https://github.com/zsa/qmk_modules.git "$SCRATCH/qmk_modules"
git -C "$SCRATCH/qmk_modules" checkout -q 2e0fc66b0f2102ff899e0d985a5be65283fe7578
patch -p1 -d "$SCRATCH/qmk_modules" < patches/navigator-trackpad-twofinger-scroll.patch
```
Expected: `patching file 'navigator_trackpad/navigator_trackpad_ptp.c'`. (No commit — workspace prep.)

---

## Task 2: Add momentum to the scroll patch

**Files:** Edit (scratch) `$SCRATCH/qmk_modules/navigator_trackpad/navigator_trackpad_ptp.c`; regenerate `patches/navigator-trackpad-twofinger-scroll.patch`.

Set `SCRATCH` as in Task 1. Nine edits, then regenerate + verify.

- [ ] **Step 1: Momentum defines (after the `_NT_SCROLL_SIGN` block)**

Find:
```c
#if TRACKPAD_SCROLL_NATURAL
#    define _NT_SCROLL_SIGN (-1)
#else
#    define _NT_SCROLL_SIGN (1)
#endif

#ifndef TRACKPAD_MAX_DELTA
```
Replace with:
```c
#if TRACKPAD_SCROLL_NATURAL
#    define _NT_SCROLL_SIGN (-1)
#else
#    define _NT_SCROLL_SIGN (1)
#endif

#ifndef TRACKPAD_SCROLL_MOMENTUM
#    define TRACKPAD_SCROLL_MOMENTUM 1          // master on/off for kinetic coasting
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
#define _NT_SCROLL_VEL_ALPHA 0.5f               // internal EMA weight for lift-off velocity

#ifndef TRACKPAD_MAX_DELTA
```

- [ ] **Step 2: `scroll_state` momentum fields**

Find:
```c
    float    v_accum;
    float    h_accum;
} scroll_state = {0};
```
Replace with:
```c
    float    v_accum;
    float    h_accum;
    float    vel_v;             // smoothed scroll velocity (wheel-units/tick)
    float    vel_h;
    bool     coasting;          // a coast is in progress (driven by the task idle loop)
    bool     lift_armed;        // recently scrolling; eligible to start a coast on full lift
    uint32_t last_scroll_time;  // timer of the last 2-finger emit (for the lift grace)
} scroll_state = {0};
```

- [ ] **Step 3: `scroll_coast_tick()` (after `clamp_to_int8`, before `process_fallback_mouse`)**

Find:
```c
// Clamp value to int8_t range
static inline int8_t clamp_to_int8(int32_t value) {
    if (value > 127) return 127;
    if (value < -127) return -127;
    return (int8_t)value;
}
```
Replace with (append the new function):
```c
// Clamp value to int8_t range
static inline int8_t clamp_to_int8(int32_t value) {
    if (value > 127) return 127;
    if (value < -127) return -127;
    return (int8_t)value;
}

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
    scroll_state.v_accum += scroll_state.vel_v;
    scroll_state.h_accum += scroll_state.vel_h;
    int8_t v = clamp_to_int8((int32_t)scroll_state.v_accum);
    int8_t h = clamp_to_int8((int32_t)scroll_state.h_accum);
    scroll_state.v_accum -= v;
    scroll_state.h_accum -= h;
    if (v != 0 || h != 0) {
        report_mouse_t r = {0};
        r.v = v;
        r.h = h;
        host_mouse_send(&r);
    }
}
#endif
```

- [ ] **Step 4: Top-of-function coast catch (a finger contact stops a coast)**

Find:
```c
    uint8_t finger_count = sensor_report->fingers[0].tip + sensor_report->fingers[1].tip;
    if (finger_count == 2) {
```
Replace with:
```c
    uint8_t finger_count = sensor_report->fingers[0].tip + sensor_report->fingers[1].tip;
#if TRACKPAD_SCROLL_MOMENTUM
    if (scroll_state.coasting && finger_count >= 1) {
        scroll_state.coasting = false;   // a finger touch catches the coast
    }
#endif
    if (finger_count == 2) {
```

- [ ] **Step 5: Capture velocity + arm in the steady scroll path**

Find:
```c
        // Vertical wheel from Δy, horizontal from Δx. The sign on v is the on-device
        // tunable (flip if inverted); macOS natural-scroll applies on top.
        scroll_state.v_accum += (float)(_NT_SCROLL_SIGN * -raw_dy) * TRACKPAD_SCROLL_SENSITIVITY;
        scroll_state.h_accum += (float)(_NT_SCROLL_SIGN *  raw_dx) * TRACKPAD_SCROLL_SENSITIVITY;
```
Replace with:
```c
        // Vertical wheel from Δy, horizontal from Δx. The sign on v is the on-device
        // tunable (flip if inverted); macOS natural-scroll applies on top.
        float inc_v = (float)(_NT_SCROLL_SIGN * -raw_dy) * TRACKPAD_SCROLL_SENSITIVITY;
        float inc_h = (float)(_NT_SCROLL_SIGN *  raw_dx) * TRACKPAD_SCROLL_SENSITIVITY;
        scroll_state.v_accum += inc_v;
        scroll_state.h_accum += inc_h;
#if TRACKPAD_SCROLL_MOMENTUM
        // Smooth the per-tick increment into a velocity, and arm a coast for lift-off.
        scroll_state.vel_v = _NT_SCROLL_VEL_ALPHA * inc_v + (1.0f - _NT_SCROLL_VEL_ALPHA) * scroll_state.vel_v;
        scroll_state.vel_h = _NT_SCROLL_VEL_ALPHA * inc_h + (1.0f - _NT_SCROLL_VEL_ALPHA) * scroll_state.vel_h;
        scroll_state.lift_armed       = true;
        scroll_state.last_scroll_time = timer_read32();
#endif
```

- [ ] **Step 6: Clear momentum state when a fresh 2-finger gesture starts**

Find:
```c
            scroll_state.v_accum    = 0.0f;
            scroll_state.h_accum    = 0.0f;
            return;  // seed only; no scroll on the first frame
```
Replace with:
```c
            scroll_state.v_accum    = 0.0f;
            scroll_state.h_accum    = 0.0f;
#if TRACKPAD_SCROLL_MOMENTUM
            scroll_state.vel_v      = 0.0f;
            scroll_state.vel_h      = 0.0f;
            scroll_state.coasting   = false;
            scroll_state.lift_armed = false;
#endif
            return;  // seed only; no scroll on the first frame
```

- [ ] **Step 7: Replace the exit-scroll block with exit + lift-grace + arm**

Find:
```c
    // Leaving a scroll gesture (finger count dropped below 2): clear scroll state and
    // force the cursor path to re-seed on the next genuine finger-down.
    if (scroll_state.active) {
        scroll_state.active  = false;
        scroll_state.settled = false;
        scroll_state.v_accum = 0.0f;
        scroll_state.h_accum = 0.0f;
        mouse_state.tracking = false;
    }
```
Replace with:
```c
    // Leaving a scroll gesture (finger count dropped below 2): clear active/accum/tracking,
    // but keep vel_*/lift_armed for the lift-grace + coast arming below.
    if (scroll_state.active) {
        scroll_state.active  = false;
        scroll_state.settled = false;
        scroll_state.v_accum = 0.0f;
        scroll_state.h_accum = 0.0f;
        mouse_state.tracking = false;
    }

#if TRACKPAD_SCROLL_MOMENTUM
    if (scroll_state.lift_armed) {
        if (finger_count == 0) {                 // full lift → arm a coast if fast enough
            if (fabsf(scroll_state.vel_v) >= TRACKPAD_SCROLL_MOMENTUM_MIN ||
                fabsf(scroll_state.vel_h) >= TRACKPAD_SCROLL_MOMENTUM_MIN) {
                scroll_state.coasting = true;    // the task idle loop drives it from here
            } else {
                scroll_state.vel_v = scroll_state.vel_h = 0.0f;
            }
            scroll_state.lift_armed = false;
            scroll_state.v_accum = scroll_state.h_accum = 0.0f;
            return;
        }
        if (timer_elapsed32(scroll_state.last_scroll_time) < TRACKPAD_SCROLL_LIFT_GRACE_MS) {
            return;                              // residual finger during the lift → suppress cursor
        }
        // Grace expired with a finger still down → intentional pointing. The rising-edge
        // tracker won't re-arm (the finger's been down the whole time), so synthesize a
        // fresh track-down on the slot-0 residual.
        scroll_state.lift_armed = false;
        scroll_state.vel_v = scroll_state.vel_h = 0.0f;
        if (finger_down) {
            mouse_state.tracking         = true;
            mouse_state.last_x           = sensor_report->fingers[0].x;
            mouse_state.last_y           = sensor_report->fingers[0].y;
            mouse_state.dx_accum         = 0.0f;
            mouse_state.dy_accum         = 0.0f;
            mouse_state.touch_start_time = timer_read32();
            mouse_state.settled          = false;
            mouse_state.is_drag          = false;
        }
    }
#endif
```

- [ ] **Step 8: Reset momentum state in `reset_mouse_state()`**

Find:
```c
    scroll_state.active  = false;
    scroll_state.settled = false;
    scroll_state.v_accum = 0.0f;
    scroll_state.h_accum = 0.0f;
}
```
Replace with:
```c
    scroll_state.active   = false;
    scroll_state.settled  = false;
    scroll_state.v_accum  = 0.0f;
    scroll_state.h_accum  = 0.0f;
    scroll_state.vel_v    = 0.0f;
    scroll_state.vel_h    = 0.0f;
    scroll_state.coasting = false;
    scroll_state.lift_armed = false;
}
```

- [ ] **Step 9: Drive the coast from the task idle branch + clear on dead-bus**

Find:
```c
        if (!trackpad_init) {
            // Dead bus: let the probe/re-init path recover; don't synthesize
            // lift-offs off a failed transaction.
            no_data_frames = 0;
            return false;
        }
        if (host_contacts.count == 0) {
            // Pad already idle — nothing to release.
            no_data_frames = 0;
            return false;
        }
```
Replace with:
```c
        if (!trackpad_init) {
            // Dead bus: let the probe/re-init path recover; don't synthesize
            // lift-offs off a failed transaction.
            no_data_frames = 0;
#if TRACKPAD_SCROLL_MOMENTUM
            scroll_state.coasting = false;   // abandon any coast on a bus error
            scroll_state.vel_v = scroll_state.vel_h = 0.0f;
#endif
            return false;
        }
        if (host_contacts.count == 0) {
            // Pad already idle — nothing to release.
            no_data_frames = 0;
#if TRACKPAD_SCROLL_MOMENTUM
            if (scroll_state.coasting) {
                // Drive the coast each idle poll. Gate on mode: the mode-change detection
                // only runs on a successful read, which never happens during an idle coast.
                if (digitizer_touchpad_get_input_mode() == TRACKPAD_INPUT_MODE_MOUSE) {
                    scroll_coast_tick();
                } else {
                    scroll_state.coasting = false;   // host switched to PTP mid-coast
                }
                return false;
            }
#endif
            return false;
        }
```

- [ ] **Step 10: Regenerate the patch**

```bash
git -C "$SCRATCH/qmk_modules" diff -- navigator_trackpad > patches/navigator-trackpad-twofinger-scroll.patch
grep -cE "scroll_coast_tick|TRACKPAD_SCROLL_MOMENTUM|lift_armed|scroll_state.coasting|TRACKPAD_SCROLL_LIFT_GRACE_MS" patches/navigator-trackpad-twofinger-scroll.patch
```
Expected: a count ≥ 12.

- [ ] **Step 11: Test — applies alone + stacked**

```bash
rm -rf /tmp/qm-m && git clone -q https://github.com/zsa/qmk_modules.git /tmp/qm-m && git -C /tmp/qm-m checkout -q 2e0fc66b0f2102ff899e0d985a5be65283fe7578
patch -p1 -d /tmp/qm-m --dry-run < patches/navigator-trackpad-twofinger-scroll.patch >/dev/null; echo "alone=$?"
rm -rf /tmp/qm-ms && git clone -q https://github.com/zsa/qmk_modules.git /tmp/qm-ms && git -C /tmp/qm-ms checkout -q 2e0fc66b0f2102ff899e0d985a5be65283fe7578
for p in automouse-contact.patch navigator-trackpad-contact.patch navigator-trackpad-twofinger-scroll.patch; do patch -p1 -d /tmp/qm-ms < "patches/$p" >/dev/null && echo "ok $p"; done; echo "stack=$?"
```
Expected: `alone=0`; three `ok` lines; `stack=0`.

- [ ] **Step 12: Commit**

```bash
git add patches/navigator-trackpad-twofinger-scroll.patch
git commit -m "✨(patches): Two-finger scroll momentum (task-driven coast + lift-grace)"
```

---

## Task 3: Lower scroll sensitivity to 0.04

- [ ] **Step 1: Edit `JRZ6Q/config.h`**

Find:
```c
#define TRACKPAD_SCROLL_SENSITIVITY 0.06f  // two-finger scroll speed (patch default 0.10); lower = slower
```
Replace with:
```c
#define TRACKPAD_SCROLL_SENSITIVITY 0.04f  // two-finger scroll speed (patch default 0.10); lower = slower
```

- [ ] **Step 2: Commit**

```bash
git add JRZ6Q/config.h
git commit -m "🔧(qmk): Reduce two-finger scroll sensitivity 0.06 → 0.04"
```

---

## Task 4: Local integration compile (incl. momentum-off)

**Files:** none (validation). Requires Docker.

- [ ] **Step 1: Build locally (momentum on)**

```bash
cd /Volumes/stein/Documents/development/personal/oryx-with-custom-qmk
FW=25
git submodule update --init --depth=1 qmk_firmware
( cd qmk_firmware && git fetch --depth=1 origin "firmware${FW}" && git checkout -B "firmware${FW}" "origin/firmware${FW}" && git submodule update --init --recursive )
mkdir -p qmk_firmware/keyboards/zsa/voyager/keymaps && rm -rf qmk_firmware/keyboards/zsa/voyager/keymaps/JRZ6Q
cp -r JRZ6Q qmk_firmware/keyboards/zsa/voyager/keymaps/JRZ6Q
cp -r patches qmk_firmware/_contact_patches
cp scripts/apply-contact-patches.sh qmk_firmware/_contact_apply.sh
docker build -t qmk . >/tmp/mom-docker.log 2>&1
docker run -v ./qmk_firmware:/root --rm qmk /bin/sh -c "
  qmk setup zsa/qmk_firmware -b firmware${FW} -y
  sh /root/_contact_apply.sh /root/modules/zsa /root/_contact_patches || exit 1
  make zsa/voyager:JRZ6Q
" 2>&1 | tee /tmp/mom-compile.log | grep -iE "applied navigator-trackpad-twofinger|Creating binary load file|error:"
```
Expected: the scroll patch applied, `Creating binary load file ... zsa_voyager_JRZ6Q.bin [OK]`, no `error:` (confirms `scroll_coast_tick`, `fabsf`, `digitizer_touchpad_get_input_mode`, and the task-branch edit compile).

- [ ] **Step 2: Sanity-check momentum-OFF compiles (no unused-static)**

```bash
docker run -v ./qmk_firmware:/root --rm qmk /bin/sh -c "
  cd /root && rm -rf .build
  make zsa/voyager:JRZ6Q EXTRAFLAGS='-DTRACKPAD_SCROLL_MOMENTUM=0' 2>&1
" 2>&1 | tee /tmp/mom-off.log | grep -iE "Creating binary load file|error:|warning: unused"
git submodule deinit -f qmk_firmware
```
Expected: builds to `.bin`; no `error:`; no `unused` warning for `scroll_coast_tick` (it's `#if`-guarded). (If `EXTRAFLAGS` isn't honored, instead temporarily add `#define TRACKPAD_SCROLL_MOMENTUM 0` to `JRZ6Q/config.h`, rebuild, then revert — note which you did.)

> If Docker is unavailable, skip Task 4 — the canary compiles in CI (Task 5). Note the skip.

---

## Task 5: CI verify + on-device tuning (outward-facing — confirm before running)

- [ ] **Step 1: Push + PR**

```bash
git push -u origin feature/trackpad-scroll-momentum
gh pr create --base main --head feature/trackpad-scroll-momentum \
  --title "✨ Two-finger scroll momentum + lower sensitivity (Phase 2)" \
  --body "Implements docs/superpowers/specs/2026-06-25-trackpad-scroll-momentum-design.md (v3, passed adversarial re-review). Task-driven coast (decay 0.95, smoothed lift velocity) + lift-grace; touch/click catches; slow lifts don't coast. Extends the scroll patch + drives a coast tick from the task idle branch. Sensitivity 0.06→0.04. Verified by local docker apply+compile (momentum on and off)."
```

- [ ] **Step 2: Canary verifies in CI**

```bash
gh workflow run patch-canary.yml --ref feature/trackpad-scroll-momentum
sleep 6
RID=$(gh run list --workflow patch-canary.yml --branch feature/trackpad-scroll-momentum --limit 1 --json databaseId --jq '.[0].databaseId')
gh run watch "$RID" --exit-status
```
Expected: green.

- [ ] **Step 3: Merge + build firmware**

```bash
gh pr merge feature/trackpad-scroll-momentum --merge --delete-branch
git checkout main && git pull --ff-only
gh workflow run fetch-and-build-layout.yml -f layout_id=JRZ6Q -f layout_geometry=voyager
sleep 6
BID=$(gh run list --workflow fetch-and-build-layout.yml --limit 1 --json databaseId --jq '.[0].databaseId')
gh run watch "$BID" --exit-status
gh run download "$BID" --dir /tmp/momentum-fw
find /tmp/momentum-fw -name '*.bin'
```
Expected: green; `zsa_voyager_JRZ6Q.bin` downloaded. Give the user the run URL + `.bin` path.

- [ ] **Step 4: On-device tuning (user, after flashing — Navigator.app quit)**

- Flick two fingers + lift → scroll coasts and decays (medium). Touch/click → stops. Slow scroll → no coast. **No cursor twitch on lift**; keep one finger down after scrolling → cursor resumes after ~90ms.
- Too floaty/short → `#define TRACKPAD_SCROLL_DECAY <v>` (0.97 floatier / 0.90 snappier).
- Starts/stops too eagerly → `#define TRACKPAD_SCROLL_MOMENTUM_MIN <v>`.
- Lag re-acquiring cursor after scroll → lower `#define TRACKPAD_SCROLL_LIFT_GRACE_MS <v>`.
- Off → `#define TRACKPAD_SCROLL_MOMENTUM 0`.

---

## Self-Review

**Spec coverage (v3):** task-driven coast (`scroll_coast_tick` in the idle branch) → T2 S3,S9; velocity EMA α=0.5 + arm → T2 S5; lift-grace + full-lift seed + cursor re-acquire → T2 S7; top catch → T2 S4; mode-gate + dead-bus clear → T2 S9; enter/reset clears → T2 S6,S8; config knobs (incl. `_LIFT_GRACE_MS`, `_VEL_ALPHA`) → T2 S1; struct fields → T2 S2; disable-flag guards everywhere (`#if TRACKPAD_SCROLL_MOMENTUM`); sensitivity 0.04 → T3; momentum-off compile check → T4 S2; verification ladder → T2 S11, T4, T5. ✓

**Placeholder scan:** none — every edit is a complete find/replace; commands have expected output.

**Type/name consistency:** `scroll_state.{vel_v,vel_h,coasting,lift_armed,last_scroll_time}` defined (T2 S2) and used (S3-S9); `scroll_coast_tick` defined (S3) and called (S9); defines (S1) used in S3/S5/S7/S9; `_NT_SCROLL_SIGN`/`TRACKPAD_SCROLL_SENSITIVITY`/`clamp_to_int8`/`mousekey_get_report`/`host_mouse_send`/`fabsf`/`digitizer_touchpad_get_input_mode`/`TRACKPAD_INPUT_MODE_MOUSE` reused as-is; sentinel `TRACKPAD_SCROLL_SENSITIVITY` preserved for the apply script. ✓

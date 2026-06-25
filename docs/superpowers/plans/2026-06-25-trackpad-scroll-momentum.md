# Trackpad Scroll Momentum (Phase 2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add kinetic/momentum coasting to the firmware two-finger scroll (flick + lift → scroll decays to a stop; touch/click catches it), bundled with a further scroll-sensitivity reduction.

**Architecture:** Extend the existing `patches/navigator-trackpad-twofinger-scroll.patch` — momentum lives in the same `process_fallback_mouse` (the trackpad task fires every ~5ms regardless of contact, so coast ticks run on empty frames). Exponential per-tick decay of a smoothed lift-off velocity, emitted via the existing fractional-accumulator → `host_mouse_send` path. No new patch file, no workflow change.

**Tech Stack:** QMK community module (C), POSIX `sh`, `patch(1)`, GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-06-25-trackpad-scroll-momentum-design.md`.

**Build target:** `firmware25` → `modules/zsa @ 2e0fc66b0f2102ff899e0d985a5be65283fe7578`.

**Key facts:**
- This **extends** the merged Phase 1 scroll patch — author against pristine `qmk_modules @ 2e0fc66` **with the current scroll patch applied first** (Task 1), so the diff is scroll+momentum combined. The patch sentinel stays `TRACKPAD_SCROLL_SENSITIVITY`; the apply script, canary, build, and README need **no** changes.
- All edits are in `navigator_trackpad/navigator_trackpad_ptp.c` (defines, `scroll_state`, `reset_mouse_state`, `process_fallback_mouse`). `math.h` (`fabsf`) and `quantum.h` (`host_mouse_send`, `mousekey_get_report`) are already included; `clamp_to_int8`, `timer_read32/elapsed32` already used.
- The momentum code is guarded by `#if TRACKPAD_SCROLL_MOMENTUM` so it's a no-op when disabled.

---

## File Structure

| Path | Modify | Responsibility |
|---|---|---|
| `patches/navigator-trackpad-twofinger-scroll.patch` | Modify (regenerate) | Adds momentum to `process_fallback_mouse` on top of the existing scroll logic |
| `JRZ6Q/config.h` | Modify | `TRACKPAD_SCROLL_SENSITIVITY 0.06f → 0.04f` |

---

## Task 1: Branch + scratch with the current scroll patch applied

**Files:** none committed (workspace prep).

- [ ] **Step 1: Branch**

```bash
cd /Volumes/stein/Documents/development/personal/oryx-with-custom-qmk
git checkout main && git pull --ff-only
git checkout -b feature/trackpad-scroll-momentum
```

- [ ] **Step 2: Pristine scratch + apply the CURRENT scroll patch**

```bash
SCRATCH=/private/tmp/claude-501/-Volumes-stein-Documents-development-personal-oryx-with-custom-qmk/7a8c34fa-230d-422e-8365-da0318d12917/scratchpad
rm -rf "$SCRATCH/qmk_modules"
git clone -q https://github.com/zsa/qmk_modules.git "$SCRATCH/qmk_modules"
git -C "$SCRATCH/qmk_modules" checkout -q 2e0fc66b0f2102ff899e0d985a5be65283fe7578
patch -p1 -d "$SCRATCH/qmk_modules" < patches/navigator-trackpad-twofinger-scroll.patch
git -C "$SCRATCH/qmk_modules" diff --stat   # shows navigator_trackpad_ptp.c modified
```
Expected: `patching file 'navigator_trackpad/navigator_trackpad_ptp.c'`; the diff stat shows that one file changed. The scratch now holds the **current** scroll source — momentum edits go on top.

---

## Task 2: Add momentum to the scroll patch

**Files:**
- Edit (scratch): `$SCRATCH/qmk_modules/navigator_trackpad/navigator_trackpad_ptp.c`
- Modify: `patches/navigator-trackpad-twofinger-scroll.patch` (regenerate)

Set `SCRATCH` as in Task 1. Make all five edits, then regenerate + verify.

- [ ] **Step 1: Add momentum defines (after the `_NT_SCROLL_SIGN` block)**

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
#    define TRACKPAD_SCROLL_MOMENTUM 1        // master on/off for kinetic coasting
#endif
#ifndef TRACKPAD_SCROLL_DECAY
#    define TRACKPAD_SCROLL_DECAY 0.95f       // velocity *= DECAY per 5ms tick (higher = floatier)
#endif
#ifndef TRACKPAD_SCROLL_MOMENTUM_MIN
#    define TRACKPAD_SCROLL_MOMENTUM_MIN 0.05f  // start/stop velocity threshold (wheel-units/tick)
#endif
#define _NT_SCROLL_VEL_ALPHA 0.35f            // internal EMA weight for lift-off velocity

#ifndef TRACKPAD_MAX_DELTA
```

- [ ] **Step 2: Add `vel_v`/`vel_h`/`coasting` to `scroll_state`**

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
    float    vel_v;      // smoothed scroll velocity (wheel-units/tick) for momentum
    float    vel_h;
    bool     coasting;
} scroll_state = {0};
```

- [ ] **Step 3: Reset momentum state in `reset_mouse_state()`**

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
}
```

- [ ] **Step 4: Clear coast + velocity when a fresh 2-finger gesture starts**

Find (inside the enter-scroll block):
```c
            scroll_state.v_accum    = 0.0f;
            scroll_state.h_accum    = 0.0f;
            return;  // seed only; no scroll on the first frame
```
Replace with:
```c
            scroll_state.v_accum    = 0.0f;
            scroll_state.h_accum    = 0.0f;
            scroll_state.vel_v      = 0.0f;
            scroll_state.vel_h      = 0.0f;
            scroll_state.coasting   = false;
            return;  // seed only; no scroll on the first frame
```

- [ ] **Step 5: Track smoothed velocity in the active-scroll emit path**

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
        // Smooth the per-tick increment into a velocity for momentum at lift-off.
        scroll_state.vel_v = _NT_SCROLL_VEL_ALPHA * inc_v + (1.0f - _NT_SCROLL_VEL_ALPHA) * scroll_state.vel_v;
        scroll_state.vel_h = _NT_SCROLL_VEL_ALPHA * inc_h + (1.0f - _NT_SCROLL_VEL_ALPHA) * scroll_state.vel_h;
```

- [ ] **Step 6: Insert the coast tick + catch, and seed the coast on full lift**

Find the exit-scroll block:
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
#if TRACKPAD_SCROLL_MOMENTUM
    // Momentum catch: a held click or any finger contact stops a coast (then normal
    // handling resumes below).
    if (scroll_state.coasting && (mousekey_get_report().buttons != 0 || finger_count >= 1)) {
        scroll_state.coasting = false;
    }
    // Pure coast tick (no fingers down): decay the velocity and keep emitting wheel.
    if (scroll_state.coasting) {
        scroll_state.vel_v *= TRACKPAD_SCROLL_DECAY;
        scroll_state.vel_h *= TRACKPAD_SCROLL_DECAY;
        if (fabsf(scroll_state.vel_v) < TRACKPAD_SCROLL_MOMENTUM_MIN &&
            fabsf(scroll_state.vel_h) < TRACKPAD_SCROLL_MOMENTUM_MIN) {
            scroll_state.coasting = false;
            scroll_state.v_accum = 0.0f;
            scroll_state.h_accum = 0.0f;
            scroll_state.vel_v   = 0.0f;
            scroll_state.vel_h   = 0.0f;
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
                r.v = v;
                r.h = h;
                host_mouse_send(&r);
            }
            return;
        }
    }
#endif

    // Leaving a scroll gesture (finger count dropped below 2): clear scroll state and
    // force the cursor path to re-seed on the next genuine finger-down.
    if (scroll_state.active) {
        scroll_state.active  = false;
        scroll_state.settled = false;
        mouse_state.tracking = false;
#if TRACKPAD_SCROLL_MOMENTUM
        // On a full lift (2→0) with enough velocity, start coasting; vel_* holds the
        // lift speed and the *_accum carry is kept. The coast runs on the next tick.
        if (finger_count == 0 &&
            (fabsf(scroll_state.vel_v) >= TRACKPAD_SCROLL_MOMENTUM_MIN ||
             fabsf(scroll_state.vel_h) >= TRACKPAD_SCROLL_MOMENTUM_MIN)) {
            scroll_state.coasting = true;
            return;
        }
#endif
        scroll_state.v_accum = 0.0f;
        scroll_state.h_accum = 0.0f;
        scroll_state.vel_v   = 0.0f;
        scroll_state.vel_h   = 0.0f;
    }
```

- [ ] **Step 7: Regenerate the patch**

```bash
git -C "$SCRATCH/qmk_modules" diff -- navigator_trackpad > patches/navigator-trackpad-twofinger-scroll.patch
echo "=== momentum bits present? ==="
grep -cE "TRACKPAD_SCROLL_MOMENTUM|scroll_state.coasting|scroll_state.vel_v|TRACKPAD_SCROLL_DECAY" patches/navigator-trackpad-twofinger-scroll.patch
```
Expected: a count ≥ 8 (the new defines, struct fields, coast logic).

- [ ] **Step 8: Test — applies alone + stacked**

```bash
rm -rf /tmp/qm-m && git clone -q https://github.com/zsa/qmk_modules.git /tmp/qm-m && git -C /tmp/qm-m checkout -q 2e0fc66b0f2102ff899e0d985a5be65283fe7578
patch -p1 -d /tmp/qm-m --dry-run < patches/navigator-trackpad-twofinger-scroll.patch >/dev/null; echo "alone=$?"
rm -rf /tmp/qm-ms && git clone -q https://github.com/zsa/qmk_modules.git /tmp/qm-ms && git -C /tmp/qm-ms checkout -q 2e0fc66b0f2102ff899e0d985a5be65283fe7578
for p in automouse-contact.patch navigator-trackpad-contact.patch navigator-trackpad-twofinger-scroll.patch; do patch -p1 -d /tmp/qm-ms < "patches/$p" >/dev/null && echo "ok $p"; done; echo "stack=$?"
```
Expected: `alone=0`; three `ok` lines; `stack=0`.

- [ ] **Step 9: Commit**

```bash
git add patches/navigator-trackpad-twofinger-scroll.patch
git commit -m "✨(patches): Two-finger scroll momentum (decay + smoothed velocity, touch/click catch)"
```

---

## Task 3: Lower scroll sensitivity to 0.04

**Files:**
- Modify: `JRZ6Q/config.h`

- [ ] **Step 1: Edit the override**

In `JRZ6Q/config.h`, find:
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

## Task 4: Local integration compile

**Files:** none (validation). Requires Docker.

- [ ] **Step 1: Reproduce the build locally**

```bash
cd /Volumes/stein/Documents/development/personal/oryx-with-custom-qmk
FW=25
git submodule update --init --depth=1 qmk_firmware
( cd qmk_firmware && git fetch --depth=1 origin "firmware${FW}" && git checkout -B "firmware${FW}" "origin/firmware${FW}" && git submodule update --init --recursive )
mkdir -p qmk_firmware/keyboards/zsa/voyager/keymaps
rm -rf qmk_firmware/keyboards/zsa/voyager/keymaps/JRZ6Q
cp -r JRZ6Q qmk_firmware/keyboards/zsa/voyager/keymaps/JRZ6Q
cp -r patches qmk_firmware/_contact_patches
cp scripts/apply-contact-patches.sh qmk_firmware/_contact_apply.sh
docker build -t qmk . >/tmp/momentum-docker-build.log 2>&1
docker run -v ./qmk_firmware:/root --rm qmk /bin/sh -c "
  qmk setup zsa/qmk_firmware -b firmware${FW} -y
  sh /root/_contact_apply.sh /root/modules/zsa /root/_contact_patches || exit 1
  make zsa/voyager:JRZ6Q
" 2>&1 | tee /tmp/momentum-compile.log | grep -iE "module-patches: applied navigator-trackpad-twofinger|Creating binary load file|error:"
git submodule deinit -f qmk_firmware
```
Expected: `module-patches: applied navigator-trackpad-twofinger-scroll.patch`, the compile ends `Creating binary load file ... zsa_voyager_JRZ6Q.bin [OK]`, **no** `error:` (confirms `fabsf`/`host_mouse_send`/`mousekey_get_report` resolve and the `#if` branches compile).

> If Docker is unavailable, skip — the canary (Task 5) compiles in CI. Note the skip.

---

## Task 5: CI verify + on-device tuning (outward-facing — confirm before running)

Pushes, runs billed CI, ends in flashing. Confirm with the user first.

- [ ] **Step 1: Push + PR**

```bash
git push -u origin feature/trackpad-scroll-momentum
gh pr create --base main --head feature/trackpad-scroll-momentum \
  --title "✨ Two-finger scroll momentum + lower sensitivity (Phase 2)" \
  --body "Implements docs/superpowers/specs/2026-06-25-trackpad-scroll-momentum-design.md. Kinetic coasting (decay 0.95, smoothed lift velocity) in process_fallback_mouse; touch/click catches the coast; slow lifts don't coast. Extends the existing scroll patch. Sensitivity 0.06→0.04. Verified by local docker apply+compile."
```

- [ ] **Step 2: Canary verifies apply+compile in CI**

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
Expected: green; a `zsa_voyager_JRZ6Q.bin` downloaded. Give the user the run URL + `.bin` path.

- [ ] **Step 4: On-device tuning (user, after flashing — Navigator.app quit)**

- Flick two fingers and lift → scroll coasts and decays (~medium). Touch the pad or click → stops instantly. Slow/precise scroll → no coast.
- Too floaty / too short → tune `#define TRACKPAD_SCROLL_DECAY <v>` in `JRZ6Q/config.h` (e.g. 0.97 floatier, 0.90 snappier) + rebuild.
- Coast starts/stops too eagerly → tune `#define TRACKPAD_SCROLL_MOMENTUM_MIN <v>` (higher = needs a firmer flick) + rebuild.
- Want it off → `#define TRACKPAD_SCROLL_MOMENTUM 0`.
- Confirm `W`/`E`/`R` clicks + single-finger cursor still fine.

---

## Self-Review

**Spec coverage:**
- Exponential decay + smoothed (EMA) lift velocity → Task 2 Steps 1,5,6. ✓
- Behavior: coast on full lift, slow-lift no-coast, touch/click catch, 2→1 no coast, disable flag → Task 2 Step 6 (catch + seed gated on `finger_count==0` and threshold; momentum `#if`). ✓
- Config knobs `TRACKPAD_SCROLL_MOMENTUM`/`_DECAY`/`_MOMENTUM_MIN` + internal `_NT_SCROLL_VEL_ALPHA` → Task 2 Step 1. ✓
- `scroll_state` fields + `reset_mouse_state` reset → Task 2 Steps 2,3. ✓
- Inherits `_NT_SCROLL_SIGN` + `TRACKPAD_SCROLL_SENSITIVITY` (velocity computed from the signed/scaled increment) → Task 2 Step 5. ✓
- Bundled sensitivity 0.06→0.04 → Task 3. ✓
- Extends existing patch; no new file/workflow; sentinel unchanged → Task 1-2 (regenerate same patch). ✓
- Verification ladder (applies/stacks, local compile, on-device) → Task 2 Step 8, Task 4, Task 5. ✓

**Placeholder scan:** none — every edit is a complete find/replace with full code; commands have expected output. (Task 5 tuning values are deliberately user ranges.)

**Type/name consistency:** `scroll_state.{vel_v,vel_h,coasting}` defined (Task 2 Step 2) and used in Steps 3-6; defines `TRACKPAD_SCROLL_MOMENTUM`/`_DECAY`/`_MOMENTUM_MIN`/`_NT_SCROLL_VEL_ALPHA` defined (Step 1) and used (Steps 5-6); existing `_NT_SCROLL_SIGN`, `TRACKPAD_SCROLL_SENSITIVITY`, `clamp_to_int8`, `mousekey_get_report`, `host_mouse_send`, `fabsf` reused as-is; the regenerated patch keeps the `TRACKPAD_SCROLL_SENSITIVITY` sentinel the apply script greps. ✓

# Trackpad Two-Finger Scroll (Phase 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add native two-finger scroll (vertical + horizontal) to the trackpad's mode-0 mouse-fallback path + a cursor-speed config tune, so the user can uninstall ZSA's Navigator.app on macOS.

**Architecture:** A new CI-applied patch to the `navigator_trackpad` community module restructures `process_fallback_mouse` to detect two fingers and emit scroll as standard `report_mouse_t.v`/`.h` via `host_mouse_send()` on the board's existing dedicated mouse interface (no core/HID changes). Cursor speed is a `config.h` override. Delivered via the existing patch mechanism, with the apply script generalized to glob all patches.

**Tech Stack:** QMK community module (C), GitHub Actions (YAML), POSIX `sh`, `patch(1)`, `gh` CLI.

**Spec:** `docs/superpowers/specs/2026-06-25-trackpad-two-finger-scroll-design.md` (v2).

**Build target (authoritative):** `firmware25` → `modules/zsa @ 2e0fc66b0f2102ff899e0d985a5be65283fe7578`. Author the patch against this SHA.

**Key facts for the implementer:**
- The patch is confined to `navigator_trackpad/navigator_trackpad_ptp.c`, all edits in the EARLY region (`process_fallback_mouse` + nearby defines/struct, lines ~80–330) — well before the contact patch's insertion (~line 473), so the two patches apply independently in either order.
- `quantum.h` is already `#include`d in that file, which transitively provides `host_mouse_send()` (host.h) and `mousekey_get_report()` (mousekey.h, since `MOUSEKEY_ENABLE` is on). `report.h` is also already included. If the compile errors on either symbol, add `#include "host.h"` / `#include "mousekey.h"` — but expect it to work via quantum.h.
- `report_mouse_t` here has **no** `report_id` field (`MOUSE_SHARED_EP` undefined) and `.v`/`.h` are **int8** (`WHEEL_EXTENDED_REPORT` undefined) → `clamp_to_int8()` is correct.
- **Scroll uses the centroid of the two contacts** (`(x0+x1)/2, (y0+y1)/2`). The centroid is order-independent, so packet slot-swaps need no special handling.
- `TRACKPAD_MAX_DELTA` (250) is defined at `navigator_trackpad_ptp.c:93`.
- The user's `config.h` already sets `TRACKPAD_TAP_TERM_MS 0` (tap disabled) — the scroll patch does not touch tap logic.

---

## File Structure

| Path | Create/Modify | Responsibility |
|---|---|---|
| `patches/navigator-trackpad-twofinger-scroll.patch` | Create | Two-finger scroll in `process_fallback_mouse` (centroid → wheel via `host_mouse_send`) + `TRACKPAD_SCROLL_SENSITIVITY` |
| `scripts/apply-contact-patches.sh` | Modify | Generalize to glob `patches/*.patch` with portable per-patch grep-sentinel idempotency |
| `patches/README.md` | Modify | List the new patch + regen line; fix stale sentinel comments |
| `JRZ6Q/config.h` | Modify | Cursor-speed overrides (`TRACKPAD_MOUSE_SENSITIVITY`/`_ACCELERATION`) + optional `TRACKPAD_SCROLL_SENSITIVITY` |

---

## Task 1: Branch + pristine scratch checkout

**Files:**
- (working dir) a **pristine** scratch clone of `zsa/qmk_modules @ 2e0fc66` (the earlier contact-keepalive work left the existing scratch modified — it must be reset/re-cloned so the scroll patch diffs against pristine).

- [ ] **Step 1: Create the feature branch**

Run:
```bash
cd /Volumes/stein/Documents/development/personal/oryx-with-custom-qmk
git checkout main && git pull --ff-only
git checkout -b feature/trackpad-two-finger-scroll
```
Expected: on `feature/trackpad-two-finger-scroll`.

- [ ] **Step 2: Get a PRISTINE scratch checkout at the pinned SHA**

Run:
```bash
SCRATCH=/private/tmp/claude-501/-Volumes-stein-Documents-development-personal-oryx-with-custom-qmk/7a8c34fa-230d-422e-8365-da0318d12917/scratchpad
rm -rf "$SCRATCH/qmk_modules"
git clone -q https://github.com/zsa/qmk_modules.git "$SCRATCH/qmk_modules"
git -C "$SCRATCH/qmk_modules" checkout -q 2e0fc66b0f2102ff899e0d985a5be65283fe7578
git -C "$SCRATCH/qmk_modules" status --porcelain   # must be EMPTY (pristine)
git -C "$SCRATCH/qmk_modules" rev-parse HEAD
```
Expected: empty `status --porcelain`; HEAD prints `2e0fc66b0f2102ff899e0d985a5be65283fe7578`.

(No commit in this task — it only prepares the workspace.)

---

## Task 2: Author `patches/navigator-trackpad-twofinger-scroll.patch`

**Files:**
- Edit (scratch): `$SCRATCH/qmk_modules/navigator_trackpad/navigator_trackpad_ptp.c`
- Create: `patches/navigator-trackpad-twofinger-scroll.patch`

Set `SCRATCH` as in Task 1. The four edits below are all in the early region of the file. Read each anchor before editing to confirm it matches (line numbers are for pristine `2e0fc66`).

- [ ] **Step 1: Add the `TRACKPAD_SCROLL_SENSITIVITY` define**

In `navigator_trackpad_ptp.c`, after the tap-settle define block (ends ~line 90):
```c
#ifndef TRACKPAD_TAP_SETTLE_TIME_MS
#    define TRACKPAD_TAP_SETTLE_TIME_MS 30  // Ignore movement during initial contact (ms)
#endif
```
Insert immediately after that `#endif`:
```c

#ifndef TRACKPAD_SCROLL_SENSITIVITY
#    define TRACKPAD_SCROLL_SENSITIVITY 0.10f  // two-finger scroll: sensor-units → wheel-clicks; tune on-device
#endif
```

- [ ] **Step 2: Add the `scroll_state` struct**

The fallback `mouse_state` struct ends (~line 168) with:
```c
    uint8_t  prev_buttons;
} mouse_state = {0};
```
Insert immediately after that closing `} mouse_state = {0};`:
```c

// Two-finger scroll state. Tracks the CENTROID of the two contacts; the centroid is
// order-independent, so packet slot-swaps need no special handling.
static struct {
    bool     active;
    bool     settled;
    uint32_t start_time;
    uint16_t prev_cx;
    uint16_t prev_cy;
    float    v_accum;
    float    h_accum;
} scroll_state = {0};
```

- [ ] **Step 3: Reset scroll state in `reset_mouse_state()`**

`reset_mouse_state()` ends (~line 201) with:
```c
    mouse_state.pending_release = false;
    mouse_state.prev_buttons = 0;
}
```
Change it to add the scroll reset before the closing brace:
```c
    mouse_state.pending_release = false;
    mouse_state.prev_buttons = 0;
    scroll_state.active  = false;
    scroll_state.settled = false;
    scroll_state.v_accum = 0.0f;
    scroll_state.h_accum = 0.0f;
}
```

- [ ] **Step 4: Add the two-finger scroll branch at the top of `process_fallback_mouse`**

The function begins (~line 210):
```c
static void process_fallback_mouse(cgen6_report_t *sensor_report, bool finger_down, bool prev_finger_down) {
    int8_t dx = 0;
    int8_t dy = 0;
    uint8_t buttons = 0;

    // Handle pending click release from previous cycle (like mouse mode)
```
Insert the scroll block between the `uint8_t buttons = 0;` line and the `// Handle pending click release` comment:
```c
static void process_fallback_mouse(cgen6_report_t *sensor_report, bool finger_down, bool prev_finger_down) {
    int8_t dx = 0;
    int8_t dy = 0;
    uint8_t buttons = 0;

    // --- Two-finger scroll (mode-0 fallback) ---
    // While two fingers are down, scroll instead of moving the cursor. Emitted as a
    // standard mouse wheel report on the dedicated mouse interface (host_mouse_send),
    // which macOS consumes natively; cursor stays on the digitizer interface.
    uint8_t finger_count = sensor_report->fingers[0].tip + sensor_report->fingers[1].tip;
    if (finger_count == 2) {
        uint16_t cx = ((uint16_t)sensor_report->fingers[0].x + (uint16_t)sensor_report->fingers[1].x) / 2;
        uint16_t cy = ((uint16_t)sensor_report->fingers[0].y + (uint16_t)sensor_report->fingers[1].y) / 2;

        if (!scroll_state.active) {
            // Entering a scroll gesture: cancel any single-finger cursor/click state so
            // a held click or in-progress drag doesn't leak into the scroll.
            if (mouse_state.prev_buttons != 0 || mouse_state.pending_release) {
                send_mouse_report(0, 0, 0);
            }
            mouse_state.prev_buttons    = 0;
            mouse_state.pending_release = false;
            mouse_state.tracking        = false;
            mouse_state.is_drag         = false;
            scroll_state.active     = true;
            scroll_state.settled    = false;
            scroll_state.start_time = timer_read32();
            scroll_state.prev_cx    = cx;
            scroll_state.prev_cy    = cy;
            scroll_state.v_accum    = 0.0f;
            scroll_state.h_accum    = 0.0f;
            return;  // seed only; no scroll on the first frame
        }

        // Settle: ignore jitter during the first TRACKPAD_TAP_SETTLE_TIME_MS.
        if (!scroll_state.settled) {
            if (timer_elapsed32(scroll_state.start_time) >= TRACKPAD_TAP_SETTLE_TIME_MS) {
                scroll_state.settled = true;
                scroll_state.prev_cx = cx;
                scroll_state.prev_cy = cy;
            }
            return;
        }

        int16_t raw_dx = (int16_t)cx - (int16_t)scroll_state.prev_cx;
        int16_t raw_dy = (int16_t)cy - (int16_t)scroll_state.prev_cy;
        scroll_state.prev_cx = cx;
        scroll_state.prev_cy = cy;

        // Reject implausible jumps (a contact being replaced mid-gesture).
        if (raw_dx >  TRACKPAD_MAX_DELTA) raw_dx =  TRACKPAD_MAX_DELTA;
        if (raw_dx < -TRACKPAD_MAX_DELTA) raw_dx = -TRACKPAD_MAX_DELTA;
        if (raw_dy >  TRACKPAD_MAX_DELTA) raw_dy =  TRACKPAD_MAX_DELTA;
        if (raw_dy < -TRACKPAD_MAX_DELTA) raw_dy = -TRACKPAD_MAX_DELTA;

        // Vertical wheel from Δy, horizontal from Δx. The sign on v is the on-device
        // tunable (flip if inverted); macOS natural-scroll applies on top.
        scroll_state.v_accum += (float)(-raw_dy) * TRACKPAD_SCROLL_SENSITIVITY;
        scroll_state.h_accum += (float)( raw_dx) * TRACKPAD_SCROLL_SENSITIVITY;

        int8_t v = clamp_to_int8((int32_t)scroll_state.v_accum);
        int8_t h = clamp_to_int8((int32_t)scroll_state.h_accum);
        scroll_state.v_accum -= v;
        scroll_state.h_accum -= h;

        if (v != 0 || h != 0) {
            report_mouse_t r = {0};
            r.buttons = mousekey_get_report().buttons;  // preserve held W/E/R clicks
            r.v = v;
            r.h = h;
            host_mouse_send(&r);
        }
        return;
    }

    // Leaving a scroll gesture (finger count dropped below 2): clear scroll state and
    // force the cursor path to re-seed on the next genuine finger-down.
    if (scroll_state.active) {
        scroll_state.active  = false;
        scroll_state.settled = false;
        scroll_state.v_accum = 0.0f;
        scroll_state.h_accum = 0.0f;
        mouse_state.tracking = false;
    }

    // Handle pending click release from previous cycle (like mouse mode)
```
Everything from `// Handle pending click release` onward is unchanged.

- [ ] **Step 5: Generate the patch**

Run:
```bash
git -C "$SCRATCH/qmk_modules" diff -- navigator_trackpad > patches/navigator-trackpad-twofinger-scroll.patch
head -5 patches/navigator-trackpad-twofinger-scroll.patch
```
Expected: starts `diff --git a/navigator_trackpad/navigator_trackpad_ptp.c ...`; file non-empty; exactly ONE file changed (only `navigator_trackpad_ptp.c`).

- [ ] **Step 6: Test — applies cleanly to pristine, AND alongside the existing two patches**

Run:
```bash
rm -rf /tmp/qm-s && git clone -q https://github.com/zsa/qmk_modules.git /tmp/qm-s && git -C /tmp/qm-s checkout -q 2e0fc66b0f2102ff899e0d985a5be65283fe7578
# alone:
patch -p1 -d /tmp/qm-s --dry-run < patches/navigator-trackpad-twofinger-scroll.patch; echo "alone_exit=$?"
# with the existing patches, sorted order (automouse, contact, scroll):
rm -rf /tmp/qm-all && git clone -q https://github.com/zsa/qmk_modules.git /tmp/qm-all && git -C /tmp/qm-all checkout -q 2e0fc66b0f2102ff899e0d985a5be65283fe7578
for p in automouse-contact.patch navigator-trackpad-contact.patch navigator-trackpad-twofinger-scroll.patch; do
  patch -p1 -d /tmp/qm-all < "patches/$p" >/dev/null && echo "applied $p"
done
echo "all_exit=$?"
```
Expected: `alone_exit=0`; three `applied …` lines; `all_exit=0` (the scroll patch's region precedes the contact patch's insertion, so they don't collide).

- [ ] **Step 7: Commit**

```bash
git add patches/navigator-trackpad-twofinger-scroll.patch
git commit -m "✨(patches): Two-finger scroll in the navigator_trackpad mode-0 fallback"
```

---

## Task 3: Generalize the apply script

**Files:**
- Modify: `scripts/apply-contact-patches.sh`

- [ ] **Step 1: Replace the script with the generalized version**

Overwrite `scripts/apply-contact-patches.sh` with EXACTLY:
```sh
#!/bin/sh
# Apply the trackpad module patches to the ZSA community modules in-tree.
# Usage: apply-contact-patches.sh <modules_zsa_dir> <patches_dir>
# (filename kept for the workflows that reference it.)
#
# Applies every patches/*.patch (sorted). Idempotent via a per-patch grep "sentinel"
# (a string unique to each patch's added code): if the sentinel is already present in
# the modules tree, the patch is skipped (already applied, or upstream shipped it).
# grep is used instead of `patch --reverse` because BSD/macOS patch mis-detects
# reverse-applicability non-interactively. Exit 0 = applied or safely skipped;
# Exit 1 = a patch failed to apply (prints CONTACT_PATCH_APPLY_FAILED — the canary
# greps it — plus a GitHub ::error:: annotation).
set -eu

MODULES_DIR="${1:?usage: apply-contact-patches.sh <modules_zsa_dir> <patches_dir>}"
PATCHES_DIR="${2:?usage: apply-contact-patches.sh <modules_zsa_dir> <patches_dir>}"

# Distinctive sentinel per patch (unique to that patch's added lines).
sentinel_for() {
  case "$1" in
    automouse-contact.patch)                    echo "AUTOMOUSE_CONTACT_STALE_MS" ;;
    navigator-trackpad-contact.patch)           echo "automouse_report_contact(cur_n" ;;
    navigator-trackpad-twofinger-scroll.patch)  echo "TRACKPAD_SCROLL_SENSITIVITY" ;;
    *)                                          echo "" ;;
  esac
}

# Guard: only act when the ZSA modules are actually present (other geometries/layouts
# and legacy firmware <24 don't have them — build those untouched).
if [ ! -d "$MODULES_DIR/automouse" ] || [ ! -d "$MODULES_DIR/navigator_trackpad" ]; then
  echo "::notice::module-patches: ZSA modules not found at $MODULES_DIR — skipping."
  exit 0
fi

for p in "$PATCHES_DIR"/*.patch; do
  [ -e "$p" ] || continue          # nullglob guard: POSIX leaves the glob literal if empty
  name=$(basename "$p")
  sentinel=$(sentinel_for "$name")

  if [ -n "$sentinel" ] && grep -rq "$sentinel" "$MODULES_DIR" 2>/dev/null; then
    echo "::notice::module-patches: $name already applied (or upstream ships it) — skipping."
    continue
  fi
  if ! patch -p1 -d "$MODULES_DIR" --dry-run < "$p" >/dev/null 2>&1; then
    echo "CONTACT_PATCH_APPLY_FAILED"
    echo "::error::module-patches: $name does not apply against the current qmk_modules — refresh it (see patches/README.md)."
    exit 1
  fi
  if ! patch -p1 -d "$MODULES_DIR" < "$p" >/dev/null; then
    echo "CONTACT_PATCH_APPLY_FAILED"
    echo "::error::module-patches: $name apply failed after a passing dry-run (disk/permission error?)."
    exit 1
  fi
  echo "module-patches: applied $name"
done
echo "module-patches: all patches applied to $MODULES_DIR"
```

- [ ] **Step 2: Test — modules-absent skip**

Run:
```bash
chmod +x scripts/apply-contact-patches.sh
sh scripts/apply-contact-patches.sh /tmp/none patches; echo "exit=$?"
```
Expected: `::notice::module-patches: ZSA modules not found ...` then `exit=0`.

- [ ] **Step 3: Test — applies all three patches to a fresh clone**

Run:
```bash
rm -rf /tmp/qm-apply && git clone -q https://github.com/zsa/qmk_modules.git /tmp/qm-apply && git -C /tmp/qm-apply checkout -q 2e0fc66b0f2102ff899e0d985a5be65283fe7578
sh scripts/apply-contact-patches.sh /tmp/qm-apply patches; echo "exit=$?"
```
Expected: three `module-patches: applied …` lines (automouse-contact, navigator-trackpad-contact, navigator-trackpad-twofinger-scroll), then `all patches applied`, `exit=0`.

- [ ] **Step 4: Test — idempotent re-run (all skipped)**

Run:
```bash
sh scripts/apply-contact-patches.sh /tmp/qm-apply patches; echo "exit=$?"
```
Expected: three `… already applied … skipping.` notices, `exit=0`. (Confirms grep-sentinel idempotency works on whatever patch is on the host — including macOS BSD patch.)

- [ ] **Step 5: Test — loud fail on a broken patch**

Run:
```bash
rm -rf /tmp/qm-break && git clone -q https://github.com/zsa/qmk_modules.git /tmp/qm-break && git -C /tmp/qm-break checkout -q 2e0fc66b0f2102ff899e0d985a5be65283fe7578
mkdir -p /tmp/bp && cp patches/*.patch /tmp/bp/
# corrupt a real CONTEXT line of the scroll patch so it can't locate its anchor:
sed -i.bak 's/Handle pending click release from previous cycle/THIS_CONTEXT_DOES_NOT_EXIST/' /tmp/bp/navigator-trackpad-twofinger-scroll.patch
sh scripts/apply-contact-patches.sh /tmp/qm-break /tmp/bp; echo "exit=$?"
```
Expected: the first two patches apply, then a line `CONTACT_PATCH_APPLY_FAILED` and `::error::module-patches: navigator-trackpad-twofinger-scroll.patch does not apply ...`, then `exit=1`.

- [ ] **Step 6: Commit**

```bash
git add scripts/apply-contact-patches.sh
git commit -m "🔧(scripts): Generalize apply script to glob all patches (portable grep idempotency)"
```

---

## Task 4: Update docs/comments

**Files:**
- Modify: `patches/README.md`

- [ ] **Step 1: Update the patch list + regen commands**

In `patches/README.md`, the patch list currently reads:
```markdown
- `automouse-contact.patch` → `automouse/automouse.{h,c}`
- `navigator-trackpad-contact.patch` → `navigator_trackpad/navigator_trackpad_ptp.c`
```
Add the scroll patch:
```markdown
- `automouse-contact.patch` → `automouse/automouse.{h,c}`
- `navigator-trackpad-contact.patch` → `navigator_trackpad/navigator_trackpad_ptp.c`
- `navigator-trackpad-twofinger-scroll.patch` → `navigator_trackpad/navigator_trackpad_ptp.c`
```
And in the "Regenerate" step, after:
```markdown
3. Regenerate: `git diff -- automouse > .../patches/automouse-contact.patch`
   and `git diff -- navigator_trackpad > .../patches/navigator-trackpad-contact.patch`.
```
append a note:
```markdown
   The `navigator_trackpad` diff covers BOTH navigator patches if both edits are present
   in the scratch — to keep them separate, author each against a fresh pristine checkout
   and regenerate only the relevant one.
```

- [ ] **Step 2: Commit**

```bash
git add patches/README.md
git commit -m "📝(patches): Document the two-finger-scroll patch"
```

---

## Task 5: Cursor-speed (and optional scroll) config overrides

**Files:**
- Modify: `JRZ6Q/config.h`

- [ ] **Step 1: Add the overrides**

In `JRZ6Q/config.h`, after the existing line:
```c
#define TRACKPAD_TAP_TERM_MS 0  // disable firmware tap-to-click (mouse-fallback mode); 0 = no tap qualifies
```
add:
```c

// Mode-0 (no-app) cursor speed — only active when Navigator.app is not driving the pad.
// #undef silences the benign -Wmacro-redefined (module config.h sets a default first).
#undef  TRACKPAD_MOUSE_SENSITIVITY
#define TRACKPAD_MOUSE_SENSITIVITY 0.6f    // starting point; dial in on-device (~0.5–0.8)
#undef  TRACKPAD_MOUSE_ACCELERATION
#define TRACKPAD_MOUSE_ACCELERATION 1.3f
```

> Leave `TRACKPAD_SCROLL_SENSITIVITY` at the patch default (0.10f) for now; add a
> `#define TRACKPAD_SCROLL_SENSITIVITY <value>` here only during the on-device tuning pass
> (Task 7) if scroll feels too fast/slow.

- [ ] **Step 2: Verify oryx doesn't define these (override survives the merge)**

Run:
```bash
git show origin/oryx:JRZ6Q/config.h | grep -nE "TRACKPAD_MOUSE_SENSITIVITY|TRACKPAD_MOUSE_ACCELERATION" || echo "(oryx does not define them — safe custom override)"
```
Expected: `(oryx does not define them — safe custom override)`.

- [ ] **Step 3: Commit**

```bash
git add JRZ6Q/config.h
git commit -m "🔧(qmk): Tune mode-0 cursor speed for the no-app trackpad"
```

---

## Task 6: Local integration build

**Files:** none (validation only). Requires Docker.

- [ ] **Step 1: Reproduce the build locally (apply all patches + compile)**

Run:
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
docker build -t qmk . >/tmp/scroll-docker-build.log 2>&1 && echo "image OK"
docker run -v ./qmk_firmware:/root --rm qmk /bin/sh -c "
  qmk setup zsa/qmk_firmware -b firmware${FW} -y
  sh /root/_contact_apply.sh /root/modules/zsa /root/_contact_patches || exit 1
  make zsa/voyager:JRZ6Q
" 2>&1 | tee /tmp/scroll-compile.log | grep -iE "module-patches: applied|\[OK\]|error:|\.bin"
git submodule deinit -f qmk_firmware   # restore clean tree
```
Expected: three `module-patches: applied …` lines, the compile ends with `Creating binary load file ... zsa_voyager_JRZ6Q.bin [OK]`, no `error:`.

> If Docker is unavailable, skip this task — the canary (Task 7) compiles in CI. Note the skip.

---

## Task 7: CI verification + on-device tuning (outward-facing — confirm before running)

This pushes, runs billed CI, and ends in flashing. Confirm with the user first.

- [ ] **Step 1: Push the branch**

```bash
git push -u origin feature/trackpad-two-finger-scroll
```

- [ ] **Step 2: Open a PR**

```bash
gh pr create --base main --head feature/trackpad-two-finger-scroll \
  --title "✨ Native two-finger scroll + cursor-speed tune (Phase 1)" \
  --body "Implements docs/superpowers/specs/2026-06-25-trackpad-two-finger-scroll-design.md (v2). Adds two-finger scroll to the mode-0 fallback via host_mouse_send (Option B, no core change), generalizes the apply script, and tunes cursor speed. Lets the trackpad work without Navigator.app."
```

- [ ] **Step 3: Validate the apply+compile in CI via the canary (safe, read-only)**

The canary globs `patches/` and compiles JRZ6Q with all three patches. Dispatch it on the branch — but note `workflow_dispatch` only works once the workflow exists on the default branch. Since `patch-canary.yml` is already on `main`, dispatch with `--ref`:
```bash
gh workflow run patch-canary.yml --ref feature/trackpad-two-finger-scroll
sleep 6
RID=$(gh run list --workflow patch-canary.yml --branch feature/trackpad-two-finger-scroll --limit 1 --json databaseId --jq '.[0].databaseId')
gh run watch "$RID" --exit-status
```
Expected: green — all three patches apply and JRZ6Q compiles in CI. If it can't run on the branch (404), merge first (Step 5) then dispatch on `main`.

- [ ] **Step 4: Merge the PR**

```bash
gh pr merge feature/trackpad-two-finger-scroll --merge --delete-branch
git checkout main && git pull --ff-only
```

- [ ] **Step 5: Build the flashable firmware**

```bash
gh workflow run fetch-and-build-layout.yml -f layout_id=JRZ6Q -f layout_geometry=voyager
sleep 6
RID=$(gh run list --workflow fetch-and-build-layout.yml --limit 1 --json databaseId --jq '.[0].databaseId')
gh run watch "$RID" --exit-status
gh run download "$RID" --dir /tmp/scroll-fw
find /tmp/scroll-fw -name '*.bin'
```
Expected: green build; a `zsa_voyager_JRZ6Q.bin` is downloaded. Give the user the run URL + the `.bin` path.

- [ ] **Step 6: On-device tuning (user, after flashing — with Navigator.app quit)**

Flash via Keymapp, quit Navigator.app, then verify and tune:
- Two fingers move → page scrolls. If the **direction is inverted**, flip the sign in the patch (`-raw_dy` ↔ `+raw_dy`) OR toggle macOS natural-scroll — decide which and, if firmware, regenerate the patch + rebuild.
- Scroll too fast/slow → set `#define TRACKPAD_SCROLL_SENSITIVITY <value>` in `JRZ6Q/config.h` (higher = faster) and rebuild.
- Cursor too slow/fast → tune `TRACKPAD_MOUSE_SENSITIVITY` / `TRACKPAD_MOUSE_ACCELERATION` in `JRZ6Q/config.h` and rebuild.
- One finger still moves the cursor; `W`/`E`/`R` clicks still work; taps still do nothing.
- When happy: **uninstall Navigator.app.**

> Each tuning value is a one-line `config.h` change + rebuild (no patch churn). Note: the `TRACKPAD_SCROLL_SENSITIVITY` *default* lives in the patch; only override it in `config.h`.

---

## Self-Review

**Spec coverage (v2):**
- Two-finger scroll (v+h) in mode-0 via `host_mouse_send` (Option B) → Task 2 Step 4. ✓
- Centroid (slot-swap invariant) → Task 2 Step 4 (replaces per-id matching; simpler, satisfies the slot-swap requirement). ✓
- Button preservation via `mousekey_get_report().buttons` (mandatory) → Task 2 Step 4. ✓
- Restructure (suppress slot-0 cursor when 2 fingers; per-transition reset) → Task 2 Step 4 (early `return` on `finger_count==2`; exit-scroll reset before existing logic). ✓
- Settle time + max-delta clamp → Task 2 Step 4. ✓
- `reset_mouse_state` resets scroll state → Task 2 Step 3. ✓
- `TRACKPAD_SCROLL_SENSITIVITY` `#ifndef` → Task 2 Step 1. ✓
- Cursor speed `config.h` override with `#undef` (redefinition) → Task 5. ✓
- Generalized apply script (glob, portable grep sentinel, nullglob guard, keep `CONTACT_PATCH_APPLY_FAILED`) → Task 3. ✓
- Two patches same file apply cleanly → Task 2 Step 6. ✓
- README/comment update → Task 4 + Task 3 (script comments rewritten). ✓
- No workflow change needed (build/canary glob the dir) → confirmed; Task 7 uses them unchanged. ✓
- Auto-mouse-layer-activates-on-scroll accepted/deferred → no code (Phase 1 accepts it); documented in spec. ✓
- Verification ladder (apply / compile / on-device) → Tasks 2-3 tests, Task 6, Task 7. ✓

**Placeholder scan:** none — every code/CI step has complete content + expected output. (The Task 7 on-device tuning values are deliberately ranges the user dials in, not placeholders.)

**Type/name consistency:** `scroll_state` fields (`active/settled/start_time/prev_cx/prev_cy/v_accum/h_accum`) defined in Task 2 Step 2 and used consistently in Steps 3-4; `TRACKPAD_SCROLL_SENSITIVITY` defined (2.1) and used (2.4) and overridable (5); `host_mouse_send`/`mousekey_get_report`/`clamp_to_int8`/`TRACKPAD_MAX_DELTA` are existing symbols used as-is; sentinel strings in the apply script (3.1) match the symbols the patches introduce (`AUTOMOUSE_CONTACT_STALE_MS`, `automouse_report_contact(cur_n`, `TRACKPAD_SCROLL_SENSITIVITY`); `CONTACT_PATCH_APPLY_FAILED` marker preserved (canary greps it). ✓

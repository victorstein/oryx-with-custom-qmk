# Trackpad Contact Keep-Alive Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep the ZSA Voyager auto-mouse layer alive while a finger rests motionless on the Navigator trackpad, by patching the `automouse` + `navigator_trackpad` community modules at CI build time, with a weekly canary that alerts when the patch stops applying.

**Architecture:** Two additive patches to `zsa/qmk_modules` (the modules are fetched fresh during CI, not committed here). A shared POSIX `apply` script applies them inside the build's Docker container after `qmk setup` and before `make`. A separate weekly read-only canary workflow reproduces the exact build resolution, runs the same apply+compile path, and opens/updates a GitHub issue on failure. No `keymap.c` changes.

**Tech Stack:** QMK community modules (C), GitHub Actions (YAML), Debian Docker image, POSIX `sh`, `patch(1)`, `gh` CLI.

**Spec:** `docs/superpowers/specs/2026-06-25-trackpad-contact-keepalive-design.md` (v3).

**Build target (resolved, authoritative):** layout `JRZ6Q` / `voyager` → Oryx `qmkVersion 25.0` → branch **`firmware25`** → `modules/zsa` gitlink **`2e0fc66b0f2102ff899e0d985a5be65283fe7578`** (currently byte-identical to `qmk_modules` `main`). Author all patches against this SHA.

**Key facts for the implementer:**
- `NAVIGATOR_TRACKPAD_POLL_INTERVAL_MS = 5`; lift-off confirm ≈ 3 frames ≈ 15 ms. So `AUTOMOUSE_CONTACT_STALE_MS = 120` is safely above contact cadence and far below `AUTOMOUSE_TIMEOUT = 650`.
- The trackpad already `#include <automouse.h>` under `#if COMMUNITY_MODULE_AUTOMOUSE_ENABLE == TRUE` (ptp.c:19-20). The new call must live inside that same `#if` block (it does — the existing motion-feed block at ptp.c:465-489 is already guarded).
- The Debian build image does **not** ship `patch(1)` — it must be added to the Dockerfile.
- The build workflow (`fetch-and-build-layout.yml`) fetches Oryx, merges to `main`, **pushes**, then builds — so do **not** test the modified build workflow by dispatching it from a branch (it would mutate `main`). The **canary** (read-only) is the safe CI test of the apply mechanism, which mirrors the build's docker path exactly.

---

## File Structure

| Path | Create/Modify | Responsibility |
|---|---|---|
| `patches/automouse-contact.patch` | Create | Adds `automouse_report_contact` + contact keep-alive to the automouse module |
| `patches/navigator-trackpad-contact.patch` | Create | Feeds finger-presence (`cur_n > 0`) from the trackpad to automouse |
| `patches/README.md` | Create | Records the pinned SHA + how to refresh a patch when it stops applying |
| `scripts/apply-contact-patches.sh` | Create | Shared applier: guard + idempotency sentinel + loud-failing `patch -p1` loop. Used by the build, the canary, and locally |
| `Dockerfile` | Modify | Add `patch` to the apt install list |
| `.github/workflows/fetch-and-build-layout.yml` | Modify | Stage patches (JRZ6Q + fw≥24) and apply them in-container after `qmk setup`, before `make` |
| `.github/workflows/patch-canary.yml` | Create | Weekly read-only canary: reproduce build resolution → apply + compile → file/update issue on failure |

---

## Task 1: Branch + scaffolding + pinned scratch checkout

**Files:**
- Create: `patches/README.md`
- (working dir) a scratch clone of `zsa/qmk_modules` at the pinned SHA, used to author and verify patches

- [ ] **Step 1: Create the feature branch**

Run:
```bash
cd /Volumes/stein/Documents/development/personal/oryx-with-custom-qmk
git checkout -b feature/trackpad-contact-keepalive
```
Expected: `Switched to a new branch 'feature/trackpad-contact-keepalive'`

- [ ] **Step 2: Clone qmk_modules at the pinned SHA into a scratch dir**

This is the authoritative source the patches target. Keep it for Tasks 2-4.

Run:
```bash
SCRATCH=/private/tmp/claude-501/-Volumes-stein-Documents-development-personal-oryx-with-custom-qmk/7a8c34fa-230d-422e-8365-da0318d12917/scratchpad
mkdir -p "$SCRATCH"
git clone https://github.com/zsa/qmk_modules.git "$SCRATCH/qmk_modules"
git -C "$SCRATCH/qmk_modules" checkout 2e0fc66b0f2102ff899e0d985a5be65283fe7578
git -C "$SCRATCH/qmk_modules" rev-parse HEAD
```
Expected: final line prints `2e0fc66b0f2102ff899e0d985a5be65283fe7578`.

- [ ] **Step 3: Create `patches/README.md`**

```markdown
# Module patches (trackpad contact keep-alive)

These patches add finger-contact keep-alive to the ZSA community modules so the
auto-mouse layer stays warm while a finger rests motionless on the trackpad. They are
applied at **CI build time** to `qmk_firmware/modules/zsa/...` — the module source is
fetched fresh per build and is not committed in this repo. See
`docs/superpowers/specs/2026-06-25-trackpad-contact-keepalive-design.md`.

- `automouse-contact.patch` → `automouse/automouse.{h,c}`
- `navigator-trackpad-contact.patch` → `navigator_trackpad/navigator_trackpad_ptp.c`

## Authored against

Repo `zsa/qmk_modules`, commit `2e0fc66b0f2102ff899e0d985a5be65283fe7578`
(pinned by `zsa/qmk_firmware@firmware25`).

## Refreshing a patch when CI/canary reports it no longer applies

1. Clone the modules at the SHA the build now uses:
   `git clone https://github.com/zsa/qmk_modules.git /tmp/qm && cd /tmp/qm`
   (find the SHA: `gh api repos/zsa/qmk_firmware/contents/modules/zsa?ref=firmware<NN> --jq .sha`)
2. Re-apply the edits documented in `docs/superpowers/plans/2026-06-25-trackpad-contact-keepalive.md`
   (Tasks 2-3) by hand against the new source.
3. Regenerate: `git diff -- automouse > .../patches/automouse-contact.patch`
   and `git diff -- navigator_trackpad > .../patches/navigator-trackpad-contact.patch`.
4. Update the "Authored against" SHA above.
5. Verify locally: `scripts/apply-contact-patches.sh <modules/zsa dir> patches` exits 0.
```

- [ ] **Step 4: Commit the scaffolding**

```bash
git add patches/README.md
git commit -m "📝(patches): Document trackpad contact keep-alive patch set + refresh steps"
```

---

## Task 2: Author `patches/automouse-contact.patch`

**Files:**
- Edit (scratch): `$SCRATCH/qmk_modules/automouse/automouse.h`, `.../automouse/automouse.c`
- Create: `patches/automouse-contact.patch`

This task edits the scratch source to the exact target state, then generates the patch from the diff. The "test" is that the generated patch re-applies cleanly to a pristine copy (Step 6).

- [ ] **Step 1: Edit `automouse.h` — declare the new API**

In `$SCRATCH/qmk_modules/automouse/automouse.h`, the file currently ends at line 47:
```c
// Feed motion from a sensor that bypasses the QMK pointing-device pipeline
// (e.g. a digitizer/trackpad) so it can activate the mouse layer.
void automouse_report_motion(int16_t dx, int16_t dy, uint8_t buttons);
```
Append immediately after line 47:
```c

// Feed finger-contact presence from a sensor that bypasses the QMK pointing-device
// pipeline (e.g. a digitizer/trackpad) so a motionless-but-present finger keeps the
// mouse layer warm while it is active.
void automouse_report_contact(bool finger_present);
```

- [ ] **Step 2: Edit `automouse.c` — add the contact statics**

In `$SCRATCH/qmk_modules/automouse/automouse.c`, the `state` struct initializer ends at line 26:
```c
} state = {
    .is_enabled = true,
};
```
Insert immediately after line 26 (before the next item):
```c

#ifndef AUTOMOUSE_CONTACT_STALE_MS
#    define AUTOMOUSE_CONTACT_STALE_MS 120  // finger-contact freshness window (ms)
#endif
static bool     finger_present = false;
static uint16_t last_contact   = 0;
```

- [ ] **Step 3: Edit `automouse.c` — gate the keep-alive on the real layer**

Replace the existing keep-alive block (lines 135-138):
```c
    // Keep layer alive while keys are held on it
    if (state.is_active && state.held_keys > 0) {
        state.last_activity = timer_read();
    }
```
with:
```c
    // Keep the layer alive while keys are held on it, or while a finger rests in contact.
    // The contact term is gated on the layer ACTUALLY being on (layer_state_is), so a
    // layer the keymap typed-off is never kept warm — its normal 650ms timeout/reset runs.
    if (state.is_active &&
        (state.held_keys > 0 ||
         (layer_state_is(AUTOMOUSE_LAYER) && finger_present &&
          timer_elapsed(last_contact) < AUTOMOUSE_CONTACT_STALE_MS))) {
        state.last_activity = timer_read();
    }
```

- [ ] **Step 4: Edit `automouse.c` — append the setter**

At the end of `$SCRATCH/qmk_modules/automouse/automouse.c` (after the final `}` at line 209), append:
```c

void automouse_report_contact(bool present) {
    if (!state.is_enabled) {
        return;
    }
    finger_present = present;
    if (present) {
        last_contact = timer_read();
    }
}
```

- [ ] **Step 5: Generate the patch**

Run:
```bash
git -C "$SCRATCH/qmk_modules" diff -- automouse > patches/automouse-contact.patch
head -5 patches/automouse-contact.patch
```
Expected: starts with `diff --git a/automouse/automouse.c b/automouse/automouse.c` (or `automouse.h` first), and `patches/automouse-contact.patch` is non-empty.

- [ ] **Step 6: Test — the patch applies cleanly to pristine source**

Run:
```bash
rm -rf /tmp/qm-verify && git clone -q https://github.com/zsa/qmk_modules.git /tmp/qm-verify
git -C /tmp/qm-verify checkout -q 2e0fc66b0f2102ff899e0d985a5be65283fe7578
patch -p1 -d /tmp/qm-verify --dry-run < patches/automouse-contact.patch
```
Expected: two `checking file automouse/automouse.h` / `checking file automouse/automouse.c` lines, no `FAILED`/`hunk` errors; exit status 0 (`echo $?` → `0`).

- [ ] **Step 7: Commit**

```bash
git add patches/automouse-contact.patch
git commit -m "✨(patches): Add automouse contact keep-alive patch (gated on layer_state_is)"
```

---

## Task 3: Author `patches/navigator-trackpad-contact.patch`

**Files:**
- Edit (scratch): `$SCRATCH/qmk_modules/navigator_trackpad/navigator_trackpad_ptp.c`
- Create: `patches/navigator-trackpad-contact.patch`

- [ ] **Step 1: Edit `navigator_trackpad_ptp.c` — feed contact to automouse**

In `$SCRATCH/qmk_modules/navigator_trackpad/navigator_trackpad_ptp.c`, the automouse-feed block (inside `#if COMMUNITY_MODULE_AUTOMOUSE_ENABLE == TRUE`) currently reads (lines 472-477):
```c
    {
        static int16_t  am_prev_id = -1;
        static uint16_t am_prev_x  = 0;
        static uint16_t am_prev_y  = 0;
        if (cur_n > 0) {
```
Insert the contact call after the three `static` declarations and before `if (cur_n > 0)`:
```c
    {
        static int16_t  am_prev_id = -1;
        static uint16_t am_prev_x  = 0;
        static uint16_t am_prev_y  = 0;

        // Keep the auto-mouse layer warm while any finger rests on the pad, even at zero
        // motion delta (a still finger would otherwise look like "no finger" to automouse).
        automouse_report_contact(cur_n > 0);

        if (cur_n > 0) {
```

- [ ] **Step 2: Generate the patch**

Run:
```bash
git -C "$SCRATCH/qmk_modules" diff -- navigator_trackpad > patches/navigator-trackpad-contact.patch
head -5 patches/navigator-trackpad-contact.patch
```
Expected: starts with `diff --git a/navigator_trackpad/navigator_trackpad_ptp.c ...`; file non-empty.

- [ ] **Step 3: Test — the patch applies cleanly to pristine source**

Run:
```bash
rm -rf /tmp/qm-verify && git clone -q https://github.com/zsa/qmk_modules.git /tmp/qm-verify
git -C /tmp/qm-verify checkout -q 2e0fc66b0f2102ff899e0d985a5be65283fe7578
patch -p1 -d /tmp/qm-verify --dry-run < patches/navigator-trackpad-contact.patch
echo "exit=$?"
```
Expected: `checking file navigator_trackpad/navigator_trackpad_ptp.c`, no errors, `exit=0`.

- [ ] **Step 4: Commit**

```bash
git add patches/navigator-trackpad-contact.patch
git commit -m "✨(patches): Feed finger-presence from navigator_trackpad to automouse"
```

---

## Task 4: Shared apply script

**Files:**
- Create: `scripts/apply-contact-patches.sh`

- [ ] **Step 1: Write a failing test invocation (script does not exist yet)**

Run:
```bash
sh scripts/apply-contact-patches.sh /tmp/none patches; echo "exit=$?"
```
Expected: FAIL — `sh: ... No such file or directory` (script not created yet).

- [ ] **Step 2: Create `scripts/apply-contact-patches.sh`**

```sh
#!/bin/sh
# Apply the trackpad contact-keepalive patches to the ZSA community modules in-tree.
# Usage: apply-contact-patches.sh <modules_zsa_dir> <patches_dir>
#
# Exit 0  = patches applied, OR safely skipped (modules absent / upstream already ships
#           the API). Skips print a ::notice:: and are NOT failures.
# Exit 1  = a patch failed to apply. Prints the marker CONTACT_PATCH_APPLY_FAILED (so the
#           canary can distinguish an apply failure from a later compile failure) plus a
#           GitHub ::error:: annotation.
set -eu

MODULES_DIR="${1:?usage: apply-contact-patches.sh <modules_zsa_dir> <patches_dir>}"
PATCHES_DIR="${2:?usage: apply-contact-patches.sh <modules_zsa_dir> <patches_dir>}"
SENTINEL="automouse_report_contact"

# Guard: only act when the ZSA modules are actually present (other geometries/layouts and
# legacy firmware <24 don't have them — build those untouched).
if [ ! -d "$MODULES_DIR/automouse" ] || [ ! -d "$MODULES_DIR/navigator_trackpad" ]; then
  echo "::notice::contact-keepalive: ZSA modules not found at $MODULES_DIR — skipping."
  exit 0
fi

# Idempotency: if upstream already defines the API (shipped it natively, or we already
# applied), skip rather than fail or double-apply.
if grep -q "$SENTINEL" "$MODULES_DIR/automouse/automouse.h" 2>/dev/null; then
  echo "::notice::contact-keepalive: upstream already defines $SENTINEL — skipping (retire the patch)."
  exit 0
fi

for name in automouse-contact.patch navigator-trackpad-contact.patch; do
  p="$PATCHES_DIR/$name"
  if [ ! -f "$p" ]; then
    echo "CONTACT_PATCH_APPLY_FAILED ::error::contact-keepalive: missing patch file $p"
    exit 1
  fi
  if ! patch -p1 -d "$MODULES_DIR" --dry-run < "$p" >/dev/null 2>&1; then
    echo "CONTACT_PATCH_APPLY_FAILED ::error::contact-keepalive: $name does not apply against the current qmk_modules — refresh it (see patches/README.md)."
    exit 1
  fi
  patch -p1 -d "$MODULES_DIR" < "$p" >/dev/null
  echo "contact-keepalive: applied $name"
done
echo "contact-keepalive: all patches applied to $MODULES_DIR"
```

- [ ] **Step 3: Make it executable + test the modules-absent skip**

Run:
```bash
chmod +x scripts/apply-contact-patches.sh
sh scripts/apply-contact-patches.sh /tmp/none patches; echo "exit=$?"
```
Expected: `::notice::contact-keepalive: ZSA modules not found ...` then `exit=0`.

- [ ] **Step 4: Test the happy path against a pristine checkout**

Run:
```bash
rm -rf /tmp/qm-apply && git clone -q https://github.com/zsa/qmk_modules.git /tmp/qm-apply
git -C /tmp/qm-apply checkout -q 2e0fc66b0f2102ff899e0d985a5be65283fe7578
sh scripts/apply-contact-patches.sh /tmp/qm-apply patches; echo "exit=$?"
```
Expected:
```
contact-keepalive: applied automouse-contact.patch
contact-keepalive: applied navigator-trackpad-contact.patch
contact-keepalive: all patches applied to /tmp/qm-apply
exit=0
```

- [ ] **Step 5: Test idempotency (re-run on already-patched tree → skip)**

Run:
```bash
sh scripts/apply-contact-patches.sh /tmp/qm-apply patches; echo "exit=$?"
```
Expected: `::notice::contact-keepalive: upstream already defines automouse_report_contact — skipping ...` then `exit=0`.

- [ ] **Step 6: Test loud failure on a broken patch**

Run:
```bash
rm -rf /tmp/qm-break && git clone -q https://github.com/zsa/qmk_modules.git /tmp/qm-break
git -C /tmp/qm-break checkout -q 2e0fc66b0f2102ff899e0d985a5be65283fe7578
mkdir -p /tmp/badpatches && cp patches/*.patch /tmp/badpatches/
# Corrupt a context line so the hunk can't locate its anchor:
sed -i.bak 's/Keep the layer alive while keys are held/THIS WILL NOT MATCH ANYTHING/' /tmp/badpatches/automouse-contact.patch
sh scripts/apply-contact-patches.sh /tmp/qm-break /tmp/badpatches; echo "exit=$?"
```
Expected: a line containing `CONTACT_PATCH_APPLY_FAILED` and `::error::contact-keepalive: automouse-contact.patch does not apply ...`, then `exit=1`.

- [ ] **Step 7: Commit**

```bash
git add scripts/apply-contact-patches.sh
git commit -m "✨(scripts): Add shared contact-keepalive patch applier (guard + sentinel + loud fail)"
```

---

## Task 5: Add `patch` to the Docker image

**Files:**
- Modify: `Dockerfile`

- [ ] **Step 1: Add `patch` to the apt install list**

In `Dockerfile`, the install block currently reads:
```dockerfile
RUN apt-get update && apt-get install -y \
    git \
    python3 \
    python3-pip \
    sudo \
    build-essential \
    gcc-arm-none-eabi \
    libnewlib-arm-none-eabi \
    avrdude \
    dfu-util
```
Add `patch` (alphabetically near the top, after `git`):
```dockerfile
RUN apt-get update && apt-get install -y \
    git \
    patch \
    python3 \
    python3-pip \
    sudo \
    build-essential \
    gcc-arm-none-eabi \
    libnewlib-arm-none-eabi \
    avrdude \
    dfu-util
```

- [ ] **Step 2: Verify the image builds and `patch` is present** (requires Docker)

Run:
```bash
docker build -t qmk-test . && docker run --rm qmk-test sh -c "patch --version | head -1"
```
Expected: image builds; final line prints e.g. `GNU patch 2.7.6`.

> If Docker is unavailable on this machine, skip Step 2 — the canary (Task 7) compiles in CI and will exercise `patch` there. Note the skip in the commit body.

- [ ] **Step 3: Commit**

```bash
git add Dockerfile
git commit -m "🔧(docker): Install patch(1) for in-container module patching"
```

---

## Task 6: Wire the apply step into the build workflow

**Files:**
- Modify: `.github/workflows/fetch-and-build-layout.yml` (the `Build the layout` step, lines 95-120)

- [ ] **Step 1: Replace the `Build the layout` step body**

Replace the entire `run: |` body of the `Build the layout` step with this (additions: a `fw` var, the patch-staging block, and the in-container apply line):
```yaml
      - name: Build the layout
        id: build-layout
        run: |
          fw="${{ steps.download-layout-source.outputs.firmware_version }}"
          # Set keyboard directory and make prefix based on firmware version
          if [ "$fw" -ge 24 ]; then
            keyboard_directory="qmk_firmware/keyboards/zsa"
            make_prefix="zsa/"
          else
            keyboard_directory="qmk_firmware/keyboards"
            make_prefix=""
          fi

          # Copy layout files to the qmk folder
          rm -rf ${keyboard_directory}/${{ github.event.inputs.layout_geometry }}/keymaps/${{ github.event.inputs.layout_id }}
          mkdir -p ${keyboard_directory}/${{ github.event.inputs.layout_geometry }}/keymaps && cp -r ${{ github.event.inputs.layout_id }} "$_"

          # Stage the trackpad contact-keepalive patches for in-container apply.
          # Only for JRZ6Q + firmware>=24; the apply script also self-skips if the ZSA
          # modules are absent, so any other geometry/layout builds untouched.
          rm -rf qmk_firmware/_contact_patches qmk_firmware/_contact_apply.sh
          if [ "${{ github.event.inputs.layout_id }}" = "JRZ6Q" ] && [ "$fw" -ge 24 ]; then
            cp -r patches qmk_firmware/_contact_patches
            cp scripts/apply-contact-patches.sh qmk_firmware/_contact_apply.sh
            echo "Staged contact-keepalive patches"
          fi

          # Build the layout. The patch apply runs AFTER qmk setup (which may re-sync the
          # modules submodule) and BEFORE make; `|| exit 1` makes an apply failure fail the
          # build (no artifact) rather than silently shipping unpatched firmware.
          docker run -v ./qmk_firmware:/root --rm qmk /bin/sh -c "
            qmk setup zsa/qmk_firmware -b firmware${fw} -y
            if [ -d /root/_contact_patches ]; then
              sh /root/_contact_apply.sh /root/modules/zsa /root/_contact_patches || exit 1
            fi
            make ${make_prefix}${{ github.event.inputs.layout_geometry }}:${{ github.event.inputs.layout_id }}
          "

          # Find and export built layout
          normalized_layout_geometry="$(echo "${{ github.event.inputs.layout_geometry }}" | sed 's/\//_/g')"
          echo built_layout_file=$(find ./qmk_firmware -maxdepth 1 -type f -regex ".*${normalized_layout_geometry}.*\.\(bin\|hex\)$") >> "$GITHUB_OUTPUT"
          echo normalized_layout_geometry=${normalized_layout_geometry} >> "$GITHUB_OUTPUT"
```

- [ ] **Step 2: Lint the YAML**

Run:
```bash
python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/fetch-and-build-layout.yml')); print('YAML OK')"
```
Expected: `YAML OK`.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/fetch-and-build-layout.yml
git commit -m "👷(ci): Apply contact-keepalive patches in-container during the build"
```

> Note: do NOT dispatch this workflow from the feature branch to test it — it pushes to `main`. The canary (Task 7) validates the identical apply+compile path safely.

---

## Task 7: Weekly canary workflow

**Files:**
- Create: `.github/workflows/patch-canary.yml`

- [ ] **Step 1: Create the canary workflow**

```yaml
name: Patch canary

on:
  schedule:
    - cron: '0 6 * * 1'   # Mondays 06:00 UTC — bump/retune freely
  workflow_dispatch: {}

permissions:
  contents: read
  issues: write

jobs:
  canary:
    runs-on: ubuntu-latest
    env:
      ISSUE_TITLE: "🔴 contact-keepalive patch canary failing"
    steps:
      - name: Checkout
        uses: actions/checkout@v4
        with:
          submodules: false

      - name: Resolve firmware version from Oryx (same source as the build)
        id: fw
        run: |
          v=$(curl -s 'https://oryx.zsa.io/graphql' \
                --header 'Content-Type: application/json' \
                --data '{"query":"query getLayout($hashId: String!, $geometry: String) { layout(hashId: $hashId, geometry: $geometry, revisionId: \"latest\") { revision { qmkVersion } } }","variables":{"hashId":"JRZ6Q","geometry":"voyager"}}' \
                | jq -r '.data.layout.revision.qmkVersion' 2>/dev/null)
          fw=$(printf "%.0f" "$v" 2>/dev/null || echo "")
          if ! [ "$fw" -ge 24 ] 2>/dev/null; then fw=25; fi
          echo "fw=$fw" >> "$GITHUB_OUTPUT"
          echo "Resolved firmware branch: firmware$fw"

      - name: Resolve modules exactly as the build does (firmwareXX pin, no --remote)
        run: |
          fw="${{ steps.fw.outputs.fw }}"
          git submodule update --init --depth=1 qmk_firmware
          cd qmk_firmware
          git fetch --depth=1 origin "firmware${fw}"
          git checkout -B "firmware${fw}" "origin/firmware${fw}"
          git submodule update --init --recursive
          cd ..

      - name: Stage layout + patches (mirror the build)
        run: |
          mkdir -p qmk_firmware/keyboards/zsa/voyager/keymaps
          rm -rf qmk_firmware/keyboards/zsa/voyager/keymaps/JRZ6Q
          cp -r JRZ6Q qmk_firmware/keyboards/zsa/voyager/keymaps/JRZ6Q
          cp -r patches qmk_firmware/_contact_patches
          cp scripts/apply-contact-patches.sh qmk_firmware/_contact_apply.sh

      - name: Build qmk docker image
        run: docker build -t qmk .

      - name: Apply patches + compile (classify failure phase)
        id: build
        run: |
          fw="${{ steps.fw.outputs.fw }}"
          set +e
          docker run -v ./qmk_firmware:/root --rm qmk /bin/sh -c "
            qmk setup zsa/qmk_firmware -b firmware${fw} -y
            sh /root/_contact_apply.sh /root/modules/zsa /root/_contact_patches || exit 1
            make zsa/voyager:JRZ6Q
          " 2>&1 | tee build.log
          rc=${PIPESTATUS[0]}
          set -e
          if [ "$rc" -ne 0 ]; then
            if grep -q CONTACT_PATCH_APPLY_FAILED build.log; then
              echo "phase=apply" >> "$GITHUB_OUTPUT"
            else
              echo "phase=compile" >> "$GITHUB_OUTPUT"
            fi
          fi
          echo "rc=$rc" >> "$GITHUB_OUTPUT"
          exit 0

      - name: Open or update the alert issue on failure
        if: steps.build.outputs.rc != '0'
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          phase="${{ steps.build.outputs.phase }}"
          run_url="${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}"
          if [ "$phase" = "apply" ]; then
            body="The contact-keepalive **patch no longer applies** against the current \`modules/zsa\` (firmware${{ steps.fw.outputs.fw }} pin). Refresh the patch context per \`patches/README.md\`. Run: $run_url"
          else
            body="The contact-keepalive patches **apply but the firmware no longer compiles** (likely an upstream symbol/signature change). Investigate the patched code. Run: $run_url"
          fi
          existing=$(gh issue list --search "in:title \"$ISSUE_TITLE\" is:open" --json number --jq '.[0].number' 2>/dev/null || echo "")
          if [ -n "$existing" ]; then
            gh issue comment "$existing" --body "$body"
          else
            gh issue create --title "$ISSUE_TITLE" --body "$body"
          fi

      - name: Fail the job (also triggers GitHub's scheduled-failure email)
        if: steps.build.outputs.rc != '0'
        run: exit 1
```

- [ ] **Step 2: Lint the YAML**

Run:
```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/patch-canary.yml')); print('YAML OK')"
```
Expected: `YAML OK`.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/patch-canary.yml
git commit -m "👷(ci): Add weekly read-only canary for the contact-keepalive patch"
```

---

## Task 8: CI verification + finalize

The canary is the safe, authoritative CI test of the apply+compile path. The scheduled
trigger only fires from the default branch, but `workflow_dispatch` lets us run it from a
branch via the API.

- [ ] **Step 1: Push the branch**

```bash
git push -u origin feature/trackpad-contact-keepalive
```

- [ ] **Step 2: Dispatch the canary against the feature branch (positive run)**

Run:
```bash
gh workflow run patch-canary.yml --ref feature/trackpad-contact-keepalive
sleep 5 && gh run list --workflow patch-canary.yml --branch feature/trackpad-contact-keepalive --limit 1
```
Then watch it:
```bash
gh run watch "$(gh run list --workflow patch-canary.yml --branch feature/trackpad-contact-keepalive --limit 1 --json databaseId --jq '.[0].databaseId')" --exit-status
```
Expected: the run completes **green** (patches apply + `make zsa/voyager:JRZ6Q` compiles). Exit status 0. No alert issue created.

- [ ] **Step 3: Negative test — confirm a broken patch is detected and reported**

Temporarily break a patch on a throwaway branch, dispatch, confirm the canary fails with `phase=apply` and files/updates the issue:
```bash
git checkout -b tmp/canary-negative
sed -i.bak 's/finger-contact freshness window/BROKEN CONTEXT LINE/' patches/automouse-contact.patch && rm -f patches/automouse-contact.patch.bak
git commit -am "test: deliberately break patch to exercise canary alert"
git push -u origin tmp/canary-negative
gh workflow run patch-canary.yml --ref tmp/canary-negative
```
Watch the run; expected: it **fails**, and:
```bash
gh issue list --search 'in:title "contact-keepalive patch canary failing" is:open'
```
shows the alert issue. Then clean up:
```bash
git checkout feature/trackpad-contact-keepalive
git push origin --delete tmp/canary-negative
git branch -D tmp/canary-negative
# Close the test issue:
gh issue list --search 'in:title "contact-keepalive patch canary failing" is:open' --json number --jq '.[0].number' | xargs -r gh issue close
```
Expected: alert issue existed (proving the path works), then closed.

- [ ] **Step 4: Open the PR**

```bash
gh pr create --title "✨ Trackpad contact keep-alive (resting finger keeps the mouse layer warm)" \
  --body "Implements docs/superpowers/specs/2026-06-25-trackpad-contact-keepalive-design.md (v3).

- Two CI-applied patches to zsa/qmk_modules (automouse + navigator_trackpad)
- Shared apply script (guard + idempotency sentinel + loud fail)
- Dockerfile: add patch(1)
- Build workflow: stage + in-container apply (JRZ6Q + fw>=24, self-skipping otherwise)
- Weekly read-only canary that opens/updates a GitHub issue when the patch stops applying

Verified: canary green on this branch (patches apply + compile); negative test confirmed the alert path."
```

- [ ] **Step 5: Final on-device verification (after merge + next firmware build)**

After merging and running the real **Fetch and build layout** Action, flash the artifact and confirm on-device:
- Rest a finger motionless on the trackpad → `W`/`E`/`R` stay clicks beyond 650ms (layer stays warm).
- Lift the finger → layer drops ~650ms later.
- While warm, type a non-click key with a finger still resting → layer drops instantly and does **not** resurrect.

---

## Self-Review

**Spec coverage (v3):**
- Behavior "alive while touching", motion-to-activate unchanged → Task 2 Steps 2-4 (statics, layer-gated keep-alive, setter) + Task 3 (contact feed). ✓
- Self-decaying contact (`AUTOMOUSE_CONTACT_STALE_MS=120`) → Task 2 Steps 2-3. ✓
- Layer-state gating (not `is_active`, not reconcile) → Task 2 Step 3. ✓
- Patch-files delivery, recorded SHA → Task 1 (README) + Tasks 2-3. ✓
- `patch -p1` in-container after `qmk setup`, before `make` → Task 6. ✓
- `patch(1)` missing from image → Task 5. ✓
- Guard (JRZ6Q + fw≥24 + modules-exist, skip-with-notice) → Task 4 script + Task 6 staging. ✓
- Idempotency sentinel → Task 4 script + Task 4 Step 5. ✓
- Loud failure / no silent stale ship → Task 4 script + Task 6 `|| exit 1` + Task 4 Step 6. ✓
- Weekly canary, exact firmwareXX resolution, dedup issue, apply-vs-compile classification, native email → Task 7. ✓
- Blast-radius containment (other geometries untouched) → Task 4 guard + Task 6 conditional staging. ✓
- No keymap.c/config/LED changes → no task touches them. ✓

**Placeholder scan:** none — every code block is complete, every command has expected output.

**Type/name consistency:** `automouse_report_contact(bool)` declared (Task 2.1), defined (Task 2.4), called (Task 3.1); `finger_present`/`last_contact`/`AUTOMOUSE_CONTACT_STALE_MS` defined and used in the same Task 2 block; `scripts/apply-contact-patches.sh` signature `<modules_zsa_dir> <patches_dir>` consistent across Task 4, Task 6, Task 7; sentinel marker `CONTACT_PATCH_APPLY_FAILED` emitted (Task 4) and grepped (Task 7). ✓

---

## Implementation deltas (applied during subagent review, vs. the task text above)

Recorded for accuracy — the committed code reflects these; the task code blocks above predate them:

- **Task 2 (automouse.h):** the `automouse_report_contact` declaration parameter is `bool present` (matches the definition), not `bool finger_present` — avoids visually shadowing the file-static `finger_present`. (Code-quality, Minor.)
- **Task 4 (apply script):** in each failure branch the marker and the annotation are emitted on **separate lines** (`echo "CONTACT_PATCH_APPLY_FAILED"` then `echo "::error::..."`) — GitHub Actions only parses `::error::`/`::notice::` when it begins a line. Also the real apply is wrapped `if ! patch ...; then <marker+error>; exit 1; fi` so a post-dry-run failure still emits the marker. (Code-quality, Important + hardening.)
- **Task 4 Step 6 (test):** the corruption `sed` must target a real **context** line (e.g. `s/static bool layer_held_externally/.../`), not an added (`+`) line, to actually break the dry-run.
- **Task 6 (build workflow):** the in-container apply adds an `elif [ "${{ github.event.inputs.layout_id }}" = "JRZ6Q" ] && [ "${fw}" -ge 24 ]; then echo "::error::...staged patches missing..."; exit 1; fi` so that if the staged patches ever vanish before apply (e.g. a future `qmk setup` cleaning the volume) the build fails loudly instead of silently shipping unpatched. (Code-quality, Minor hardening.)
- **Task 7 (canary):** two runtime fixes for the default `bash -e -o pipefail` shell — (1) `|| true` on the `v=$(curl | jq ...)` firmware-resolution assignment so an Oryx outage falls back to `fw=25` instead of aborting (which would file a spurious issue); (2) the dedup jq filter is `.[0].number // empty` (not `.[0].number`) so an empty issue list yields `existing=""` and the **first** alert issue is actually created (bare `.[0].number` prints the string `null`). (Code-quality, Critical + Important.)

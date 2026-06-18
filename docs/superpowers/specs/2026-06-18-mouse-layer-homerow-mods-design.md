# Mouse layer: move clicks off the home row — design

**Date:** 2026-06-18
**Keyboard:** ZSA Voyager (`JRZ6Q`), Oryx + custom-QMK hybrid, Navigator trackpad.
**Host:** macOS.
**Supersedes:** the layer-5 keymap edits in `2026-06-15-trackpad-layer-and-zoom-design.md`
(the `G`=⇧ and inner-thumb=⌃ additions). The `layer_state_set_user()` from that
design is unchanged and still in force.

## Problem

On the auto-mouse layer (`AUTOMOUSE_LAYER = 5`) the click buttons sit on the left
home row: `S` = middle, `D` = right, `F` = left. Those are exactly the user's
left-hand home-row modifiers (`S`=⌥, `D`=⌃, `F`=⇧). So while the trackpad keeps the
mouse layer warm, common modifier combos done with the left hand
(`⌃+⌥`, `⌃+<anything>`, `⌥+<anything>`, `⇧+<anything>`) misfire as mouse clicks.
The right hand is unaffected (its home-row mods are transparent on layer 5 and fall
through to the base mod-taps). `⌘` (on `A`) was already fine for the same reason —
`A` is transparent on layer 5 — which is why cmd was never part of the problem.

## Decision

Move the three mouse buttons **off the home row and onto the top row**, and revert
the home row + the task-4 helper keys to transparent. Then the home row falls
through to the base home-row mod-taps and all left-hand modifiers work while mousing.

Rejected alternative — **dual-role home-row keys** (tap = click, hold = modifier):
it would keep clicks on `S/D/F`, but holding a click key would become a modifier
instead of a held mouse button, **breaking click-and-drag** (a hard requirement).
Moving the buttons avoids tap/hold ambiguity entirely and keeps plain
press-and-hold drag.

## Design — `JRZ6Q/keymap.c`, layer 5 only

### Keymap-array edits

| Row | Key | From → To |
|---|---|---|
| Top | `W` | `KC_TRANSPARENT` → `KC_MS_BTN3` (middle click) |
| Top | `E` | `KC_TRANSPARENT` → `KC_MS_BTN2` (right click) |
| Top | `R` | `KC_TRANSPARENT` → `KC_MS_BTN1` (left click) |
| Home | `S` | `KC_MS_BTN3` → `KC_TRANSPARENT` |
| Home | `D` | `KC_MS_BTN2` → `KC_TRANSPARENT` |
| Home | `F` | `KC_MS_BTN1` → `KC_TRANSPARENT` |
| Home | `G` | `KC_LEFT_SHIFT` → `KC_TRANSPARENT` |
| Thumb | inner-left | `KC_LEFT_CTRL` → `KC_TRANSPARENT` |

`T` stays transparent (no fourth button). Mapping preserves finger→button muscle
memory shifted up one row: ring = middle, middle = right, index = left.

### LED edit — `ledmap[5]`

Copy the existing teal `{40,218,204}` highlight from the old click keys
(`S/D/F`, LED indices 14/15/16) to the new ones (`W/E/R`, LED indices 8/9/10);
clear 14/15/16.

### Unchanged

`layer_state_set_user()` — tri-layer release (layers 1+2 → 3) and "auto-mouse layer
yields to any explicitly-held layer" — stays exactly as-is.

## Behavior after change

- Trackpad → layer 5; clicks are on `W` (middle) / `E` (right) / `R` (left).
- `S/D/F` fall through to base mod-taps → `⌃+⌥`, `⌃+<key>`, `⌥+<key>`, `⇧+<key>`
  all work while mousing; `⌘` (`A`) too.
- Click-and-drag works — the top-row buttons are plain mouse buttons; hold to drag.
- `⌃/⇧ + scroll` zoom works by holding `D`/`F` (home-row mod) and scrolling.
- LED highlight follows the buttons to `W/E/R`.

## Notes / risks / out of scope

- The only ⌃/⇧ source while mousing is now the home-row mod-tap, which needs a brief
  hold (~`TAPPING_TERM`) before it registers as a modifier. Scrolling takes longer
  than that, so it is a non-issue in practice; this is why the dedicated `G`/thumb
  modifiers are no longer needed.
- Starting to type with `W/E/R` while the layer is warm (within `AUTOMOUSE_TIMEOUT`
  or while a key is held) sends clicks, not letters — accepted; touch nothing for the
  timeout, or the layer drops on its own / via the existing yield logic.
- Merge risk: edits to Oryx-generated keymap/LED lines are low-risk and only conflict
  if the same keys are edited in Oryx later. `layer_state_set_user()` is merge-safe.
- Cannot compile locally; verification is static review + the GitHub Action Docker build.

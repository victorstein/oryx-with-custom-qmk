# Mouse layer: drop instantly when typing (non-click keys) — design

**Date:** 2026-06-19
**Keyboard:** ZSA Voyager (`JRZ6Q`), Oryx + custom-QMK hybrid, Navigator trackpad.
**Host:** macOS.
**Builds on:** `2026-06-18-mouse-layer-homerow-mods-design.md` (clicks live on the top
row `W`=middle / `E`=right / `R`=left; home row is transparent → base mod-taps) and the
`AUTOMOUSE_TIMEOUT` bump to 650ms. Both stay in force; this only adds an early-exit.

## Problem

The auto-mouse layer (`AUTOMOUSE_LAYER = 5`) stays warm for `AUTOMOUSE_TIMEOUT`
(650ms) after the last trackpad motion, and each keypress on the layer resets that
window. While warm, `W`/`E`/`R` are mouse clicks, not letters. So if you stop mousing
and start typing within the window, a word containing `w`/`e`/`r` fires stray clicks.

The user wants: pressing any key that is **not** `W`/`E`/`R` should drop the mouse
layer **instantly**, so subsequent `W`/`E`/`R` presses are letters again.

## Key constraint — modifier gestures must survive

A naïve "any non-`W`/`E`/`R` key kills the layer" rule breaks **modifier + click**
combos (shift-click, ⌘-click, ⌃-click, ⌥-click) and **⌃/⇧ + scroll zoom**: you press
and *hold* the modifier first, which would kill the layer before the click/scroll lands.

The resolving insight: **a modifier used in a mouse gesture is always a _hold_, never a
_tap_.** So held modifiers are the exemption; anything you actually *type* drops the
layer.

## Decision

Add an early guard at the top of the existing `process_record_user`
(`JRZ6Q/keymap.c`, currently line 180). On a **key press while layer 5 is active**,
branch on the resolved keycode:

| Resolved keycode | Action | Why |
|---|---|---|
| `KC_MS_BTN1` / `KC_MS_BTN2` / `KC_MS_BTN3` (the `W`/`E`/`R` clicks) | keep layer | clicks and press-and-hold drag continue |
| `QK_MOD_TAP … QK_MOD_TAP_MAX` with `record->tap.count == 0` (mod-tap resolving as **hold**) | keep layer | modifier gesture in progress (shift-click, ⌃/⇧+scroll-zoom) |
| `KC_LEFT_CTRL … KC_RIGHT_GUI` (plain modifiers) | keep layer | held modifier |
| `QK_ONE_SHOT_MOD … QK_ONE_SHOT_MOD_MAX` (one-shot mods) | keep layer | modifier |
| anything else (letters, numbers, symbols, nav, layer/thumb keys, mod-tap **tap**) | `layer_off(AUTOMOUSE_LAYER)` | typing → drop the click layer |

The guard runs only on `record->event.pressed` and only when `layer_state_is(AUTOMOUSE_LAYER)`.
It does not `return` — it falls through into the existing `switch` so all current
keycode handling (`QK_MODS`, `DUAL_FUNC_*`, `RGB_SLD`) is untouched.

The `keycode` parameter here is already layer-resolved, so a transparent home-row key
on layer 5 arrives as its base mod-tap keycode (e.g. `MT(MOD_LCTL, KC_D)`), which the
`QK_MOD_TAP` branch matches.

### Why `tap.count == 0` for mod-taps

At the press event a mod-tap that will become a hold has `tap.count == 0`; we treat
that as "modifier, keep the layer." A genuine tap is only known later (on release /
after resolution), so we never see `tap.count > 0` on the press we act on. The
practical effect: **tapping** a home-row key for its *letter* while warm does **not**
drop the layer. This is an accepted edge (see below) and is the safe direction —
we never cancel a real modifier gesture. This matches the existing `DUAL_FUNC_*`
handlers in the same file, which already branch on `record->tap.count`.

## Recovery

`layer_off()` from the keymap sticks: the automouse module re-asserts the layer only
on *new* trackpad motion crossing the threshold (verified in `automouse.c` —
`pointing_device_task_automouse` only calls `automouse_accumulate`; the keep-alive
branch updates `last_activity` but never calls `layer_on`). So after a typed key drops
the layer, the next trackpad motion brings it straight back. The module's internal
`is_active` stays `true` after our `layer_off`, which is harmless: on the next motion
`automouse_activate()` re-runs `layer_on`, and otherwise the module's own timeout
eventually calls `automouse_deactivate` (a no-op `layer_off`).

## Behavior after change

- Mouse, then type a normal letter (e.g. `q`, `t`, `z`) → layer drops on that press;
  following `w`/`e`/`r` are letters.
- Shift-click / ⌘-click / ⌃-click / ⌥-click → the held modifier keeps the layer; the
  click lands. Press-and-hold drag still works (`KC_MS_BTNx` keep the layer).
- ⌃/⇧ + two-finger scroll zoom → hold `D`/`F` (mod-tap hold) keeps the layer; scroll.
- `⌃+⌥` and other left-hand modifier combos → unaffected (still fall through to base
  mod-taps; the layer state doesn't gate modifier output).
- Composes with the existing `layer_state_set_user` yield logic (auto-mouse layer
  yields to any explicitly-held layer) — both can fire; no conflict.

## Notes / risks / out of scope

- **Accepted edge 1:** tapping a home-row key (`a`/`s`/`d`/`f`) for its *letter* while
  warm does not instantly drop the layer (mod-tap looks like a pending hold at press
  time). The 650ms timeout still ends the window. Not worth the complexity to chase.
- **Accepted edge 2:** a word that *starts* with `w`/`e`/`r` while warm still clicks on
  that first key — there is no preceding key to trigger the drop. Pure timeout
  territory; unchanged by this design.
- **Merge safety:** the guard is custom code inserted into the Oryx-generated
  `process_record_user`. Like the existing custom logic in `layer_state_set_user`, it
  survives the Action's `git merge -Xignore-all-space oryx`. Only a conflict if Oryx
  regenerates the same function body lines; low risk.
- **No config or LED changes.** Keymap layout, `ledmap`, and `config.h` are untouched.
- Cannot compile locally; verification is static review + the GitHub Action Docker build.

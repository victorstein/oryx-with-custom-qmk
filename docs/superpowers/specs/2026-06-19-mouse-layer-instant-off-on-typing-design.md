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
| `QK_MOD_TAP … QK_MOD_TAP_MAX` (any mod-tap, incl. the home-row mods) | keep layer | a held mod-tap is a modifier gesture (shift-click, ⌃/⇧+scroll-zoom); see note |
| `KC_LEFT_CTRL … KC_RIGHT_GUI` (plain modifier keycodes) | keep layer | held modifier — **load-bearing** here: the thumb `KC_LEFT_GUI`/`KC_RIGHT_GUI` (⌘) and pinky `KC_LEFT_SHIFT` (⇧) are plain keys (keymap.c:25-26), so this is what makes ⌘-click / shift-click work |
| anything else (letters, custom `DUAL_FUNC_*` macros, layer/momentary keys, symbols, nav, thumbs) | `layer_off(AUTOMOUSE_LAYER)` | typing / layer-switching → drop the click layer |

The guard is a **standalone `if (record->event.pressed && layer_state_is(AUTOMOUSE_LAYER))`
block placed *before* the existing `switch (keycode)`** — NOT new `case` labels added to
that switch (which already owns `QK_MODS … QK_MODS_MAX`). It never `return`s, so control
falls through to the existing switch and all current handling (`QK_MODS`, `DUAL_FUNC_*`,
`RGB_SLD`) is untouched.

The `keycode` parameter is already layer-resolved, so a transparent layer-5 key arrives
as its base keycode — e.g. home-row `D` as `MT(MOD_LCTL, KC_D)` (matches `QK_MOD_TAP`),
top-row `Q` as plain `KC_Q`, the `T`-position as the custom `DUAL_FUNC_0`, a thumb as
`MO(1)`. The guard classifies by keycode *range*, so it behaves correctly regardless of
what each transparent key happens to resolve to: only clicks and held modifiers are
exempt; everything else drops the layer.

### Note on the mod-tap branch and `tap.count`

At the **press** event a mod-tap reports `tap.count == 0` whether it will become a hold
(modifier) or a tap (letter) — the tap/hold decision resolves later. So the press we act
on cannot distinguish them, and we deliberately err toward *keeping* the layer for the
whole `QK_MOD_TAP` range. Practical consequence: **tapping a home-row key (`a`/`s`/`d`/`f`)
for its letter while warm does not drop the layer** (Accepted edge 1 below). This is the
safe direction — we never cancel a real modifier gesture. (The existing `DUAL_FUNC_*`
handlers in this file branch on `record->tap.count` the same way.)

### Note on keycode-range adjacency (footgun avoided)

We intentionally do **not** add a `QK_ONE_SHOT_MOD … QK_ONE_SHOT_MOD_MAX` exemption:
there are no one-shot-mod (`OSM`) keys in this keymap (dead code), and that range
(`0x52A0–0x52BF`) is a *sub-range* of `QK_MOMENTARY` (`0x5200–0x52FF`), which is where the
`MO(n)` thumb-layer keys live. Momentary-layer keys *should* drop the auto-mouse layer
(they hit `default`), so adding the OSM range would be both useless and a latent
misclassification trap. Leaving it out keeps `MO(n)` on the `default` path.

### Why `tap.count == 0` for mod-taps

At the press event a mod-tap that will become a hold has `tap.count == 0`; we treat
that as "modifier, keep the layer." A genuine tap is only known later (on release /
after resolution), so we never see `tap.count > 0` on the press we act on. The
practical effect: **tapping** a home-row key for its *letter* while warm does **not**
drop the layer. This is an accepted edge (see below) and is the safe direction —
we never cancel a real modifier gesture. This matches the existing `DUAL_FUNC_*`
handlers in the same file, which already branch on `record->tap.count`.

## Implementation shape

```c
bool process_record_user(uint16_t keycode, keyrecord_t *record) {
  // Typing drops the auto-mouse layer instantly so W/E/R go back to being letters.
  // Held modifiers (mouse gestures are always a HOLD) and the click keys keep it.
  if (record->event.pressed && layer_state_is(AUTOMOUSE_LAYER)) {
    switch (keycode) {
      case KC_MS_BTN1:
      case KC_MS_BTN2:
      case KC_MS_BTN3:
        break;                              // clicks (and drag) — keep the layer
      case QK_MOD_TAP ... QK_MOD_TAP_MAX:   // home-row mods etc. — keep (see note)
        break;
      case KC_LEFT_CTRL ... KC_RIGHT_GUI:   // plain mods (thumb ⌘, pinky ⇧) — keep
        break;
      default:
        layer_off(AUTOMOUSE_LAYER);         // anything typed — drop the click layer
        break;
    }
  }

  switch (keycode) {        // ← existing Oryx-generated switch, unchanged
  case QK_MODS ... QK_MODS_MAX:
    /* ... */
  }
  return true;
}
```

The mod-tap branch is collapsed to a plain `break` because `tap.count` is `0` at the
press for both tap and hold (see note above); the range is simply always exempt.

## Recovery

`layer_off()` from the keymap sticks: the automouse module re-asserts the layer only
on *new* trackpad motion crossing the threshold (verified in `automouse.c` —
`pointing_device_task_automouse` only calls `automouse_accumulate`; the keep-alive
branch updates `last_activity` but never calls `layer_on`). So after a typed key drops
the layer, the next trackpad motion brings it straight back. The module's internal
`is_active` stays `true` after our `layer_off`, which is harmless: on the next motion
`automouse_activate()` re-runs `layer_on`, and otherwise the module's own timeout
eventually calls `automouse_deactivate` (a no-op `layer_off`).

**Processing order:** the module's `process_record_automouse` runs *before*
`process_record_user`. So on the press it has already done `held_keys++` and refreshed
`last_activity` before our guard fires `layer_off`. That refresh does not re-assert the
layer (only motion does), so it is benign; the matching release later runs `held_keys--`,
keeping the counter balanced for a clean tap.

## Behavior after change

- Mouse, then type a word that doesn't start with `w`/`e`/`r` (e.g. "you", "the",
  "hi") → the first typed key drops the layer; the rest, including any later
  `w`/`e`/`r`, are letters.
- Shift-click / ⌘-click / ⌃-click / ⌥-click → the held modifier keeps the layer; the
  click lands. Press-and-hold drag still works (`KC_MS_BTNx` keep the layer). Tapping
  a non-modifier key *mid-drag* fires `layer_off`, but the held click button is already
  registered at the HID level, so the drag continues uninterrupted.
- ⌃/⇧ + two-finger scroll zoom → hold `D`/`F` (mod-tap hold) keeps the layer; scroll.
- `⌃+⌥` and other left-hand modifier combos → unaffected (still fall through to base
  mod-taps; the layer state doesn't gate modifier output).
- Pressing a thumb layer key (`MO(1)`/`MO(2)`) while warm → drops layer 5 via both this
  guard's `default` branch *and* the existing `layer_state_set_user` yield (it strips
  layer 5 whenever another layer turns on). Both do the same thing; idempotent.

## Notes / risks / out of scope

- **Accepted edge 1:** tapping a home-row key (`a`/`s`/`d`/`f`) for its *letter* while
  warm does not instantly drop the layer (mod-tap looks like a pending hold at press
  time). The 650ms timeout still ends the window. Not worth the complexity to chase.
- **Accepted edge 2:** a word that *starts* with `w`/`e`/`r` while warm still clicks on
  that first key — there is no preceding key to trigger the drop. Pure timeout
  territory; unchanged by this design.
- **Accepted edge 3:** if you *hold* a non-click, non-modifier key (e.g. for key-repeat)
  the press fires `layer_off`, but the module's `held_keys` stays `> 0` until release.
  If new trackpad motion crosses threshold during that hold, the layer re-activates and
  the module's keep-alive holds it open until the key is released. Niche; not worth
  special-casing.
- **Merge safety:** the guard is custom code inserted into the Oryx-generated
  `process_record_user`. Like the existing custom logic in `layer_state_set_user`, it
  survives the Action's `git merge -Xignore-all-space oryx`. Only a conflict if Oryx
  regenerates the same function body lines; low risk.
- **No config or LED changes.** Keymap layout, `ledmap`, and `config.h` are untouched.
- Cannot compile locally; verification is static review + the GitHub Action Docker build.

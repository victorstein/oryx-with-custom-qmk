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

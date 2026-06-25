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

# -N (forward-only) on the patch calls: an already-applied patch loud-fails rather than
# silently reverse-applying (BSD patch auto-answers the reverse prompt non-interactively).
for p in "$PATCHES_DIR"/*.patch; do
  [ -e "$p" ] || continue          # nullglob guard: POSIX leaves the glob literal if empty
  name=$(basename "$p")
  sentinel=$(sentinel_for "$name")

  if [ -n "$sentinel" ] && grep -rq "$sentinel" "$MODULES_DIR" 2>/dev/null; then
    echo "::notice::module-patches: $name already applied (or upstream ships it) — skipping."
    continue
  fi
  if ! patch -N -p1 -d "$MODULES_DIR" --dry-run < "$p" >/dev/null 2>&1; then
    echo "CONTACT_PATCH_APPLY_FAILED"
    echo "::error::module-patches: $name does not apply against the current qmk_modules — refresh it (see patches/README.md)."
    exit 1
  fi
  if ! patch -N -p1 -d "$MODULES_DIR" < "$p" >/dev/null; then
    echo "CONTACT_PATCH_APPLY_FAILED"
    echo "::error::module-patches: $name apply failed after a passing dry-run (disk/permission error?)."
    exit 1
  fi
  echo "module-patches: applied $name"
done
echo "module-patches: all patches applied to $MODULES_DIR"

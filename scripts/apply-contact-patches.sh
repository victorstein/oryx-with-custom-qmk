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
    echo "CONTACT_PATCH_APPLY_FAILED"
    echo "::error::contact-keepalive: missing patch file $p"
    exit 1
  fi
  if ! patch -p1 -d "$MODULES_DIR" --dry-run < "$p" >/dev/null 2>&1; then
    echo "CONTACT_PATCH_APPLY_FAILED"
    echo "::error::contact-keepalive: $name does not apply against the current qmk_modules — refresh it (see patches/README.md)."
    exit 1
  fi
  if ! patch -p1 -d "$MODULES_DIR" < "$p" >/dev/null; then
    echo "CONTACT_PATCH_APPLY_FAILED"
    echo "::error::contact-keepalive: $name apply failed after a passing dry-run (disk/permission error?)."
    exit 1
  fi
  echo "contact-keepalive: applied $name"
done
echo "contact-keepalive: all patches applied to $MODULES_DIR"

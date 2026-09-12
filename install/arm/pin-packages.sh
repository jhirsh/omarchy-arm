#!/bin/bash

# Regenerate the lock set: capture the currently-installed versions of the named
# packages and publish them as a GitHub release install.sh can fall back to.
#
# Run this on a machine where the desktop works, after an install or update you
# are happy with. It reads the built package files out of pacman's cache (so the
# bytes are exactly what is installed, not whatever a mirror serves now), writes
# their names and checksums into install/arm/packages.pinned, and uploads the
# files to the release that file names. A fresh install on another board then
# installs that set directly when Arch Linux ARM's own repository is mid-rebuild
# and cannot satisfy the desktop.
#
# Usage, from a checkout on the working machine:
#   install/arm/pin-packages.sh hyprland aquamarine hyprutils hyprgraphics hyprwire
#
# Needs gh authenticated against the fork. Pass the packages the desktop's
# fast-moving stack actually pins on; the Hyprland family is the usual set.

set -euo pipefail

CHECKOUT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
MANIFEST="$CHECKOUT/install/arm/packages.pinned"
CACHE="${PACMAN_CACHE:-/var/cache/pacman/pkg}"

(( $# > 0 )) || { echo "Usage: $0 <package>..." >&2; exit 1; }

release=$(sed -n 's/^#[[:space:]]*release:[[:space:]]*//p' "$MANIFEST" | head -1)
[[ -n $release ]] || { echo "No 'release:' line in $MANIFEST" >&2; exit 1; }
tag="${release##*/}"

# Keep the header (every line up to and including the 'filename ... sha256' one)
# and rewrite the entries below it.
header=$(sed '/^#[[:space:]]*filename/q' "$MANIFEST")

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
declare -a assets=()

{
  echo "$header"
  for pkg in "$@"; do
    ver=$(pacman -Q "$pkg" | awk '{print $2}')
    # Cache filenames carry the architecture and a .xz or .zst extension; take
    # the newest match so a re-pin after an upgrade picks the current one.
    file=$(ls -t "$CACHE/$pkg-$ver-"*.pkg.tar.* 2>/dev/null | grep -v '\.sig$' | head -1) ||
      { echo "No cached file for $pkg $ver in $CACHE; run 'sudo pacman -Sw $pkg' first." >&2; exit 1; }
    fn=$(basename "$file")
    sha=$(sha256sum "$file" | awk '{print $1}')
    printf '%-44s %s\n' "$fn" "$sha"
    cp "$file" "$tmp/$fn"
    assets+=("$tmp/$fn")
  done
} >"$MANIFEST.new"
mv "$MANIFEST.new" "$MANIFEST"

echo "Wrote $MANIFEST:"
sed -n '/^#[[:space:]]*filename/,$p' "$MANIFEST" | grep -v '^#'

# --clobber so a re-pin replaces the assets rather than erroring on duplicates.
if gh release view "$tag" >/dev/null 2>&1; then
  gh release upload "$tag" --clobber "${assets[@]}"
else
  gh release create "$tag" --title "Pinned packages" \
    --notes "Known-good package set for install.sh to fall back on." "${assets[@]}"
fi

echo "Uploaded ${#assets[@]} package(s) to release '$tag'. Commit the updated $MANIFEST."

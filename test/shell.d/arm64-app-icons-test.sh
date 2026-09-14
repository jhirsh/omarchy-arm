#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command magick

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Stand in for install/arm/settings.sh, which sources app-icons.sh with these in
# scope. A real run writes under /usr; this one writes under a scratch sysroot.
# place() keeps the real one's contract: back up a destination that differs.
say() { :; }
place() {
  local dest="$root$3"
  if [[ -e $dest ]] && ! cmp -s "$2" "$dest"; then
    cp -a "$dest" "$dest.omarchy-arm.bak"
  fi
  install -Dm"$1" "$2" "$dest"
}
dry=0

apps="usr/share/icons/hicolor"

# The shipped icons, against every launcher that names one. Icon lookup is
# case-sensitive: a launcher asking for google-maps finds nothing in a directory
# holding "Google Maps.png", so it shows no logo at all.
OMARCHY_PATH="$ROOT"
root="$work/shipped"
source "$ROOT/install/arm/app-icons.sh"

unresolved=()
for desktop in "$ROOT"/applications/*.desktop; do
  wanted=$(sed -n 's/^Icon=//p' "$desktop" | head -1)
  [[ -n $wanted ]] || continue

  shipped=0
  for icon in "$ROOT"/applications/icons/*; do
    [[ $(app_icon_id "$(basename "$icon")") == "$wanted" ]] && shipped=1
  done
  (( shipped )) || continue

  [[ -f $root/$apps/256x256/apps/$wanted.png && -f $root/$apps/48x48/apps/$wanted.png ]] ||
    [[ -f $root/$apps/scalable/apps/$wanted.svg ]] ||
    unresolved+=("$(basename "$desktop") -> $wanted")
done
(( ${#unresolved[@]} == 0 )) ||
  fail "every launcher finds the icon Omarchy ships for it" "$(printf '%s\n' "${unresolved[@]}")"
pass "every launcher finds the icon Omarchy ships for it"

misnamed=$(find "$root/$apps" -type f -name '*[A-Z ]*')
[[ -z $misnamed ]] || fail "no icon is filed under a name nothing looks up" "$misnamed"
pass "no icon is filed under a name nothing looks up"

# Sizes follow the omarchy-settings package: a pixel-size directory promises
# that size, and scalable/ is for SVG only.
OMARCHY_PATH="$work/checkout"
root="$work/upgraded"
mkdir -p "$OMARCHY_PATH/applications/icons"
magick -size 512x300 xc:red "$OMARCHY_PATH/applications/icons/Google Maps.png"
magick -size 64x64 xc:blue "$OMARCHY_PATH/applications/icons/imv.png"
printf '<svg xmlns="http://www.w3.org/2000/svg"/>\n' >"$OMARCHY_PATH/applications/icons/Some App.svg"

# What earlier runs of the installer left behind: PNGs in scalable/, then PNGs
# in 256x256/ under their source spelling.
mkdir -p "$root/$apps/scalable/apps" "$root/$apps/256x256/apps"
cp "$OMARCHY_PATH/applications/icons/imv.png" "$root/$apps/scalable/apps/imv.png"
cp "$OMARCHY_PATH/applications/icons/imv.png" "$root/$apps/256x256/apps/imv.png"
cp "$OMARCHY_PATH/applications/icons/Google Maps.png" "$root/$apps/256x256/apps/Google Maps.png"
cp "$OMARCHY_PATH/applications/icons/Google Maps.png" "$root/$apps/256x256/apps/Google Maps.png.omarchy-arm.bak"

source "$ROOT/install/arm/app-icons.sh"

[[ $(magick identify -format '%wx%h' "$root/$apps/256x256/apps/google-maps.png") == "256x256" ]] ||
  fail "a 256x256 icon is 256x256"
[[ $(magick identify -format '%wx%h' "$root/$apps/48x48/apps/google-maps.png") == "48x48" ]] ||
  fail "a 48x48 icon is 48x48"
[[ -f $root/$apps/scalable/apps/some-app.svg ]] || fail "an SVG goes in scalable/ under its icon name"
[[ ! -e $root/$apps/48x48/apps/some-app.png ]] || fail "an SVG is not rasterized"
pass "icons are filed at the sizes their directories promise"

[[ ! -e "$root/$apps/256x256/apps/Google Maps.png" ]] || fail "a misnamed icon from an earlier run is removed"
[[ ! -e "$root/$apps/256x256/apps/Google Maps.png.omarchy-arm.bak" ]] || fail "its backup is removed with it"
[[ ! -e $root/$apps/scalable/apps/imv.png ]] || fail "a PNG an earlier run put in scalable/ is removed"
[[ $(magick identify -format '%wx%h' "$root/$apps/256x256/apps/imv.png") == "256x256" ]] ||
  fail "an icon already spelled as its name keeps the copy just placed"
[[ ! -e $root/$apps/256x256/apps/imv.png.omarchy-arm.bak ]] ||
  fail "the installer's own earlier copy is not backed up among the icons"
pass "a rerun clears what earlier runs misfiled and keeps what it placed"

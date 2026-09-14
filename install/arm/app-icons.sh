# Install the application icons the omarchy-settings package would own.
#
# Sourced by install/arm/settings.sh, which provides place(), say(), $dry and
# $root.
#
# The package files each icon under its freedesktop icon name -- the file name
# lowercased, with every run of other characters turned into a dash -- and the
# desktop files ask for exactly that name: Basecamp.desktop says Icon=basecamp.
# Icon lookup is case-sensitive, so a copy that keeps the source spelling
# (Basecamp.png, "Google Maps.png") is never found and the launcher shows no
# logo. The naming and the 256/48 sizes follow the omarchy-settings PKGBUILD.

hicolor="/usr/share/icons/hicolor"

app_icon_id() {
  printf '%s\n' "${1%.*}" |
    tr '[:upper:]' '[:lower:]' |
    sed 's/[^[:alnum:]]\+/-/g; s/^-//; s/-$//'
}

if [[ -d $OMARCHY_PATH/applications/icons ]]; then
  icon_work=""
  (( dry )) || icon_work=$(mktemp -d)

  for icon in "$OMARCHY_PATH"/applications/icons/*; do
    [[ -f $icon ]] || continue
    icon_name=$(basename "$icon")
    icon_id=$(app_icon_id "$icon_name")

    if [[ $icon_name == *.svg ]]; then
      place 644 "$icon" "$hicolor/scalable/apps/$icon_id.svg"
      continue
    fi

    # An icon already spelled as its id (imv.png) was copied verbatim by an
    # earlier run. That copy is the installer's own, so replace it without
    # leaving a backup of it among the icons.
    earlier="$root$hicolor/256x256/apps/$icon_id.png"
    if (( ! dry )) && [[ -f $earlier ]] && cmp -s "$icon" "$earlier"; then
      rm -f "$earlier"
    fi

    for size in 256 48; do
      if (( dry )); then
        place 644 "$icon" "$hicolor/${size}x${size}/apps/$icon_id.png"
      else
        magick "$icon" -thumbnail "${size}x${size}" -background transparent -gravity center \
          -extent "${size}x${size}" "PNG32:$icon_work/$icon_id-$size.png"
        place 644 "$icon_work/$icon_id-$size.png" "$hicolor/${size}x${size}/apps/$icon_id.png"
      fi
    done

    # Earlier runs of this installer filed PNGs under their source spelling,
    # first in scalable/ and then in 256x256/. Neither is ever looked up, so
    # clear them out -- but not an icon already spelled as its id (imv.png),
    # whose 256x256 copy is the one just placed.
    stale=("$hicolor/scalable/apps/$icon_name")
    [[ $icon_name == "$icon_id.png" ]] || stale+=("$hicolor/256x256/apps/$icon_name")

    for path in "${stale[@]}"; do
      for file in "$root$path" "$root$path.omarchy-arm.bak"; do
        [[ -e $file ]] || continue
        if (( dry )); then
          say "would remove   $file (misnamed icon)"
        else
          rm -f "$file"
          say "removed misnamed icon $file"
        fi
      done
    done
  done

  if (( ! dry )); then
    rm -rf "$icon_work"
    if command -v gtk-update-icon-cache >/dev/null 2>&1; then
      gtk-update-icon-cache -q -t -f "$root$hicolor" || true
    fi
  fi
fi

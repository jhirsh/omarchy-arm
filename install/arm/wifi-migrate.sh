#!/bin/bash

# Carry WiFi credentials from iwd into NetworkManager before iwd is disabled.
#
# The Arch Linux ARM image this fork installs onto provisions WiFi through iwd
# and stores each network's secret in /var/lib/iwd/<SSID>.psk. Omarchy disables
# iwd and manages the network with NetworkManager instead, and NetworkManager
# does not read iwd's store -- so a Raspberry Pi reached only over WiFi drops
# off the network at the first reboot after install and cannot be reached again
# without a keyboard or a serial cable. This writes a NetworkManager keyfile for
# each iwd-known network so the machine rejoins on its own.
#
# Best effort: a network iwd stored without a usable secret (an open network, or
# one whose passphrase iwd did not keep) is skipped rather than guessed at. An
# SSID iwd percent-encoded in its filename (non-alphanumeric names) is left for
# the user to re-add; the common plain-text SSID is what this covers.
#
# Overridable for tests; honours OMARCHY_ARM_DRY_RUN=1.
omarchy_arm_migrate_iwd_wifi() {
  local store="${OMARCHY_IWD_STORE:-/var/lib/iwd}"
  local nm_dir="${OMARCHY_NM_CONNECTIONS:-/etc/NetworkManager/system-connections}"
  local dry="${OMARCHY_ARM_DRY_RUN:-0}"
  local f ssid passphrase psk secret dest

  [[ -d $store ]] || return 0

  local had_glob=0
  shopt -q nullglob && had_glob=1
  shopt -s nullglob
  for f in "$store"/*.psk; do
    ssid=$(basename "$f" .psk)
    dest="$nm_dir/$ssid.nmconnection"

    # Never clobber a connection the user already has under this name.
    [[ -e $dest ]] && continue

    # iwd prefers Passphrase (plain text); fall back to the 64-hex PreSharedKey,
    # which NetworkManager also accepts under key-mgmt=wpa-psk.
    passphrase=$(sed -n 's/^[[:space:]]*Passphrase=//p' "$f" | head -1)
    psk=$(sed -n 's/^[[:space:]]*PreSharedKey=//p' "$f" | head -1)
    secret="${passphrase:-$psk}"
    [[ -n $secret ]] || continue

    if (( dry )); then
      echo "[dry-run] migrate WiFi '$ssid' from iwd into $dest"
      continue
    fi

    install -d -m 0700 "$nm_dir"
    # NetworkManager ignores a keyfile that is not 0600 and root-owned, so write
    # it private from the start rather than chmod-ing a world-readable secret.
    ( umask 077
      cat >"$dest" <<NMCONN
[connection]
id=$ssid
type=wifi

[wifi]
ssid=$ssid
mode=infrastructure

[wifi-security]
key-mgmt=wpa-psk
psk=$secret

[ipv4]
method=auto

[ipv6]
method=auto
NMCONN
    )
    echo "Migrated WiFi '$ssid' from iwd into NetworkManager."
  done
  (( had_glob )) || shopt -u nullglob
}

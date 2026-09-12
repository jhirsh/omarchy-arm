#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

if (( BASH_VERSINFO[0] < 5 )); then
  pass "bash 5 is not available; skipping the wifi migration test"
  exit 0
fi

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

store="$test_tmp/iwd"
nm="$test_tmp/nm"
mkdir -p "$store"

# A network iwd stored with a plain-text passphrase.
cat >"$store/HomeNet.psk" <<PSK
[Security]
Passphrase=hunter2swordfish
PreSharedKey=deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef
PSK

# A network stored with only the hashed key, no passphrase.
cat >"$store/HashOnly.psk" <<PSK
[Security]
PreSharedKey=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
PSK

# An open network: no secret to carry.
cat >"$store/CoffeeShop.open" <<PSK
[Settings]
AutoConnect=true
PSK

run_migrate() {
  OMARCHY_IWD_STORE="$store" OMARCHY_NM_CONNECTIONS="$nm" \
  OMARCHY_ARM_DRY_RUN="${OMARCHY_ARM_DRY_RUN:-0}" \
    bash -c 'source "$1"; omarchy_arm_migrate_iwd_wifi' _ "$ROOT/install/arm/wifi-migrate.sh"
}

# Dry run writes nothing.
OMARCHY_ARM_DRY_RUN=1 run_migrate >/dev/null
[[ -z $(ls -A "$nm" 2>/dev/null) ]] ||
  fail "a dry run writes no NetworkManager keyfiles" "$(ls -A "$nm")"
pass "a dry run migrates nothing"

# Real run.
run_migrate >/dev/null

[[ -f "$nm/HomeNet.nmconnection" ]] ||
  fail "a passphrase network becomes a NetworkManager keyfile"
grep -q "psk=hunter2swordfish" "$nm/HomeNet.nmconnection" ||
  fail "the passphrase is carried across" "$(cat "$nm/HomeNet.nmconnection")"
grep -q "ssid=HomeNet" "$nm/HomeNet.nmconnection" ||
  fail "the SSID is set from the iwd filename"
pass "a passphrase network is migrated with its secret"

grep -q "psk=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" "$nm/HashOnly.nmconnection" ||
  fail "a network with only a hashed key uses the PreSharedKey" "$(cat "$nm/HashOnly.nmconnection" 2>/dev/null)"
pass "a key-only network falls back to the PreSharedKey"

[[ ! -e "$nm/CoffeeShop.nmconnection" ]] ||
  fail "an open network with no secret is skipped, not guessed at"
pass "an open network is skipped"

# NetworkManager ignores keyfiles that are not private.
perms=$(stat -f '%Lp' "$nm/HomeNet.nmconnection" 2>/dev/null || stat -c '%a' "$nm/HomeNet.nmconnection")
[[ $perms == "600" ]] ||
  fail "keyfiles are written 0600 so NetworkManager honours them" "got $perms"
pass "migrated keyfiles are private"

# An existing connection is never clobbered.
printf '[connection]\nid=HomeNet\n# mine\n' >"$nm/HomeNet.nmconnection"
chmod 600 "$nm/HomeNet.nmconnection"
run_migrate >/dev/null
grep -q "# mine" "$nm/HomeNet.nmconnection" ||
  fail "an existing NetworkManager connection is left untouched" "$(cat "$nm/HomeNet.nmconnection")"
pass "an existing connection is not clobbered"

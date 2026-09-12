#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# install.sh refuses to run under anything older than bash 5, which is what
# every Omarchy machine has. A development box that does not (macOS ships bash
# 3.2) should skip this file rather than report a failure it cannot fix.
if (( BASH_VERSINFO[0] < 5 )); then
  pass "bash 5 is not available; skipping the install.sh dry run"
  exit 0
fi

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

stub_bin="$test_tmp/bin"
mkdir -p "$stub_bin" "$test_tmp/dt" "$test_tmp/sync"

printf '%s\0' "raspberrypi,5-model-b" "brcm,bcm2712" >"$test_tmp/dt/compatible"
printf '%s\0' "Raspberry Pi 5 Model B Rev 1.0" >"$test_tmp/dt/model"
: >"$test_tmp/sync/core.db"

os_release() {
  cat >"$test_tmp/os-release" <<OS
NAME="$1"
PRETTY_NAME="$1"
ID=$2
${3:+ID_LIKE=$3}
OS
  echo "$test_tmp/os-release"
}

cat >"$stub_bin/uname" <<'SH'
#!/bin/bash
if [[ ${1:-} == "-m" ]]; then
  echo "${STUB_ARCH:-aarch64}"
else
  /usr/bin/uname "$@"
fi
SH

# pacman -Si is how install.sh decides whether a package is in the configured
# repositories. The stub answers from a fixture list so the plan is
# deterministic instead of depending on the machine running the tests.
cat >"$stub_bin/pacman" <<'SH'
#!/bin/bash
if [[ ${1:-} == "-Si" ]]; then
  grep -qxF "${2:-}" "$STUB_REPO_LIST"
  exit $?
fi
# -Sp resolves without installing. STUB_UNRESOLVED names a package the
# repository cannot satisfy, the way Arch Linux ARM's lagging rebuilds leave it.
if [[ ${1:-} == "-Sp" ]]; then
  if [[ -n ${STUB_UNRESOLVED:-} ]]; then
    # pacman prints the summary to stderr but the line naming the package to
    # stdout, which is why resolve_set must capture both streams.
    echo "error: failed to prepare transaction (could not satisfy dependencies)" >&2
    echo ":: unable to satisfy dependency 'libaquamarine.so=13-64' required by $STUB_UNRESOLVED"
    exit 1
  fi
  exit 0
fi
printf 'pacman %s\n' "$*" >>"$STUB_CALLS"
SH

# Nothing in a dry run may reach sudo. The stub records any call so the test
# can prove that, rather than trusting the read-through of run().
cat >"$stub_bin/sudo" <<'SH'
#!/bin/bash
printf 'sudo %s\n' "$*" >>"$STUB_CALLS"
SH

# The preflight mirror probe asks pacman which mirror it would actually use,
# then fetches from it. Both halves are stubbed so the suite never depends on a
# network, and so the offline path can be driven on demand.
cat >"$stub_bin/pacman-conf" <<'SH'
#!/bin/bash
echo 'https://mirror.example/$arch/$repo'
SH

cat >"$stub_bin/curl" <<'SH'
#!/bin/bash
# The version Arch ships on x86_64, which is the recipe the fallback builds.
if [[ $* == *archlinux.org/packages/extra/* ]]; then
  echo '{"pkgname": "hyprland", "pkgver": "0.56.2", "pkgrel": "2", "epoch": 0}'
  exit 0
fi
exit "${STUB_CURL_EXIT:-0}"
SH

chmod +x "$stub_bin"/*

# Everything in the base list is "available" except the packages the manifests
# already say have no aarch64 repository build.
sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$ROOT/install/omarchy-base.packages" | awk '{print $1}' >"$test_tmp/all-packages"
{
  sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$ROOT/install/arm/packages.aur"
  sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$ROOT/install/arm/packages.aur-required"
  sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$ROOT/install/arm/packages.unavailable"
} | awk '{print $1}' | sort -u >"$test_tmp/absent"
# Substituted names are what actually gets looked up, so the fixture has to
# carry them too -- neovim is in the repositories even though nvim is not.
awk '{print $2}' <(sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$ROOT/install/arm/packages.replace") >>"$test_tmp/all-packages"
grep -vxFf "$test_tmp/absent" "$test_tmp/all-packages" >"$test_tmp/repo-list"

run_install() {
  local os_file="$1"
  shift

  STUB_ARCH="${STUB_ARCH:-aarch64}" \
  STUB_REPO_LIST="$test_tmp/repo-list" \
  STUB_CALLS="$test_tmp/calls.log" \
  STUB_CURL_EXIT="${STUB_CURL_EXIT:-0}" \
  STUB_UNRESOLVED="${STUB_UNRESOLVED:-}" \
  OMARCHY_NOW="${OMARCHY_NOW:-}" \
  OMARCHY_OS_RELEASE="$os_file" \
  OMARCHY_ARCH="${STUB_ARCH:-aarch64}" \
  OMARCHY_DEVICETREE="$test_tmp/dt" \
  OMARCHY_PACMAN_SYNC_DIR="$test_tmp/sync" \
  OMARCHY_PINNED_MANIFEST="${OMARCHY_PINNED_MANIFEST:-}" \
  OMARCHY_ARM_SKEL="$test_tmp/skel" \
  HOME="$test_tmp/home" \
  PATH="$stub_bin:$PATH" \
    "$BASH" "$ROOT/install.sh" "$@" 2>&1
}

# A stand-in for the shipped defaults, so the seeding step has something to
# report without touching the machine running the tests.
mkdir -p "$test_tmp/skel/.config/hypr" "$test_tmp/home"
: >"$test_tmp/skel/.config/hypr/hyprland.lua"
: >"$test_tmp/skel/.bashrc"

arch_arm=$(os_release "Arch Linux ARM" archarm)
: >"$test_tmp/calls.log"

output=$(run_install "$arch_arm" --dry-run) ||
  fail "install.sh --dry-run succeeds on Arch Linux ARM" "$output"
pass "install.sh --dry-run succeeds on Arch Linux ARM"

grep -q "Platform: Raspberry Pi 5" <<<"$output" ||
  fail "the dry run reports the detected platform" "$output"
pass "the dry run reports the detected platform"

# The whole point of the flag: a dry run must not shell out to anything that
# changes the machine.
# Reading whether a key is trusted is not a change; anything else through sudo
# in a dry run is.
mutating=$(cat "$test_tmp/calls.log")
[[ -z $mutating ]] ||
  fail "a dry run invokes neither sudo nor a mutating pacman" "$mutating"
pass "a dry run invokes neither sudo nor a mutating pacman"

[[ ! -e /etc/omarchy.conf.dryrun ]] || fail "a dry run writes no config"
pass "a dry run writes nothing outside the sandbox"

# The manifests are the contract; the plan has to reflect them rather than
# quietly installing the packages that have no aarch64 build.
grep -q "No aarch64 source at all:" <<<"$output" ||
  fail "the plan counts packages with no aarch64 source" "$output"
grep -q "omacalc" <<<"$output" ||
  fail "the plan names the first-party packages it is dropping" "$output"
pass "the plan names the packages it is dropping and why"

grep -q "Not in the repositories and not in any manifest" <<<"$output" &&
  fail "every base package is accounted for by a manifest" "$output"
pass "every base package is accounted for by a manifest"

# nvim -> neovim is the substitution that keeps an editor on the machine after
# Omarchy's own x86-only build is dropped.
grep -q "would sync" <<<"$output" ||
  fail "the settings plan is printed" "$output"
pass "the settings plan is printed"

# The omarchy package installs bin/* with install -Dm755, so the executable bit
# in git is not the contract. Linking only what git marks executable dropped
# two commands the menu calls.
bin_files=$(find "$ROOT/bin" -maxdepth 1 -type f | wc -l | tr -d ' ')
grep -q "would link     $bin_files commands into /usr/bin" <<<"$output" ||
  fail "every command in bin/ is put on PATH, executable bit or not" "$(grep 'commands into' <<<"$output")"
pass "every command in bin/ is put on PATH, executable bit or not"

# Without the commands on PATH the desktop comes up as a bare compositor:
# Hyprland's autostart calls omarchy-launch-shell to raise the bar, and every
# keybinding runs an omarchy-* command. The omarchy package does this on
# x86_64 and has no aarch64 build.
grep -qE "would link +[0-9]+ commands into /usr/bin" <<<"$output" ||
  fail "the omarchy commands are put on PATH" "$output"
pass "the omarchy commands are put on PATH"

# /etc/skel only fires at user creation, and this fork installs onto a machine
# whose user already exists. Without an explicit copy the desktop comes up on
# Hyprland's own autogenerated config: no bar, no keybindings, and nothing in
# any log saying why, because nothing failed.
grep -q "would copy .* shipped defaults into" <<<"$output" ||
  fail "the shipped defaults are copied into an existing user's home" "$output"
pass "the shipped defaults are copied into an existing user's home"

# A backup this installer leaves inside the template would be copied into every
# future user's home as if it were a shipped default.
grep -q 'dest != \*"\$skel"\*' "$ROOT/install/arm/settings.sh" ||
  fail "no backups are left inside /etc/skel"
grep -q '\[\[ \$rel == \*.omarchy-arm.bak \]\] && continue' "$ROOT/install/arm/seed-home.sh" ||
  fail "seeding skips this installer's own backups"
pass "backups never masquerade as shipped defaults"

# omarchy-migrate looks for the migration file name with its extension. A
# marker without it marks nothing, and all 84 shipped migrations replay on the
# first login -- which only stayed hidden while --first-install was writing a
# second, correctly named set.
grep -q 'basename "\$migration")"$' "$ROOT/install/arm/settings.sh" ||
  fail "migration markers keep the file extension" "$(grep -n 'migrations/' "$ROOT/install/arm/settings.sh")"
pass "migration markers keep the file extension"

# --first-install makes omarchy-provision-user claim to be the ISO chroot, and
# the leaves then look for tarballs bundled under /opt/packages.
grep -q 'omarchy-provision-user" --force' "$ROOT/install.sh" ||
  fail "the installer does not claim to be an ISO chroot" "$(grep -n 'provision-user' "$ROOT/install.sh")"
# Only the invocation matters; the comment above it explains why.
grep -E '^[^#]*provision-user[^#]*--first-install' "$ROOT/install.sh" &&
  fail "no call to provision-user still passes --first-install"
# omarchy-apply-system takes a --first-install of its own, which is correct
# there: it sets OMARCHY_FIRST_INSTALL, not the setup context.
grep -q 'omarchy-apply-system" --install-user "\$USER" --first-install' "$ROOT/install.sh" ||
  fail "omarchy-apply-system keeps its own --first-install"
pass "the installer does not claim to be an ISO chroot"

# The boot chain is the one thing a wrong install here makes unrecoverable.
grep -q "skip (boot chain, not ours on ARM): /etc/mkinitcpio.conf.d/" <<<"$output" ||
  fail "the mkinitcpio drop-ins are skipped on ARM" "$output"
grep -q "skip (boot chain, not ours on ARM): /etc/limine-entry-tool.d/" <<<"$output" ||
  fail "the limine drop-ins are skipped on ARM" "$output"
pass "boot-chain drop-ins are skipped on ARM"

# The AUR step is last and off by default. On aarch64 those packages are
# compiled here, and herdr pulls zig0.15, which rebuilds Zig against LLVM 20 --
# enough to fill a 15 GB disk while the desktop is still not provisioned. A
# machine that gives up there must still end up with a working Omarchy.
user_setup_line=$(grep -n "step \"User setup\"" "$ROOT/install.sh" | cut -d: -f1)
aur_line=$(grep -n "step \"AUR packages\"" "$ROOT/install.sh" | cut -d: -f1)
[[ -n $user_setup_line && -n $aur_line ]] || fail "install.sh has both a user setup and an AUR phase"
(( aur_line > user_setup_line )) ||
  fail "the AUR phase runs after the desktop is provisioned" "user setup:$user_setup_line aur:$aur_line"
pass "the AUR phase runs after the desktop is provisioned"

grep -q "Only in the AUR, needed:" <<<"$output" ||
  fail "the plan separates the needed AUR packages from the optional ones" "$output"
grep -q "omarchy-pkg-aur-add.*xdg-terminal-exec" <<<"$output" ||
  fail "the needed AUR packages are installed even without --with-aur" "$output"
pass "the needed AUR packages are installed even without --with-aur"

no_aur=$(run_install "$arch_arm" --dry-run --no-aur) || fail "--no-aur runs" "$no_aur"
grep -q "no terminal opens" <<<"$no_aur" ||
  fail "--no-aur says what it costs" "$no_aur"
grep -q "omarchy-pkg-aur-add" <<<"$no_aur" && fail "--no-aur really installs nothing from the AUR" "$no_aur"
pass "--no-aur keeps everything out and says what that costs"

grep -q "Skipped: aether" <<<"$output" ||
  fail "the AUR packages are skipped by default and named" "$output"
grep -q -- "--with-aur" <<<"$output" ||
  fail "the plan says how to install them anyway" "$output"
pass "the AUR packages are skipped by default, named, and recoverable"

with_aur=$(run_install "$arch_arm" --dry-run --with-aur) ||
  fail "--with-aur runs" "$with_aur"
grep -q "omarchy-pkg-aur-add" <<<"$with_aur" ||
  fail "--with-aur plans the AUR builds" "$with_aur"
# bootstrap_aur_helper returns early when yay is already on PATH, and the
# stub PATH here still reaches the machine's own binaries. This suite now
# runs on a Pi whose install built yay, so the branch under test depends on
# the machine: assert the one this machine is actually in, rather than
# assuming the empty one and failing everywhere the fork has been installed.
if command -v yay >/dev/null 2>&1; then
  grep -q "aur.archlinux.org/yay.git" <<<"$with_aur" &&
    fail "an AUR helper that is already installed is not rebuilt" "$with_aur"
  pass "--with-aur plans the builds and reuses the helper already installed"
else
  grep -q "aur.archlinux.org/yay.git" <<<"$with_aur" ||
    fail "--with-aur bootstraps an AUR helper first" "$with_aur"
  pass "--with-aur plans the builds and bootstraps a helper"
fi

########################################################################
# Refusals
########################################################################

: >"$test_tmp/calls.log"
output=$(STUB_ARCH=x86_64 run_install "$arch_arm" --dry-run) &&
  fail "install.sh refuses to run on x86_64" "$output"
grep -q "aarch64 only" <<<"$output" ||
  fail "the x86_64 refusal explains itself" "$output"
grep -q "basecamp/omarchy" <<<"$output" ||
  fail "the x86_64 refusal points at upstream" "$output"
pass "install.sh refuses to run on x86_64 and says where to go instead"

fedora=$(os_release "Fedora Asahi Remix 42" fedora)
output=$(run_install "$fedora" --dry-run) &&
  fail "install.sh refuses a non-Arch distribution" "$output"
grep -q "Arch Linux ARM" <<<"$output" ||
  fail "the distribution refusal explains itself" "$output"
pass "install.sh refuses a non-Arch distribution"

# Arch derivatives declare their base in ID_LIKE rather than ID.
derivative=$(os_release "Manjaro ARM" manjaro-arm arch)
output=$(run_install "$derivative" --dry-run) ||
  fail "install.sh accepts a distribution that declares arch in ID_LIKE" "$output"
pass "install.sh accepts a distribution that declares arch in ID_LIKE"

# The two preconditions install.sh cannot supply for itself. Both used to fail
# deep into the run: the mirror partway through the package phase, the clock as
# a wall of signature errors indistinguishable from the missing keyring the
# preflight already has a message for.
offline=$(STUB_CURL_EXIT=1 run_install "$arch_arm" --dry-run) &&
  fail "install.sh refuses to start with the mirror unreachable" "$offline"
grep -q "Cannot reach the pacman mirror" <<<"$offline" ||
  fail "the offline refusal explains itself" "$offline"
grep -q "mirror.example/aarch64/core" <<<"$offline" ||
  fail "the offline refusal names the mirror pacman would have used" "$offline"
grep -q "Package plan" <<<"$offline" &&
  fail "the offline refusal lands before the package plan is printed" "$offline"
pass "an unreachable mirror is refused in preflight, not mid-download"

# A Raspberry Pi with no RTC battery boots at the epoch, which is what makes
# this worth checking rather than assuming.
skewed=$(OMARCHY_NOW=0 run_install "$arch_arm" --dry-run) &&
  fail "install.sh refuses to start with the clock at the epoch" "$skewed"
grep -q "before the newest commit in this checkout" <<<"$skewed" ||
  fail "the clock refusal explains itself" "$skewed"
grep -q "timedatectl set-ntp" <<<"$skewed" ||
  fail "the clock refusal says how to fix it" "$skewed"
pass "a clock that predates the checkout is refused before pacman sees it"

[[ ! -s $test_tmp/calls.log ]] ||
  fail "no refusal path reaches sudo" "$(cat "$test_tmp/calls.log")"
pass "no refusal path reaches sudo"

# Hyprland reloads on config change, and everything from the deploy onwards
# rewrites config. A reload landing mid-write is how a live session ends up in
# emergency mode with no keyboard layout, locked behind its own lock screen.
# run() prints a dry run's command with every argument quoted separately.
pause_line=$(grep -nE "reload-guard'? '?pause" <<<"$output" | head -1 | cut -d: -f1)
deploy_line=$(grep -n 'Deploy Omarchy to' <<<"$output" | head -1 | cut -d: -f1)
resume_line=$(grep -nE "reload-guard'? '?resume" <<<"$output" | tail -1 | cut -d: -f1)

[[ -n $pause_line && -n $resume_line ]] ||
  fail "the run pauses and resumes Hyprland's config auto-reload" "$output"
(( pause_line > deploy_line )) ||
  fail "the pause is part of the deploy step, not before it is announced" "$output"
(( resume_line > pause_line )) ||
  fail "the resume comes after the pause" "$output"
pass "the run brackets every config change with Hyprland's reload guard"

# A stock Arch Linux ARM image logs in as root with no sudo and no usable user.
# As root the installer makes the user it needs and starts over as them, so a
# fresh image is one command away rather than a manual useradd first.
: >"$test_tmp/calls.log"
as_root=$(OMARCHY_EUID=0 run_install "$arch_arm" --dry-run --user omarchytest) ||
  fail "install.sh --dry-run as root with --user succeeds" "$as_root"
grep -qE "useradd'? .*'?omarchytest" <<<"$as_root" ||
  fail "root creates the named user" "$as_root"
grep -q "sudoers.d/00-omarchy-wheel" <<<"$as_root" ||
  fail "root gives wheel sudo rights" "$as_root"
grep -qE "chown'? '?-R'? '?omarchytest:" <<<"$as_root" ||
  fail "root hands the user a checkout of their own" "$as_root"
grep -q "Package plan" <<<"$as_root" &&
  fail "the root run stops before the per-user plan" "$as_root"
[[ ! -s $test_tmp/calls.log ]] ||
  fail "the root run never calls sudo" "$(cat "$test_tmp/calls.log")"
pass "as root, install.sh creates the user and hands over to them"

no_name=$(OMARCHY_EUID=0 run_install "$arch_arm" --dry-run --yes) &&
  fail "root with --yes and no --user is refused" "$no_name"
grep -q -- "--user NAME" <<<"$no_name" ||
  fail "the refusal names the flag" "$no_name"
bad_name=$(OMARCHY_EUID=0 run_install "$arch_arm" --dry-run --user "Bad Name") &&
  fail "an invalid user name is refused" "$bad_name"
pass "root without a usable user name is refused"

# Arch Linux ARM rebuilds Arch's packages one at a time, so a soname bump leaves
# hyprland unresolvable for a few days. The plan step finds that before the
# prompt and builds the package from Arch's recipe instead of failing the
# whole transaction after the password.
stale=$(STUB_UNRESOLVED=hyprland run_install "$arch_arm" --dry-run) ||
  fail "an unresolvable package does not fail the dry run" "$stale"
grep -q "cannot satisfy the package set" <<<"$stale" ||
  fail "the plan reports the repository cannot satisfy the set" "$stale"
grep -q "unable to satisfy dependency .* required by hyprland" <<<"$stale" ||
  fail "the plan shows pacman's own line naming hyprland" "$stale"
grep -q "Installing the vendored known-good set" <<<"$stale" &&
  fail "with no lock set pinned, nothing claims to install a vendored bundle" "$stale"
grep -qE "git'? '?clone.*--branch'? '?0.56.2-2.*packages/hyprland.git" <<<"$stale" ||
  fail "the fallback clones Arch's recipe at the version x86_64 ships" "$stale"
grep -q "makepkg -s " <<<"$stale" ||
  fail "the fallback builds the package" "$stale"
grep -qE "pacman -Rdd --noconfirm.*hyprland" <<<"$stale" ||
  fail "the fallback clears any stale build of the package first" "$stale"
grep -qE "pacman'? '?-Syu'? '?--needed'? '?--noconfirm'? '?base-devel" <<<"$stale" ||
  fail "the fallback upgrades the libraries before building against them" "$stale"
grep -qE "pacman -U --needed.*\.pkg\.tar" <<<"$stale" ||
  fail "the fallback installs what it built" "$stale"
grep -q "/var/cache/pacman/pkg" <<<"$stale" ||
  fail "the fallback keeps the built package in the cache so it can be pinned" "$stale"
stale_line=$(grep -n "cannot satisfy the package set" <<<"$stale" | head -1 | cut -d: -f1 || true)
install_line=$(grep -n "Repository packages installed" <<<"$stale" | head -1 | cut -d: -f1 || true)
[[ -n $stale_line && -n $install_line ]] ||
  fail "the resolve check and the package install both appear" "$stale"
(( stale_line < install_line )) ||
  fail "the resolve check lands before the package transaction" "$stale"
pass "an unresolvable package is built from Arch's recipe before the package transaction"

# What was built is dropped from the repository transaction: we installed a
# newer coherent version ourselves, and asking pacman for the repo's older
# build would make the set resolve as unsatisfiable again.
transaction=$(grep -E "pacman -S --needed --noconfirm" <<<"$stale" | grep -v "base-devel" | tail -1)
grep -qw hyprland <<<"$transaction" &&
  fail "the built package is not handed back to the repository transaction" "$transaction"
pass "a recipe-built package is dropped from the repository transaction"

# With a lock set pinned, the vendored known-good packages go in first, before
# anything is compiled from a recipe.
pinned="$test_tmp/packages.pinned"
cat >"$pinned" <<'PIN'
# release: https://example.invalid/pinned
# filename                           sha256
hyprland-0.56.1-3-aarch64.pkg.tar.xz  0000000000000000000000000000000000000000000000000000000000000000
PIN
locked=$(OMARCHY_PINNED_MANIFEST="$pinned" STUB_UNRESOLVED=hyprland run_install "$arch_arm" --dry-run) ||
  fail "an unresolvable set with a lock set does not fail the dry run" "$locked"
grep -q "Installing the vendored known-good set: hyprland" <<<"$locked" ||
  fail "the lock set is installed when the repository cannot satisfy the set" "$locked"
grep -qE "pacman'? '?-U.*hyprland-0.56.1-3-aarch64.pkg.tar.xz" <<<"$locked" ||
  fail "the pinned package file is installed with pacman -U" "$locked"
pinned_line=$(grep -n "vendored known-good set" <<<"$locked" | head -1 | cut -d: -f1 || true)
recipe_line=$(grep -n "Building them from Arch's recipe" <<<"$locked" | head -1 | cut -d: -f1 || true)
[[ -n $pinned_line ]] ||
  fail "the lock set install appears in the plan" "$locked"
[[ -z $recipe_line ]] || (( pinned_line < recipe_line )) ||
  fail "the lock set is tried before building from a recipe" "$locked"
pass "a pinned lock set is installed before falling back to a recipe build"

#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# The command erases a drive and reflashes a bootloader, so the test covers what
# can be checked without hardware: the filters that decide whether the copy
# boots. A wrong root= or fstab entry produces a Pi that falls back to its SD
# card at best.
source "$ROOT/bin/omarchy-setup-pi-nvme-boot"

[[ $(partition_path /dev/nvme0n1 2) == "/dev/nvme0n1p2" ]] || fail "an NVMe partition gets a p before its number"
pass "an NVMe partition gets a p before its number"

[[ $(partition_path /dev/sda 1) == "/dev/sda1" ]] || fail "a SCSI partition does not"
pass "a SCSI partition does not"

cmdline="console=tty1 root=PARTUUID=0badc0de-02 rw rootwait"
[[ $(cmdline_with_root 1234abcd-02 <<<"$cmdline") == "console=tty1 root=PARTUUID=1234abcd-02 rw rootwait" ]] ||
  fail "root= is rewritten in place" "$(cmdline_with_root 1234abcd-02 <<<"$cmdline")"
pass "root= is rewritten in place"

[[ $(cmdline_with_root 1234abcd-02 <<<"root=/dev/mmcblk0p2 rw") == "root=PARTUUID=1234abcd-02 rw" ]] ||
  fail "a /dev path at the start of the line is rewritten too"
pass "a /dev path at the start of the line is rewritten too"

# rootfstype= contains "root" but is not root=.
[[ $(cmdline_with_root 1234abcd-02 <<<"rootfstype=ext4 root=UUID=abc rw") == "rootfstype=ext4 root=PARTUUID=1234abcd-02 rw" ]] ||
  fail "rootfstype= is left alone"
pass "rootfstype= is left alone"

if cmdline_with_root 1234abcd-02 <<<"console=tty1 rw" 2>/dev/null; then
  fail "a cmdline with no root= is refused rather than silently kept"
fi
pass "a cmdline with no root= is refused rather than silently kept"

fstab=$'# <file system> <dir> <type> <options> <dump> <pass>\nLABEL=RPI64-BOOT  /boot   vfat    defaults        0       0\n/dev/mmcblk0p2 / ext4 defaults 0 1\n/dev/sda1 /mnt/data ext4 defaults 0 2'
expected=$'# <file system> <dir> <type> <options> <dump> <pass>\nPARTUUID=1234abcd-01  /boot   vfat    defaults        0       0\nPARTUUID=1234abcd-02 / ext4 defaults 0 1\n/dev/sda1 /mnt/data ext4 defaults 0 2'
actual=$(fstab_with_partitions /boot 1234abcd-01 1234abcd-02 <<<"$fstab")
[[ $actual == "$expected" ]] || fail "fstab entries for / and the firmware partition are repointed, spacing and other entries kept" "$actual"
pass "fstab entries for / and the firmware partition are repointed, spacing and other entries kept"

actual=$(fstab_with_partitions /boot/firmware 1234abcd-01 1234abcd-02 <<<"proc /proc proc defaults 0 0")
[[ $actual == *"PARTUUID=1234abcd-01  /boot/firmware  vfat"* ]] || fail "a missing firmware entry is added" "$actual"
pass "a missing firmware entry is added"

config=$'arm_64bit=1\n[cm4]\notg_mode=1'
actual=$(config_with_pcie false <<<"$config")
[[ $actual == *$'[all]\n# Added by omarchy-setup-pi-nvme-boot\ndtparam=pciex1' ]] || fail "PCIe is enabled under [all]" "$actual"
[[ $actual != *pciex1_gen* ]] || fail "Gen 3 is only set when asked for" "$actual"
pass "PCIe is enabled under [all], and Gen 3 only when asked for"

actual=$(config_with_pcie true <<<$'dtparam=pciex1\ndtparam=pciex1_gen=2')
[[ $actual == $'dtparam=pciex1\ndtparam=pciex1_gen=3' ]] || fail "an existing Gen 2 setting is raised instead of duplicated" "$actual"
pass "an existing Gen 2 setting is raised instead of duplicated"

actual=$(config_with_pcie false <<<$'dtparam=nvme')
[[ $actual == "dtparam=nvme" ]] || fail "the dtparam=nvme alias counts as already enabled" "$actual"
pass "the dtparam=nvme alias counts as already enabled"

eeprom=$'[all]\nBOOT_UART=1\nBOOT_ORDER=0xf461\nPCIE_PROBE=0'
actual=$(eeprom_with_nvme_first <<<"$eeprom")
[[ $actual == $'[all]\nBOOT_UART=1\nBOOT_ORDER=0xf416\nPCIE_PROBE=1' ]] || fail "BOOT_ORDER and PCIE_PROBE are replaced in place" "$actual"
pass "BOOT_ORDER and PCIE_PROBE are replaced in place"

actual=$(eeprom_with_nvme_first <<<$'[all]\nBOOT_UART=1')
[[ $actual == $'[all]\nBOOT_UART=1\n[all]\nBOOT_ORDER=0xf416\nPCIE_PROBE=1' ]] || fail "missing keys are appended under [all]" "$actual"
pass "missing keys are appended under [all]"

actual=$(eeprom_with_nvme_first <<<"$(eeprom_with_nvme_first <<<"$eeprom")")
[[ $actual == "$(eeprom_with_nvme_first <<<"$eeprom")" ]] || fail "an already NVMe-first config is left unchanged, so a rerun schedules no update"
pass "an already NVMe-first config is left unchanged, so a rerun schedules no update"

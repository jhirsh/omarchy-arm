# Booting a Raspberry Pi 5 from NVMe

A Raspberry Pi 5 usually starts life on an SD card. With an NVMe drive attached through a PCIe HAT or base, the whole system can move onto the drive, which is many times faster for everything that touches the disk: boot, launching apps, package updates, and swap when memory runs short.

The goal is to boot entirely from the NVMe drive. Splitting the system, with the firmware on the SD card and the rest on NVMe, is a workaround for older Pis that could not boot from anything else. The Pi 5 boots from NVMe directly, and the firmware files are only read for a few seconds at power-on, so a split gains no speed and keeps the SD card as a point of failure.

Keep the SD card anyway. It is left untouched, and the Pi falls back to it if the NVMe copy ever fails to boot.

## The short version

```bash
omarchy setup pi nvme boot --dry-run   # print every step, change nothing
omarchy setup pi nvme boot             # erase the NVMe drive and copy this system onto it
sudo reboot
findmnt /                              # should now show /dev/nvme0n1p2
```

Run it from the system you want to copy, booted from the SD card, with other applications closed. Add `--gen3` to run the PCIe link at Gen 3 (see below). If more than one NVMe drive is attached, you are asked to pick one, or you can name it: `omarchy setup pi nvme boot /dev/nvme0n1`.

The drive has to show up in `lsblk` first. If it does not, check the ribbon cable, add `dtparam=pciex1` to `config.txt`, and reboot.

## What it does, and why

### 1. Partition the drive

```bash
sudo parted -s -a optimal /dev/nvme0n1 mklabel msdos \
  mkpart primary fat32 1MiB 513MiB \
  mkpart primary ext4 513MiB 100%
```

This gives the drive the same shape as a Raspberry Pi SD card image. `mklabel msdos` writes an MBR partition table. The two numbers on each `mkpart` are where the partition starts and ends on the disk, not sizes: the first runs from 1 MiB to 513 MiB (512 MiB, the size Pi images ship with), and the second from 513 MiB to the end. The first 1 MiB holds the partition table and lines partitions up with the drive's internal blocks.

**Partition 1 is FAT32** because it is read before Linux starts. The Pi's bootloader lives in an EEPROM chip on the board and only understands FAT. It loads `config.txt`, `cmdline.txt`, the kernel, the initramfs and the device tree files from this partition.

**Partition 2 is ext4** because that is where Linux runs from, and it needs what FAT lacks: file owners and permissions, symlinks, and a journal that survives a power cut.

Partitions are numbered in the order they are created. The kernel names them after the device: `nvme0n1` is NVMe controller 0, namespace 1, and its partitions are `nvme0n1p1` and `nvme0n1p2`. An SD card's are `mmcblk0p1` and `mmcblk0p2`.

### 2. Format the partitions

```bash
sudo mkfs.vfat -F 32 -n NVME-BOOT /dev/nvme0n1p1
sudo mkfs.ext4 -F -L NVME-ROOT /dev/nvme0n1p2
```

`-n` and `-L` give each filesystem a label. A partition ends up with three different names, stored in three different places:

| Name | Example | Created by | Stored | Shown by |
|---|---|---|---|---|
| Device name | `/dev/nvme0n1p1` | The kernel, at boot | Nowhere on disk | `lsblk` |
| Label | `NVME-BOOT` | `mkfs -n` / `mkfs -L` | Inside the filesystem | `lsblk -o NAME,LABEL` |
| PARTUUID | `1a2b3c4d-01` | `parted`, at random | In the partition table | `sudo blkid` |

The device name depends on where the drive is connected; the same SSD in a USB enclosure becomes `/dev/sda1`. So configuration files name partitions by label or PARTUUID instead. Labels are uppercase because FAT stores them that way, in at most 11 characters.

On an MBR disk, the PARTUUID is the disk's random 8-digit ID followed by the partition number. It is not a hardware serial number (`lsblk -o NAME,SERIAL` shows that). A freshly partitioned drive gets a new disk ID, which is why the next steps have to rewrite the files that point at the old one.

### 3. Copy the system

```bash
sudo mount /dev/nvme0n1p2 /mnt/nvme
sudo rsync -aHAXxS --numeric-ids --info=progress2 / /mnt/nvme/
sudo mount /dev/nvme0n1p1 /mnt/nvme/boot
sudo rsync -rt --modify-window=1 --info=progress2 /boot/ /mnt/nvme/boot/
```

`/dev/nvme0n1p2` is the raw partition: bytes that can be formatted, but not browsed. Mounting it attaches its filesystem to a directory so its files can be read and written there. The command mounts under a temporary directory and unmounts when it is done; `/mnt/nvme` above is just a readable stand-in.

`-x` keeps rsync on the root filesystem, so `/proc`, `/sys`, `/run` and the firmware partition come across as empty mount points rather than being copied. The firmware partition is copied separately, without owners or permissions because FAT has none. On Raspberry Pi OS it is mounted at `/boot/firmware` rather than `/boot`; the command detects which.

### 4. Point the copy at itself

Two files on the copy still name the SD card:

- **`cmdline.txt`**, on the firmware partition, holds the kernel's command line. Its `root=` says which partition to mount as `/`. It becomes `root=PARTUUID=<nvme root partuuid>`. PARTUUID is used here because the kernel can resolve it from the partition table alone, before any filesystem is mounted.
- **`/etc/fstab`** says what to mount where once the system is up. The `/boot` entry (and `/`, if it has one) is repointed to the NVMe partitions' PARTUUIDs.

`config.txt` gains `dtparam=pciex1`, which enables the PCIe connector in the kernel. With `--gen3` it also gains `dtparam=pciex1_gen=3`.

The SD card's own copies of these files are not touched, so it still boots on its own.

### 5. Try NVMe first

```bash
sudo rpi-eeprom-config --edit
```

The boot order is stored in the bootloader EEPROM, not on any disk. The command sets:

```
BOOT_ORDER=0xf416
PCIE_PROBE=1
```

`BOOT_ORDER` is read right to left, one digit per attempt: `6` NVMe, `1` SD card, `4` USB, `f` start over. `PCIE_PROBE=1` has the bootloader look for a drive on the PCIe bus even when the HAT does not identify itself. The change is staged on the current firmware partition and written to the EEPROM during the next reboot. You are asked before it is applied, and the diff is shown first.

Because the SD card stays second in the order, a copy that fails to boot drops back to the SD card, from which you can fix it or run the command again.

## Gen 3

The Pi 5 certifies its PCIe connector at Gen 2 (5 GT/s). Most drives and HATs run reliably at Gen 3 (8 GT/s), which roughly doubles sequential throughput. If you use `--gen3` and see freezes or disk errors in `sudo dmesg`, boot and remove `dtparam=pciex1_gen=3` from `/boot/config.txt` (or `/boot/firmware/config.txt`). `omarchy disk speedtest` shows the difference.

## Swap

Omarchy sets up zram on a Raspberry Pi: compressed swap held in memory, which is faster than swapping to any disk. On a Pi with little memory, once the system is on NVMe, a swap file on the drive at a lower priority catches whatever overflows zram:

```bash
sudo mkswap -U clear --size 4G --file /swapfile
sudo swapon --priority 10 /swapfile
echo '/swapfile none swap defaults,pri=10 0 0' | sudo tee -a /etc/fstab
```

zram keeps its higher priority, so the NVMe swap is only used once zram is full.

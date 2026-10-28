#!/bin/sh
# Builds the raw disk image of "Z Alpine Desktop (x86)": 32-bit Alpine Linux
# with Xorg + XFCE (LightDM autologin as z/z), the zguest agent on
# 127.0.0.1:5555 and an extlinux BIOS bootloader. Made for the v86 emulator.
#
#   sudo tools/images/x86/build-image.sh OUTDIR ZGUEST_LINUX_386_BINARY
#
# Writes OUTDIR/z-alpine-desktop-x86.img (sparse raw disk, MBR, one ext4
# partition = /dev/sda1) and OUTDIR/build-info.txt.
#
# Environment:
#   ALPINE_BRANCH  v3.22                     ALPINE_MIRROR  https://dl-cdn.alpinelinux.org/alpine
#   APK_CACHE      OUTDIR/apk-cache          DISK_MB        1536
#   IMAGE_VERSION  dev                       PRUNE_GL       1 (drop Mesa gallium + LLVM, ~350 MB)
#
# Needs root, curl, sfdisk, losetup, mkfs.ext4 on an x86_64 Linux host. The
# image's own 32-bit binaries run natively in a chroot for the configure step.
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
OUT=${1:?usage: build-image.sh OUTDIR ZGUEST_LINUX_386_BINARY}
ZGUEST=${2:?usage: build-image.sh OUTDIR ZGUEST_LINUX_386_BINARY}
BRANCH=${ALPINE_BRANCH:-v3.22}
MIRROR=${ALPINE_MIRROR:-https://dl-cdn.alpinelinux.org/alpine}
ARCH=x86
DISK_MB=${DISK_MB:-1536}
VERSION=${IMAGE_VERSION:-dev}
mkdir -p "$OUT"
OUT=$(CDPATH= cd -- "$OUT" && pwd)
CACHE=${APK_CACHE:-$OUT/apk-cache}
WORK=$OUT/work
ROOT=$WORK/rootfs
MNT=$WORK/mnt
IMG=$OUT/z-alpine-desktop-x86.img
LOOP=""

[ "$(id -u)" -eq 0 ] || { echo "build-image.sh: run as root" >&2; exit 1; }
[ -f "$ZGUEST" ] || { echo "build-image.sh: no zguest binary at $ZGUEST" >&2; exit 1; }

log() { printf '\n==> %s\n' "$*"; }

umount_tree() { # unmount everything below $1, deepest first
    for m in $(awk -v r="$1" '$2 == r || index($2, r "/") == 1 { print $2 }' /proc/mounts | sort -r); do
        umount "$m" 2>/dev/null || umount -l "$m"
    done
}

cleanup() {
    set +e
    umount_tree "$MNT"
    umount_tree "$ROOT"
    [ -n "$LOOP" ] && losetup -d "$LOOP"
}
trap cleanup EXIT INT TERM

bind_system() { # /dev, /proc, /sys for chroot work in $1
    mkdir -p "$1/dev" "$1/proc" "$1/sys"
    mount --bind /dev "$1/dev"
    mount -t proc proc "$1/proc"
    mount -t sysfs sys "$1/sys"
}

rm -rf "$WORK"
mkdir -p "$WORK/apk" "$ROOT" "$MNT" "$CACHE"
START=$(date +%s)

# --- apk.static ------------------------------------------------------------
log "apk-tools-static ($BRANCH/main/$ARCH)"
listing=$(curl -fsSL --retry 3 "$MIRROR/$BRANCH/main/$ARCH/")
apk_pkg=$(printf '%s\n' "$listing" | grep -o 'apk-tools-static-[0-9][^"<>]*\.apk' | sort -uV | tail -1)
[ -n "$apk_pkg" ] || { echo "apk-tools-static not found in $MIRROR/$BRANCH/main/$ARCH/" >&2; exit 1; }
echo "$apk_pkg"
curl -fsSL --retry 3 -o "$WORK/apk/$apk_pkg" "$MIRROR/$BRANCH/main/$ARCH/$apk_pkg"
tar -xzf "$WORK/apk/$apk_pkg" -C "$WORK/apk" sbin/apk.static 2>/dev/null || tar -xzf "$WORK/apk/$apk_pkg" -C "$WORK/apk"
APK=$WORK/apk/sbin/apk.static
"$APK" --version

# --- packages --------------------------------------------------------------
PKGS=$(sed 's/#.*//' "$HERE/packages.txt" | tr -s ' \t\n' ' ')
apk_add() {
    "$APK" --arch "$ARCH" --root "$ROOT" -U --allow-untrusted --no-progress --cache-dir "$CACHE" \
        -X "$MIRROR/$BRANCH/main" -X "$MIRROR/$BRANCH/community" "$@"
}
log "alpine-base into $ROOT"
apk_add --initdb add alpine-base alpine-keys
# The rest with /dev, /proc and /sys available to the package scripts and triggers.
bind_system "$ROOT"
log "installing $(echo $PKGS | wc -w) packages"
apk_add add $PKGS
"$APK" --root "$ROOT" info -v 2>/dev/null | sort > "$OUT/packages-installed.txt"
echo "installed: $(wc -l < "$OUT/packages-installed.txt") packages"

# --- configure (inside the chroot) -------------------------------------------
log "overlay + zguest"
(cd "$HERE/overlay" && tar --owner=0 --group=0 -cf - .) | tar -xf - -C "$ROOT"
install -D -m 0755 "$ZGUEST" "$ROOT/usr/local/bin/zguest"
install -m 0755 "$HERE/configure.sh" "$ROOT/tmp/configure.sh"
cp /etc/resolv.conf "$ROOT/etc/resolv.conf" 2>/dev/null || true
log "configure.sh (chroot)"
chroot "$ROOT" /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/root TERM=dumb \
    IMAGE_VERSION="$VERSION" ALPINE_BRANCH="$BRANCH" ALPINE_MIRROR="$MIRROR" PRUNE_GL="${PRUNE_GL:-1}" \
    /bin/sh /tmp/configure.sh
rm -f "$ROOT/tmp/configure.sh" "$ROOT/etc/resolv.conf"
rm -rf "$ROOT/var/cache/apk/"* "$ROOT/root/.cache" "$ROOT/tmp/"* 2>/dev/null || true
umount_tree "$ROOT"
ROOT_MB=$(du -sm --one-file-system "$ROOT" | cut -f1)
echo "rootfs: ${ROOT_MB} MiB"

# --- disk ------------------------------------------------------------------
log "disk: ${DISK_MB} MiB sparse, MBR, ext4 /dev/sda1"
rm -f "$IMG"
truncate -s "${DISK_MB}M" "$IMG"
printf 'label: dos\nstart=2048, type=83, bootable\n' | sfdisk --quiet "$IMG"
LOOP=$(losetup --show -f -P "$IMG")
PART=${LOOP}p1
i=0; while [ ! -b "$PART" ] && [ $i -lt 20 ]; do sleep 0.5; i=$((i + 1)); done
[ -b "$PART" ] || { echo "partition device $PART did not appear" >&2; exit 1; }
# syslinux reads ext4 but not every newer feature: no 64bit, no csum seed, no orphan file.
# lazy init off so the guest's ext4lazyinit never rewrites inode tables (keeps the saved state small).
mkfs.ext4 -q -F -L zroot -m 1 -O ^64bit,^metadata_csum_seed,^orphan_file \
    -E lazy_itable_init=0,lazy_journal_init=0 "$PART"
mount -o noatime "$PART" "$MNT"
(cd "$ROOT" && tar --numeric-owner --xattrs --xattrs-include='*' --acls --one-file-system -cpf - .) \
    | tar --numeric-owner --xattrs --xattrs-include='*' --acls -xpf - -C "$MNT"

log "extlinux"
bind_system "$MNT"
chroot "$MNT" /usr/bin/env PATH=/usr/sbin:/usr/bin:/sbin:/bin extlinux --install /boot
umount_tree "$MNT"/dev; umount_tree "$MNT"/proc; umount_tree "$MNT"/sys
df -m "$MNT" | tail -1
USED_MB=$(df -m --output=used "$MNT" | tail -1 | tr -d ' ')
sync
umount "$MNT"
e2fsck -f -n "$PART" >/dev/null 2>&1 && echo "e2fsck: clean" || { e2fsck -f -n "$PART" || true; echo "e2fsck reported problems" >&2; exit 1; }
losetup -d "$LOOP"; LOOP=""
dd if="$ROOT/usr/share/syslinux/mbr.bin" of="$IMG" bs=440 count=1 conv=notrunc status=none
sfdisk --list "$IMG"

KREL=$(cat "$ROOT/usr/share/kernel/virt/kernel.release")
cat > "$OUT/build-info.txt" <<EOF
version=$VERSION
alpine=$(cat "$ROOT/etc/alpine-release")
branch=$BRANCH
kernel=linux-virt $KREL
apk_tools_static=$apk_pkg
packages=$(wc -l < "$OUT/packages-installed.txt")
rootfs_mib=$ROOT_MB
fs_used_mib=$USED_MB
disk_mib=$DISK_MB
disk_bytes=$(stat -c %s "$IMG")
build_seconds=$(( $(date +%s) - START ))
EOF
cat "$OUT/build-info.txt"
rm -rf "$WORK"
ls -ls "$IMG"

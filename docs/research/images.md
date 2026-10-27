# Linux images for one-click download (research, 2026-10-27)

This is the curated list of "best functional images" Z Computer can offer in its image picker, in two groups:

* **A. Ready-to-run cloud images.** There is no installer. Our cloud-init NoCloud seed (`CloudInit.swift`) creates user `z`, installs `zguest`, and can optionally turn the VM into an X11 desktop the agent can drive.
* **B. Installer ISOs.** For people who want a full distribution and install it by hand in the VM window.

Section C covers Windows. The machine-readable catalogue (`images.json`, 71 entries) is at the end.

**What "verified" means here.** On 2026-10-27, every URL in `images.json` returned HTTP 200 to a HEAD request, or to a ranged GET where HEAD gave no length. The size is that response's `Content-Length` (or the `Content-Range` total). Every checksum value was read from the distribution's own sums file (or, for Pop!_OS, its build API) on the same day. The scripts that produced the JSON fetched everything again in one final pass, and all 71 entries passed. Nothing was booted, because no Mac was available for this research. Anything about boot behaviour under Virtualization.framework (VZ) is evidence from other VZ projects (lima, UTM, arm64vm), not our own test. Where there is no evidence, it is marked **UNVERIFIED**.

Extra checks run against the real files (with ranged GETs, without downloading whole images):

* **qcow2 headers** of every cloud image. All 25 qcow2 images checked are v3 with 64 KiB clusters, no backing file, no encryption, no incompatible features and **zlib/deflate** compression. That is exactly what `QCOW2.convertToRaw` supports. None uses zstd.
* **ISO boot structures.** For each ISO we read the El Torito boot catalogue, checked for `BOOTAA64.EFI`/`BOOTX64.EFI` in the EFI image, and read the hybrid MBR/GPT partition table. VZ attaches an ISO as a USB disk, not as a CD drive, so the partition table matters (B.1).
* **Desktop package names**, checked against the real repository indexes: Debian trixie main `Packages.xz` (arm64 and amd64), Ubuntu noble main and universe (arm64 from ports.ubuntu.com, amd64), Fedora 44 Everything, EPEL 9 and 10, Rocky 9 and 10 AppStream, openSUSE Leap 16.0 and Tumbleweed oss, Alpine 3.24 `APKINDEX`, archlinux.org.
* **First-boot download size**, computed from those indexes: the dependency closure of the desktop package list, minus the packages already in each image (from the image's own manifest).

---

## Summary

### The three "Recommended" images

| Role | Image | arm64 download | x86_64 download | Why |
|---|---|---|---|---|
| **1. Agent desktop** | **Debian 13 "trixie" generic, qcow2** + the XFCE/X11 recipe (A.4.1) | 431,882,240 B (432 MB) | 438,894,592 B (439 MB) | Full kernel (virtio-gpu, USB HID, vsock). `firefox-esr` is a real deb, with no snap. Xorg plus XFCE plus LightDM autologin is plain Debian. The lean recipe adds only about 199 MB at first boot (836 MB installed). |
| **2. Terminal / dev** | **Ubuntu 24.04 LTS server cloud image** | 616,522,752 B (617 MB) | 621,284,352 B (621 MB) | The most-used dev base, with support until 2029. This is lima's default image. Kernel 6.8, so it boots on Intel Macs on any macOS that VZ supports (A.1, Intel note). |
| **3. Smallest download** | **Ubuntu 24.04 LTS minimal cloud image** | 224,002,048 B (224 MB) | 260,177,920 B (260 MB) | It is systemd plus apt, so our seed and the `zguest` systemd installer work unchanged. It has no snapd and keeps the same generic kernel. Alpine 3.24 is smaller (192 MB / 158 MB), but it needs an OpenRC port of the agent installer and has no bash (A.4.6). |

### Findings the app should act on

1. **Switch the Debian catalogue entries from `.raw` to `.qcow2`.** It is the same build (`20261026-2643`). The download is **432 MB instead of 3.22 GB**, and its header is v3 with 64 KiB clusters and zlib, which our converter supports. The `.raw` is not compressed on the wire, so `sparse: true` saves disk space but not transfer.
2. **Never offer Debian `genericcloud` for a desktop.** Its `linux-image-cloud-*` kernel config has `# CONFIG_DRM is not set`, `# CONFIG_HID is not set` and `# CONFIG_USB_SUPPORT is not set`. That means no virtio-gpu output and no USB keyboard or pointer under VZ ([salsa config.cloud](https://salsa.debian.org/kernel-team/linux/-/raw/debian/6.12/trixie/debian/config/config.cloud)). Lima uses genericcloud because it is headless. Our catalogue already uses `generic`, which is right.
3. **`Checksums.parse` only understands GNU lines (`hex  name`).** The catalogue also needs:
   * **BSD style**, `SHA256 (file) = hex`, for Fedora (PGP-clearsigned `*-CHECKSUM`) and Rocky (`*.CHECKSUM`, `CHECKSUM`).
   * **A bare hash with no file name**, for Alpine `*.qcow2.sha512`.
   * **A different file name** for openSUSE `*-Current.iso.sha256`. It names the `…-SnapshotYYYYMMDD-Media.iso` file that the alias redirects to, so look it up by the redirect target, or take the only entry.
   * **JSON** for Pop!_OS: `sha_sum` from `api.pop-os.org/builds/…`.

   `images.json` records the style per entry in `checksum.style`.
4. **Install the desktop from `runcmd`, not from `packages:`.** cloud-init's `packages:` runs in the final stage, before `scripts_user`, so the agent would only come up after the whole desktop install. Our generator puts `zguest-install` first in `runcmd`. If the apt or dnf install comes after it, the agent is reachable within a minute of boot and can watch the install (`cloud-init status --wait`).
   `packages:` also pulls in Recommends. On Debian that means **576 MB to download (952 packages) instead of 199 MB (246 packages)**, and it brings in `light-locker`.
5. **Intel hosts: guest kernels of 6.12 or later do not boot under VZ before macOS 15.5.** The cause is a regression from Linux commit 70044df250d0 (x86/pkeys), fixed in macOS 15.5 ([lima#3334](https://github.com/lima-vm/lima/issues/3334)). The workaround is the `nopku` kernel argument.
   * Affected: Debian 13, Fedora 43/44, Ubuntu 26.04, Arch, Leap 16 and Tumbleweed. Rocky/Alma 10 are likely affected (6.12-based kernel, not tested).
   * Not affected: Ubuntu 24.04 (6.8) and Alpine (no `CONFIG_X86_INTEL_MEMORY_PROTECTION_KEYS`). EL9 is a 5.14 base, but whether the regression was backported is UNVERIFIED.
   * Apple-silicon hosts are not affected.
6. **The seed is not fully portable beyond Debian and Ubuntu:**
   * `shell: /bin/bash` breaks Alpine, which has no bash until the `bash` package is installed.
   * The `zguest` installer is systemd-only. On Alpine it copies the binary, then fails at `cat > /etc/systemd/system/zguest.service`.
   * `groups: [sudo, adm]` relies on cloud-init creating missing groups on Fedora, EL and SUSE (the sudoers rule works regardless).
7. **Pinned file names go stale.** Debian ISOs in `current/` are renamed at every point release (13.7.0 today). Fedora, Kali and NixOS release paths are versioned. Prefer the "latest/current" aliases where they exist, and resolve the real name from the sums file at download time.
8. **Some arm64 ISOs have no MBR/GPT at all.** They boot only through El Torito: NixOS minimal, Rocky 10, Pop!_OS arm64 and elementary OS 8.1 arm64. EDK2 explicitly supports El Torito on 512-byte USB media ("If the ISO image has been copied onto a different storage media then the block size might be different (eg: USB)", [ElTorito.c](https://github.com/tianocore/edk2/blob/master/MdeModulePkg/Universal/Disk/PartitionDxe/ElTorito.c)). Whether Apple's VZ firmware does the same is **UNVERIFIED**, so mark these "may not boot" until we test them.
9. **Use X11 for the agent.** Do not offer a Wayland desktop as the agent desktop: xdotool does not work there, and GNOME blocks grim, wtype and its own screenshot D-Bus API (A.7). Fedora Workstation 43+, Ubuntu 26.04 Desktop, Pop!_OS 24.04 (COSMIC) and RHEL/Rocky/Alma 10 have **no** X11 session at all.

---

## A. Ready-to-run cloud images

### A.1 What each image is

| Distro / image | Current build | Format | Kernel (display under VZ) | Distro default user¹ | hvc0 login prompt | Pkg mgr | Agent desktop | VZ evidence² |
|---|---|---|---|---|---|---|---|---|
| Debian 13 `generic` | 20261026-2643 | raw or qcow2 (3 GiB virtual) | 6.12.113 `linux-image-arm64`/`-amd64`, full (virtio-gpu, USB HID, vsock) | `debian` | yes (systemd) | apt | **XFCE/X11, recommended** | Lima's `debian-13` template boots the same trixie builds (`genericcloud` variant) under vz |
| Debian 13 `genericcloud` | 20261026-2643 | qcow2 | 6.12 `-cloud`: **no DRM, HID or USB** | `debian` | yes | apt | **headless only** | lima `debian-13` |
| Ubuntu 24.04 server | 20261017 | qcow2 `.img` (3.5 GiB virtual) | 6.8.0-147 generic; `linux-modules` include `virtio-gpu.ko`, `usbhid.ko`, `hid-generic.ko`, `net/vmw_vsock/*` ([inclusion list](https://git.launchpad.net/~ubuntu-kernel/ubuntu/+source/linux/+git/noble/plain/debian.master/control.d/generic.inclusion-list)) | `ubuntu` | yes | apt (+ snapd) | XFCE/X11 (browser from Mozilla's APT repo) | Lima's default `ubuntu-24.04` template, vz |
| Ubuntu 24.04 minimal | release (2026-10-27 build) | qcow2 | same 6.8 generic kernel (`linux-image-virtual`) | `ubuntu` | yes | apt (no snapd, 274 pkgs) | XFCE/X11 | same kernel as above; minimal image itself UNVERIFIED on VZ |
| Ubuntu 26.04 server | 20261016 | qcow2 | 7.0 series | `ubuntu` | yes | apt | XFCE/X11 (names not re-checked for resolute) | lima `ubuntu-26.04` |
| Fedora 44 Cloud Generic | 44-1.7 | qcow2 (5 GiB, btrfs) | Fedora kernel, full | `fedora` | yes | dnf5 | XFCE/X11 (Xorg still packaged) | lima `fedora-44`, vz (Intel needs macOS 15.5+) |
| Fedora 43 Cloud Generic | 43-1.6 | qcow2 | Fedora kernel | `fedora` | yes | dnf5 | XFCE/X11 | lima `fedora-43` |
| Alpine 3.24.3 cloudinit | r0 (Limine bootloader) | qcow2 (516 MiB virtual) | `linux-virt` 6.18 (`DRM_VIRTIO_GPU=m`, `VIRTIO_VSOCKETS=m`, `VIRTIO_FS=m`) | `alpine` | **no** (OpenRC inittab; UNVERIFIED) | apk | XFCE/X11 (community repo) | 3.24/Limine UNVERIFIED; lima uses 3.21–3.23 `nocloud_…-uefi-cloudinit` images with vz |
| Alpine 3.22.7 uefi-cloudinit | r0 (GRUB-EFI) | qcow2 | `linux-virt` | `alpine` | no | apk | XFCE/X11 | lima `alpine-3.22` (`nocloud_` variant of the same release) |
| Arch Linux cloudimg | 20261015 | qcow2 (2 GiB) | `linux` (x86_64 only) | `arch` | yes | pacman | XFCE/X11 | Lima `archlinux` template; GPT has a BIOS-boot partition plus a 300 MB ESP, GRUB installed with `--target=x86_64-efi --removable` ([build.sh](https://github.com/archlinux/arch-boxes/blob/master/build.sh)). **There is no official Arch Linux ARM cloud image or ISO**: os.archlinuxarm.org has only rootfs tarballs, and lima's aarch64 entry is a 2022 community build |
| openSUSE Leap 16.0 Minimal-VM Cloud | Build18.85 | qcow2 (1.5 GiB) | 6.12 `kernel-default-base` (reduced driver set) | (not checked) | yes | zypper | XFCE/X11 after `kernel-default` (virtio-gpu in `-base` UNVERIFIED) | lima `opensuse-leap-16` |
| openSUSE Tumbleweed Minimal-VM Cloud | snapshot (rolling) | qcow2 (2 GiB) | 7.x `kernel-default-base` | (not checked) | yes | zypper | XFCE/X11 | none found (lima's `_images` has Leap 15/16 only), UNVERIFIED |
| Rocky Linux 10 GenericCloud-Base | 10.2-20260525 | qcow2 (10 GiB) | EL10 | `rocky` | yes | dnf | **terminal only** (no Xorg in EL10, no XFCE/LightDM/xdotool in EPEL 10) | lima `rocky-10` |
| Rocky Linux 9 GenericCloud-Base | 9.8-20260525 | qcow2 | EL9 5.14 | `rocky` | yes | dnf | XFCE/X11 via EPEL 9 (maim, as EPEL 9 has no scrot) | lima `rocky-9` |
| AlmaLinux 10 GenericCloud | 10.2-20261012 | qcow2 (10 GiB) | EL10 | `almalinux` | yes | dnf | **terminal only** | lima `almalinux-10` |
| AlmaLinux 9 GenericCloud | 9.8-20261005 | qcow2 | EL9 | `almalinux` | yes | dnf | XFCE/X11 via EPEL 9 | lima `almalinux-9` |

¹ Our seed lists only `z` under `users:` and does not include `default`, so cloud-init does **not** create the distro's default user. The column is for reference only. The default users are the well-known ones. They were not each checked inside the images.

² Lima has used **vz by default on macOS 13.5+ since Lima 1.0** ([lima docs](https://lima-vm.io/docs/config/vmtype/)). Lima boots these images with `VZEFIBootLoader` and a NoCloud `cidata` ISO, the same way we do, so a lima template is the best available evidence that an image boots under VZ.

**hvc0 login prompt.** On systemd distributions, `systemd-getty-generator` "will also instantiate `serial-getty@.service` instances for virtualizer consoles, if execution in a virtualized environment is detected" ([man page](https://www.freedesktop.org/software/systemd/man/latest/systemd-getty-generator.html)). The built-in list in the source is `hvc0`, `xvc0`, `hvsi0`, `sclp_line0`, `ttysclp0`, `3270/tty1` ([getty-generator.c](https://github.com/systemd/systemd/blob/main/src/getty-generator/getty-generator.c)). So a login prompt appears on our `VZVirtioConsoleDeviceSerialPortConfiguration` with no configuration. Kernel and cloud-init *boot output* only goes to hvc0 if `console=hvc0` is on the kernel command line, and the cloud images point `console=` at ttyS0/ttyAMA0 (exact per-image cmdline UNVERIFIED). Use `zguest` or `cloud-init status` as the readiness signal, not serial output.

Alpine uses busybox init plus OpenRC, so it needs `hvc0::respawn:/sbin/getty -L hvc0 115200 vt100` added to `/etc/inittab` (A.4.6).

### A.2 URLs and sizes (all HTTP 200 on 2026-10-27)

Debian URLs go through a mirror redirect, and Fedora and openSUSE URLs through MirrorManager or MirrorBrain redirects. Sizes are the final response's `Content-Length`.

| id | arch | format | download | URL |
|---|---|---|---|---|
| `debian-13-generic-arm64` | arm64 | qcow2 | 431,882,240 B (432 MB) | https://cloud.debian.org/images/cloud/trixie/latest/debian-13-generic-arm64.qcow2 |
| `debian-13-generic-x86_64` | x86_64 | qcow2 | 438,894,592 B (439 MB) | https://cloud.debian.org/images/cloud/trixie/latest/debian-13-generic-amd64.qcow2 |
| `debian-13-generic-arm64-raw` | arm64 | raw | 3,221,225,472 B (3,221 MB) | https://cloud.debian.org/images/cloud/trixie/latest/debian-13-generic-arm64.raw |
| `debian-13-generic-x86_64-raw` | x86_64 | raw | 3,221,225,472 B (3,221 MB) | https://cloud.debian.org/images/cloud/trixie/latest/debian-13-generic-amd64.raw |
| `debian-13-genericcloud-arm64` | arm64 | qcow2 | 336,723,968 B (337 MB) | https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-arm64.qcow2 |
| `debian-13-genericcloud-x86_64` | x86_64 | qcow2 | 341,114,880 B (341 MB) | https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2 |
| `ubuntu-24.04-server-arm64` | arm64 | qcow2 | 616,522,752 B (617 MB) | https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-arm64.img |
| `ubuntu-24.04-server-x86_64` | x86_64 | qcow2 | 621,284,352 B (621 MB) | https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img |
| `ubuntu-24.04-minimal-arm64` | arm64 | qcow2 | 224,002,048 B (224 MB) | https://cloud-images.ubuntu.com/minimal/releases/noble/release/ubuntu-24.04-minimal-cloudimg-arm64.img |
| `ubuntu-24.04-minimal-x86_64` | x86_64 | qcow2 | 260,177,920 B (260 MB) | https://cloud-images.ubuntu.com/minimal/releases/noble/release/ubuntu-24.04-minimal-cloudimg-amd64.img |
| `ubuntu-26.04-server-arm64` | arm64 | qcow2 | 940,373,504 B (940 MB) | https://cloud-images.ubuntu.com/resolute/current/resolute-server-cloudimg-arm64.img |
| `ubuntu-26.04-server-x86_64` | x86_64 | qcow2 | 859,090,944 B (859 MB) | https://cloud-images.ubuntu.com/resolute/current/resolute-server-cloudimg-amd64.img |
| `fedora-44-cloud-arm64` | arm64 | qcow2 | 528,154,624 B (528 MB) | https://download.fedoraproject.org/pub/fedora/linux/releases/44/Cloud/aarch64/images/Fedora-Cloud-Base-Generic-44-1.7.aarch64.qcow2 |
| `fedora-44-cloud-x86_64` | x86_64 | qcow2 | 583,729,152 B (584 MB) | https://download.fedoraproject.org/pub/fedora/linux/releases/44/Cloud/x86_64/images/Fedora-Cloud-Base-Generic-44-1.7.x86_64.qcow2 |
| `fedora-43-cloud-arm64` | arm64 | qcow2 | 544,997,376 B (545 MB) | https://download.fedoraproject.org/pub/fedora/linux/releases/43/Cloud/aarch64/images/Fedora-Cloud-Base-Generic-43-1.6.aarch64.qcow2 |
| `fedora-43-cloud-x86_64` | x86_64 | qcow2 | 583,335,936 B (583 MB) | https://download.fedoraproject.org/pub/fedora/linux/releases/43/Cloud/x86_64/images/Fedora-Cloud-Base-Generic-43-1.6.x86_64.qcow2 |
| `alpine-3.24.3-cloudinit-arm64` | arm64 | qcow2 | 191,823,872 B (192 MB) | https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/cloud/alpine-3.24.3-aarch64-cloudinit-r0.qcow2 |
| `alpine-3.24.3-cloudinit-x86_64` | x86_64 | qcow2 | 157,810,688 B (158 MB) | https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/cloud/alpine-3.24.3-x86_64-cloudinit-r0.qcow2 |
| `alpine-3.22.7-uefi-cloudinit-arm64` | arm64 | qcow2 | 206,176,256 B (206 MB) | https://dl-cdn.alpinelinux.org/alpine/v3.22/releases/cloud/alpine-3.22.7-aarch64-uefi-cloudinit-r0.qcow2 |
| `alpine-3.22.7-uefi-cloudinit-x86_64` | x86_64 | qcow2 | 183,107,584 B (183 MB) | https://dl-cdn.alpinelinux.org/alpine/v3.22/releases/cloud/alpine-3.22.7-x86_64-uefi-cloudinit-r0.qcow2 |
| `archlinux-cloudimg-x86_64` | x86_64 | qcow2 | 576,680,960 B (577 MB) | https://geo.mirror.pkgbuild.com/images/latest/Arch-Linux-x86_64-cloudimg.qcow2 |
| `opensuse-leap-16.0-cloud-arm64` | arm64 | qcow2 | 319,029,248 B (319 MB) | https://download.opensuse.org/distribution/leap/16.0/appliances/Leap-16.0-Minimal-VM.aarch64-Cloud.qcow2 |
| `opensuse-leap-16.0-cloud-x86_64` | x86_64 | qcow2 | 339,871,232 B (340 MB) | https://download.opensuse.org/distribution/leap/16.0/appliances/Leap-16.0-Minimal-VM.x86_64-Cloud.qcow2 |
| `opensuse-tumbleweed-cloud-arm64` | arm64 | qcow2 | 288,803,840 B (289 MB) | https://download.opensuse.org/ports/aarch64/tumbleweed/appliances/openSUSE-Tumbleweed-Minimal-VM.aarch64-Cloud.qcow2 |
| `opensuse-tumbleweed-cloud-x86_64` | x86_64 | qcow2 | 316,864,512 B (317 MB) | https://download.opensuse.org/tumbleweed/appliances/openSUSE-Tumbleweed-Minimal-VM.x86_64-Cloud.qcow2 |
| `rocky-10-genericcloud-arm64` | arm64 | qcow2 | 469,368,832 B (469 MB) | https://dl.rockylinux.org/pub/rocky/10/images/aarch64/Rocky-10-GenericCloud-Base.latest.aarch64.qcow2 |
| `rocky-10-genericcloud-x86_64` | x86_64 | qcow2 | 544,997,376 B (545 MB) | https://dl.rockylinux.org/pub/rocky/10/images/x86_64/Rocky-10-GenericCloud-Base.latest.x86_64.qcow2 |
| `rocky-9-genericcloud-arm64` | arm64 | qcow2 | 519,831,552 B (520 MB) | https://dl.rockylinux.org/pub/rocky/9/images/aarch64/Rocky-9-GenericCloud-Base.latest.aarch64.qcow2 |
| `rocky-9-genericcloud-x86_64` | x86_64 | qcow2 | 645,988,352 B (646 MB) | https://dl.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud-Base.latest.x86_64.qcow2 |
| `almalinux-10-genericcloud-arm64` | arm64 | qcow2 | 478,937,088 B (479 MB) | https://repo.almalinux.org/almalinux/10/cloud/aarch64/images/AlmaLinux-10-GenericCloud-latest.aarch64.qcow2 |
| `almalinux-10-genericcloud-x86_64` | x86_64 | qcow2 | 497,876,992 B (498 MB) | https://repo.almalinux.org/almalinux/10/cloud/x86_64/images/AlmaLinux-10-GenericCloud-latest.x86_64.qcow2 |
| `almalinux-9-genericcloud-arm64` | arm64 | qcow2 | 483,262,464 B (483 MB) | https://repo.almalinux.org/almalinux/9/cloud/aarch64/images/AlmaLinux-9-GenericCloud-latest.aarch64.qcow2 |
| `almalinux-9-genericcloud-x86_64` | x86_64 | qcow2 | 572,850,176 B (573 MB) | https://repo.almalinux.org/almalinux/9/cloud/x86_64/images/AlmaLinux-9-GenericCloud-latest.x86_64.qcow2 |

### A.3 Checksums as of 2026-10-27

The "latest", "current" and "Current" aliases are rebuilt in place: Debian daily, Ubuntu every few weeks, openSUSE several times a week. Always fetch the sums file at download time, as `ImagePreparer.fetch` already does. Do not hard-code these values.

- `debian-13-generic-arm64`: sha512 `5fc0eba340b16651f1b4163f3249b0c8fb91acd2bc5898b609181ee47ac50a5bf3e24166ba8647279db05e883883e22e9308193ef4ad75293cb254b919e358d8` (gnu file: https://cloud.debian.org/images/cloud/trixie/latest/SHA512SUMS)
- `debian-13-generic-x86_64`: sha512 `5bd891c6e62d01639f52a5587b72a4607421e445732214be787dba6043cf9797a6ff90bed982aada6a6c7e619f1f956d961c4fad76757171abd607920aac098a` (gnu file: https://cloud.debian.org/images/cloud/trixie/latest/SHA512SUMS)
- `debian-13-generic-arm64-raw`: sha512 `58b265ee1286c7ad8a9c96dcde3dd2825c0b6e7e5dd26baea1c9ece7e46da6d6dee8a2d800a6c6eb882e53e87771168bc4786894a3d7e48fe608907ce61499d1` (gnu file: https://cloud.debian.org/images/cloud/trixie/latest/SHA512SUMS)
- `debian-13-generic-x86_64-raw`: sha512 `7ddcbc835b6d946e2cbe578bdd2142ce12d979fed124a13986089ab9eee9fa1e4c66d6ffd35416b473a200c8757272bb065e9b764179ba92519fbe463451c27e` (gnu file: https://cloud.debian.org/images/cloud/trixie/latest/SHA512SUMS)
- `debian-13-genericcloud-arm64`: sha512 `71aa5d5dbcb3d9ecfe96bc3f6dd41b6805a0a41c852204a32747d230b64b95912297fb453b11a6031fd54d84a0a0a430e137d07e6986dc9ebc9d41483be003c4` (gnu file: https://cloud.debian.org/images/cloud/trixie/latest/SHA512SUMS)
- `debian-13-genericcloud-x86_64`: sha512 `3ace18e33bdd036edb49d1f79342bd01d2ab980e35194edb0b410435cd543538d286a0bd13bbb0835f7862306e3d385ce2f6a70d8ecf0bd961111166adbc1b8e` (gnu file: https://cloud.debian.org/images/cloud/trixie/latest/SHA512SUMS)
- `ubuntu-24.04-server-arm64`: sha256 `50e24e1fb79e89116e939d90aa7738f7af48c442fa1bc2510131e0b39c50348e` (gnu file: https://cloud-images.ubuntu.com/noble/current/SHA256SUMS)
- `ubuntu-24.04-server-x86_64`: sha256 `04e8f2461a16a44e78a370284471f29616cdd9baf1893df25807b71f985b6c94` (gnu file: https://cloud-images.ubuntu.com/noble/current/SHA256SUMS)
- `ubuntu-24.04-minimal-arm64`: sha256 `6e971c7935c62c8ea7796b085e4ea038e2301a067f8c853e154133f8df192c85` (gnu file: https://cloud-images.ubuntu.com/minimal/releases/noble/release/SHA256SUMS)
- `ubuntu-24.04-minimal-x86_64`: sha256 `3839f148c5a3b4a736e7dbb0af75594743fa5ebee2a202424ba1a32e5d3b5d2c` (gnu file: https://cloud-images.ubuntu.com/minimal/releases/noble/release/SHA256SUMS)
- `ubuntu-26.04-server-arm64`: sha256 `8eb876c2ccc4b6ff89e4a65d511815923b285e04503ba465809bf587f763da24` (gnu file: https://cloud-images.ubuntu.com/resolute/current/SHA256SUMS)
- `ubuntu-26.04-server-x86_64`: sha256 `5645d0318ad21f643ebb1ac4567514620e9893380b07b0201fda163baa5b7eb5` (gnu file: https://cloud-images.ubuntu.com/resolute/current/SHA256SUMS)
- `fedora-44-cloud-arm64`: sha256 `55c60a3b80d3616a08705afd0459e75fe9f03c54aba7a46e4002a41a72fa0d5b` (bsd file: https://dl.fedoraproject.org/pub/fedora/linux/releases/44/Cloud/aarch64/images/Fedora-Cloud-44-1.7-aarch64-CHECKSUM)
- `fedora-44-cloud-x86_64`: sha256 `28680fe5b371a5a82ebf43a31926e086a168e59949d03969c5093e7071f90b7f` (bsd file: https://dl.fedoraproject.org/pub/fedora/linux/releases/44/Cloud/x86_64/images/Fedora-Cloud-44-1.7-x86_64-CHECKSUM)
- `fedora-43-cloud-arm64`: sha256 `66031aea9ec61e6d0d5bba12b9454e80ca94e8a79c913d37ded4c60311705b8b` (bsd file: https://dl.fedoraproject.org/pub/fedora/linux/releases/43/Cloud/aarch64/images/Fedora-Cloud-43-1.6-aarch64-CHECKSUM)
- `fedora-43-cloud-x86_64`: sha256 `846574c8a97cd2d8dc1f231062d73107cc85cbbbda56335e264a46e3a6c8ab2f` (bsd file: https://dl.fedoraproject.org/pub/fedora/linux/releases/43/Cloud/x86_64/images/Fedora-Cloud-43-1.6-x86_64-CHECKSUM)
- `alpine-3.24.3-cloudinit-arm64`: sha512 `9eb2a1639df38123af47915938a4ebd2943ae543ac535c69e790e441ee11a74257ae80ad6ff10be22fdfacdf9e2b5510e0e2e6a65beaa7329d1f506ac213bebc` (bare file: https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/cloud/alpine-3.24.3-aarch64-cloudinit-r0.qcow2.sha512)
- `alpine-3.24.3-cloudinit-x86_64`: sha512 `cf1b95fb4b77d32a9e5c3d02290e203f24907550192fe21819e1abaa28541dab3fe025aa2afa1b952773e3d8e6ea5593bc2e6bfcf398bff886fe5c6f2785f308` (bare file: https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/cloud/alpine-3.24.3-x86_64-cloudinit-r0.qcow2.sha512)
- `alpine-3.22.7-uefi-cloudinit-arm64`: sha512 `c73ef67891b118f4939cdc45c2d891cbca77305f6e6073cb0d702c82aaf7eef3934cf81274c6b9f350efc03e904926316771aebfc3b67a677d890dd36d162401` (bare file: https://dl-cdn.alpinelinux.org/alpine/v3.22/releases/cloud/alpine-3.22.7-aarch64-uefi-cloudinit-r0.qcow2.sha512)
- `alpine-3.22.7-uefi-cloudinit-x86_64`: sha512 `876ae6f11342cf45f46a1a748ff8d2b2ea220e9ec3b7c3774e1cfa0e90590e9fdff8d7808008eeee2787ea2e3ecdd5376ca733573c34ff0454882cdb22519600` (bare file: https://dl-cdn.alpinelinux.org/alpine/v3.22/releases/cloud/alpine-3.22.7-x86_64-uefi-cloudinit-r0.qcow2.sha512)
- `archlinux-cloudimg-x86_64`: sha256 `08754e28d91b1680086c6211ef4df13559e766fff7cdb4006489b14b5d281f08` (gnu file: https://geo.mirror.pkgbuild.com/images/latest/Arch-Linux-x86_64-cloudimg.qcow2.SHA256)
- `opensuse-leap-16.0-cloud-arm64`: sha256 `38f2fdf9681081a95c8e8fabd12509e57c780f2d4f1e67fcbcc832292d8bf878` (gnu file: https://download.opensuse.org/distribution/leap/16.0/appliances/Leap-16.0-Minimal-VM.aarch64-Cloud.qcow2.sha256)
- `opensuse-leap-16.0-cloud-x86_64`: sha256 `4a8cb7ba5457ebe875005cfd2ce7ebfd4ab4109c69b6ee6519f0a5e23ff5dd74` (gnu file: https://download.opensuse.org/distribution/leap/16.0/appliances/Leap-16.0-Minimal-VM.x86_64-Cloud.qcow2.sha256)
- `opensuse-tumbleweed-cloud-arm64`: sha256 `854a94040fdf699582745106f233dab3ca3a838aa8c851b4cf43f9f561a4c166` (gnu file: https://download.opensuse.org/ports/aarch64/tumbleweed/appliances/openSUSE-Tumbleweed-Minimal-VM.aarch64-Cloud.qcow2.sha256)
- `opensuse-tumbleweed-cloud-x86_64`: sha256 `374f925fc386a0fb3c30e3fbb8e083ade6441034bd37e1776123733d7266a4d9` (gnu file: https://download.opensuse.org/tumbleweed/appliances/openSUSE-Tumbleweed-Minimal-VM.x86_64-Cloud.qcow2.sha256)
- `rocky-10-genericcloud-arm64`: sha256 `457c8375e19496f43a25c4a6169fa11237536c53cef6f85a20ea3c5a751aa0f5` (bsd file: https://dl.rockylinux.org/pub/rocky/10/images/aarch64/Rocky-10-GenericCloud-Base.latest.aarch64.qcow2.CHECKSUM)
- `rocky-10-genericcloud-x86_64`: sha256 `9fc9e9ff16888bb68ac39b0392e25c9c92684d50c85f1cce6ab549363bbc4b48` (bsd file: https://dl.rockylinux.org/pub/rocky/10/images/x86_64/Rocky-10-GenericCloud-Base.latest.x86_64.qcow2.CHECKSUM)
- `rocky-9-genericcloud-arm64`: sha256 `24692a444f1f0b8bb95375c38c8b43f8099a115347623691be2c330b40c8a1fe` (bsd file: https://dl.rockylinux.org/pub/rocky/9/images/aarch64/Rocky-9-GenericCloud-Base.latest.aarch64.qcow2.CHECKSUM)
- `rocky-9-genericcloud-x86_64`: sha256 `92c206cc6f790c61583247eefe87890f8828420662c17cacf247cec78ab4eec8` (bsd file: https://dl.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud-Base.latest.x86_64.qcow2.CHECKSUM)
- `almalinux-10-genericcloud-arm64`: sha256 `ca65d1c32430acd84e9126c2e48f3b4110cd649a592712bfb570a6650e7e19e7` (gnu file: https://repo.almalinux.org/almalinux/10/cloud/aarch64/images/CHECKSUM)
- `almalinux-10-genericcloud-x86_64`: sha256 `cbee4726fc0f5a60694bb4f289003cc221e715dfbacebcce76b54daf386d8eca` (gnu file: https://repo.almalinux.org/almalinux/10/cloud/x86_64/images/CHECKSUM)
- `almalinux-9-genericcloud-arm64`: sha256 `15cf8257cb3c293268898309fe9f7d70e893b1eddff99bac9d7e53a2155d00ce` (gnu file: https://repo.almalinux.org/almalinux/9/cloud/aarch64/images/CHECKSUM)
- `almalinux-9-genericcloud-x86_64`: sha256 `25942b554efaac077e2f60d6bb27bd3332c171454cc21bbd33e5f79244d7570f` (gnu file: https://repo.almalinux.org/almalinux/9/cloud/x86_64/images/CHECKSUM)

### A.4 cloud-init recipes: from cloud image to an agent-drivable X11 desktop

**The target:** XFCE on **Xorg**, with LightDM **autologin** as `z`. It includes `xdotool`, `scrot` (or `maim`), `xclip`, a browser, a terminal and fonts. Screen blanking, DPMS and lockers are off. The resolution is 1280×800, or whatever VZ's scanout offers. `spice-vdagent` is included for the Spice clipboard port (`VZSpiceAgentPortAttachment`, see virtualization.md §2.1).

**How it plugs into `CloudInitConfig`:** leave `packages` empty and pass the blocks below as `runCommands`. `userData()` already emits `runcmd` as `[sh, -c, "<string>"]`, with the SSH enable and `/usr/local/sbin/zguest-install` first. So the agent is up before the desktop install starts. Each block is a POSIX `sh` script, and multi-line strings are fine because `yaml()` escapes newlines.

**On the host side:** set the virtio-gpu scanout to the size the agent should see, for example `VZVirtioGraphicsScanoutConfiguration(widthInPixels: 1280, heightInPixels: 800)`. For agent VMs, keep `automaticallyReconfiguresDisplay` **off** so screenshot coordinates stay stable. `virtio_gpu` reports the scanout size as its preferred mode, and Xorg's modesetting driver uses it. The `xrandr --mode 1280x800` line below is only a fallback, and it is UNVERIFIED on VZ.

#### A.4.1 Debian 13 (recommended desktop)

All package names were verified in trixie `main`, for both `binary-arm64` and `binary-amd64`. Versions on 2026-10-27:

| Package | Version |
|---|---|
| `xfce4` | 4.20.1 |
| `lightdm` | 1.32.0-6+b2 |
| `lightdm-gtk-greeter` | 2.0.9-1 |
| `xserver-xorg-core` | 2:21.1.16-1.3+deb13u3 (ships `/usr/bin/X` and `/usr/bin/Xorg`) |
| `xdotool` | 1:3.20160805.1-5.1 |
| `scrot` | 1.12.1-1 |
| `maim` | 5.8.0-1 |
| `xclip` | 0.13-4 |
| `firefox-esr` | 140.15.0esr-1~deb13u1 |
| `chromium` | 150.0.7871.181-1~deb13u1 |
| `spice-vdagent` | 0.22.1-4.1 |

`ydotool` is **not** in trixie (also noted in the Unix.SE question cited in A.7). The Wayland tools that are present are `grim` 1.4.0 and `wtype` 0.4.

Block 1, packages. Leave out Recommends. Recommends would pull in `light-locker`, Mesa Vulkan and video drivers and much more.

```sh
set -e
export DEBIAN_FRONTEND=noninteractive
echo 'man-db man-db/auto-update boolean false' | debconf-set-selections
apt_get() { apt-get -y -q -o DPkg::Lock::Timeout=600 -o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-unsafe-io "$@"; }
apt_get update
apt_get install --no-install-recommends \
  xserver-xorg-core xserver-xorg-input-libinput x11-xserver-utils \
  lightdm lightdm-gtk-greeter \
  xfce4 xfce4-terminal dbus-x11 dbus-user-session at-spi2-core adwaita-icon-theme \
  xdotool scrot xclip \
  firefox-esr fonts-dejavu-core fonts-liberation2 \
  spice-vdagent
```

Variations:

* Swap `firefox-esr` for `chromium` (adds about 43 MB).
* Add `maim x11-utils wmctrl` if the agent wants window queries (`xwininfo`, `xprop`, `wmctrl -l`).
* With `xserver-xorg` instead of `xserver-xorg-core` you get all input and video drivers, about 1 MB more.

Block 2, autologin, no blanking, 1280×800, and no XFCE first-run prompt. The same block works on Ubuntu, Fedora, EL9, openSUSE and Arch:

```sh
set -e
install -d /etc/lightdm/lightdm.conf.d
cat > /etc/lightdm/lightdm.conf.d/50-zcomputer.conf <<'EOF'
[Seat:*]
autologin-user=z
autologin-user-timeout=0
autologin-session=xfce
user-session=xfce
greeter-session=lightdm-gtk-greeter
xserver-command=X -s 0 -dpms
display-setup-script=/usr/local/sbin/zc-display-setup
EOF
cat > /usr/local/sbin/zc-display-setup <<'EOF'
#!/bin/sh
# Runs as root on LightDM's X server before the session. Prefer 1280x800, keep VZ's mode otherwise.
out=$(xrandr --query 2>/dev/null | awk '/ connected/ {print $1; exit}')
[ -n "$out" ] && xrandr --output "$out" --mode 1280x800 2>/dev/null
xset s off s noblank -dpms 2>/dev/null
exit 0
EOF
chmod 0755 /usr/local/sbin/zc-display-setup
getent group autologin >/dev/null || groupadd -r autologin
usermod -aG autologin z
x=/home/z/.config/xfce4/xfconf/xfce-perchannel-xml
mkdir -p "$x"
# Seeding the panel channel stops xfce4-panel's "first start" dialog.
[ -f /etc/xdg/xfce4/panel/default.xml ] && cp /etc/xdg/xfce4/panel/default.xml "$x/xfce4-panel.xml"
cat > "$x/xfce4-power-manager.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-power-manager" version="1.0">
  <property name="xfce4-power-manager" type="empty">
    <property name="dpms-enabled" type="bool" value="false"/>
    <property name="blank-on-ac" type="int" value="0"/>
  </property>
</channel>
EOF
cat > "$x/xfce4-screensaver.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-screensaver" version="1.0">
  <property name="saver" type="empty"><property name="enabled" type="bool" value="false"/></property>
  <property name="lock" type="empty"><property name="enabled" type="bool" value="false"/></property>
</channel>
EOF
chown -R z:z /home/z/.config
systemctl set-default graphical.target
systemctl enable lightdm.service 2>/dev/null || true
systemctl restart display-manager.service 2>/dev/null || systemctl restart lightdm.service
```

Notes:

* **Autologin group.** The `autologin` group is only *required* by Arch's LightDM PAM configuration. Everywhere else it is harmless.
* **Lockers and power manager.** The lean install brings no locker and no power manager. If you use `packages:` (with Recommends) instead, append `apt-get -y purge light-locker xfce4-screensaver || true`. The two xfconf files cover `xfce4-power-manager` and `xfce4-screensaver` if a user installs them later.
* **Blanking.** `X -s 0 -dpms` turns off the X server's own screensaver and DPMS, which by default blank the screen after 10 minutes.
* **Panel template.** `/etc/xdg/xfce4/panel/default.xml` is shipped by Debian's `xfce4-panel` (checked in the trixie file list).
* **Seed overrides.** None of this needs the generator's `desktopPackages`. Today that constant has no autologin and no browser, and it pulls in Recommends through `packages:`.

#### A.4.2 Ubuntu 24.04 (server or minimal image)

The same two blocks work, with one change: **the browser**. On noble, `firefox` (`1:1snap1-0ubuntu5`) and `chromium-browser` (`2:1snap1-0ubuntu2`) are transitional debs that install **snaps**. Use Mozilla's APT repository instead. It publishes **arm64** and amd64: its `Release` file lists `Architectures: all amd64 arm64 i386`, and the arm64 `Packages` file has `firefox` 157 and 158 builds.

The key file `https://packages.mozilla.org/apt/repo-signing-key.gpg` (1,022 bytes) has fingerprint `35BA A0B3 3E9E B396 F59C A838 C0BA 5CE6 DC63 15A3` and SHA-256 `3ecc63922b7795eb23fdc449ff9396f9114cb3cf186d6f5b53ad4cc3ebfbb11f` (checked with `gpg --show-keys` and `sha256sum`). The minimal image has no `gpg`, so the recipe pins the file hash instead.

Block 1 for Ubuntu replaces Debian's block 1:

```sh
set -e
export DEBIAN_FRONTEND=noninteractive
echo 'man-db man-db/auto-update boolean false' | debconf-set-selections
install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://packages.mozilla.org/apt/repo-signing-key.gpg -o /etc/apt/keyrings/packages.mozilla.org.asc
echo '3ecc63922b7795eb23fdc449ff9396f9114cb3cf186d6f5b53ad4cc3ebfbb11f  /etc/apt/keyrings/packages.mozilla.org.asc' | sha256sum -c -
echo 'deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.asc] https://packages.mozilla.org/apt mozilla main' > /etc/apt/sources.list.d/mozilla.list
printf 'Package: *\nPin: origin packages.mozilla.org\nPin-Priority: 1000\n' > /etc/apt/preferences.d/mozilla
apt_get() { apt-get -y -q -o DPkg::Lock::Timeout=600 -o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-unsafe-io "$@"; }
apt_get update
apt_get install --no-install-recommends \
  xserver-xorg-core xserver-xorg-input-libinput x11-xserver-utils \
  lightdm lightdm-gtk-greeter \
  xfce4 xfce4-terminal dbus-x11 dbus-user-session at-spi2-core adwaita-icon-theme \
  xdotool scrot xclip \
  firefox fonts-dejavu-core fonts-liberation2 \
  spice-vdagent
```

Notes:

* **The pin is required.** Ubuntu's shim has epoch `1:`, so without `Pin-Priority: 1000` apt would choose the snap shim over Mozilla's `157.0~build1`.
* **Verified names.** Every package name was verified in noble main and universe for arm64 (ports.ubuntu.com) and amd64. Some versions: `xfce4` 4.18, `lightdm` 1.30.0-0ubuntu14, `xdotool` 1:3.20160805.1-5build1, `scrot` 1.10-1build2, `maim` 5.7.4-2build2, `xclip` 0.13-3, `spice-vdagent` 0.22.1-4build3.
* **Wayland tools.** Unlike Debian, noble also has `ydotool` 0.1.8, `grim` and `wtype`.
* **Greeter.** Ubuntu's `lightdm` does not *depend* on a greeter. It only recommends `unity-greeter | lightdm-greeter`. That is why `lightdm-gtk-greeter` is listed and `greeter-session=` is set.
* **dpkg lock.** `DPkg::Lock::Timeout=600` covers the first-boot `apt-daily` or `unattended-upgrades` holding the lock.
* **Ubuntu 26.04.** The same recipe should work on 26.04: GNOME's X11 session is gone, but Xorg and XFCE stay in the archive. The package names were **not** re-checked against resolute (UNVERIFIED).

#### A.4.3 Fedora 44 or 43 Cloud

Verified in Fedora 44 Everything aarch64:

| Package | Version |
|---|---|
| `xorg-x11-server-Xorg` | 21.1.21 (still packaged, although GNOME is Wayland-only since F43) |
| `xfce4-session` | 4.20.3 |
| `lightdm` | 1.32.0 |
| `lightdm-gtk` | 2.0.8 |
| `xdotool` | 3.20211022.1 |
| `scrot` | 1.12.1 |
| `maim` | 5.8.1 |
| `xclip` | 0.13 |
| `firefox` | 150.0 |
| `chromium` | 146 |
| `spice-vdagent` | 0.23.0 |
| `ydotool` | 1.0.4 |
| `grim` | 1.5.0 |
| `wtype` | 0.4 |
| `dbus-x11` | 1.16.2 |
| `Thunar` | 4.20.7 |

The comps groups `@base-x` and `@xfce-desktop` also exist, but `@xfce-desktop` drags in `initial-setup-gui`, NetworkManager VPN plugins, `abrt-desktop` and similar, so list the packages instead:

```sh
set -e
dnf -y install --setopt=install_weak_deps=False \
  xorg-x11-server-Xorg xorg-x11-xinit xorg-x11-drv-libinput mesa-dri-drivers \
  lightdm lightdm-gtk \
  xfce4-session xfwm4 xfce4-panel xfdesktop xfce4-settings xfce4-terminal Thunar \
  dbus-x11 adwaita-icon-theme \
  xdotool scrot xclip \
  firefox dejavu-sans-fonts google-noto-sans-fonts \
  spice-vdagent
```

Then run block 2 from A.4.1 unchanged. `systemctl enable lightdm` creates the `display-manager.service` alias. The size of the Fedora closure was not computed. Expect roughly twice Debian's (UNVERIFIED).

#### A.4.4 Rocky Linux and AlmaLinux

**EL9.** Xorg comes from AppStream: `xorg-x11-server-Xorg` 1.20.11, `firefox` 140.10 ESR, `dbus-x11`, `spice-vdagent`, `xorg-x11-drv-libinput`. XFCE comes from EPEL 9: `xfce4-session` 4.18.3, `xfwm4`, `xfce4-panel`, `xfdesktop`, `xfce4-settings`, `xfce4-terminal`, `Thunar`, `lightdm` 1.30, `lightdm-gtk`, `xdotool`, `maim` 5.8.0, `xclip`. EPEL 9 has **no `scrot`**.

```sh
set -e
dnf -y install epel-release
crb enable || dnf config-manager --set-enabled crb
dnf -y install --setopt=install_weak_deps=False \
  xorg-x11-server-Xorg xorg-x11-xinit xorg-x11-drv-libinput \
  lightdm lightdm-gtk xfce4-session xfwm4 xfce4-panel xfdesktop xfce4-settings xfce4-terminal Thunar \
  dbus-x11 xdotool maim xclip firefox dejavu-sans-fonts spice-vdagent
```

Then run block 2. The `crb` helper ships with EL9's `epel-release` (UNVERIFIED in these images, hence the fallback).

**EL10 (Rocky 10, Alma 10): use these for terminal work only.** Rocky 10 AppStream has only `xorg-x11-server-Xwayland`, with no `xorg-x11-server-Xorg`. EPEL 10 (checked 2026-10-27) has no `xfce4-session`, `lightdm`, `xdotool`, `scrot`, `maim`, `ydotool`, `grim` or `wtype`. The only graphical option is GNOME on Wayland, which the agent cannot drive (A.7).

#### A.4.5 openSUSE Leap 16.0 and Tumbleweed

Verified in Leap 16.0 `repo/oss` (XFCE comes from the Package Hub `bp160` builds inside oss) and in Tumbleweed `ports/aarch64` oss: `xorg-x11-server`, `xf86-input-libinput`, `lightdm`, `lightdm-gtk-greeter`, `xfce4-session`, `xfwm4`, `xfce4-panel`, `xfdesktop`, `xfce4-settings`, `xfce4-terminal`, `thunar`, `xdotool`, `scrot`, `xclip`, `MozillaFirefox`, `spice-vdagent`, `xrandr`, `xset`, `kernel-default`, and the noarch `dejavu-fonts` and `adwaita-icon-theme`. `dbus-1-x11` exists in Leap 16 but **not** in Tumbleweed. Tumbleweed also has `ydotool` 1.0.4, `grim` and `wtype`.

The Minimal-VM images boot `kernel-default-base`, a reduced driver set. Whether it includes virtio-gpu and USB HID is UNVERIFIED, so install `kernel-default` and reboot once:

```sh
set -e
zypper --non-interactive install --no-recommends kernel-default \
  xorg-x11-server xf86-input-libinput xrandr xset lightdm lightdm-gtk-greeter \
  xfce4-session xfwm4 xfce4-panel xfdesktop xfce4-settings xfce4-terminal thunar \
  xdotool scrot xclip MozillaFirefox dejavu-fonts adwaita-icon-theme spice-vdagent
```

Then run block 2, then `reboot` (or put `power_state: {mode: reboot}` in the seed). This recipe has not been tried in a VM.

#### A.4.6 Alpine 3.24 (smallest, needs adaptations)

What is in Alpine 3.24 `main` and `community` for aarch64:

* XFCE and display: `xfce4` 4.20, `xfce4-terminal` 1.2.0, `lightdm` 1.32.0, `lightdm-gtk-greeter` 2.0.9, `xorg-server` 21.1.25 (the modesetting driver is built in, and there is no `xf86-video-modesetting` package), `xf86-input-libinput`, `xrandr`, `xset`.
* Session and services: `dbus`, `dbus-x11`, `elogind`, `polkit-elogind`.
* Agent tools: `xdotool` 4.20260303.1, `scrot` 2.0.0, `maim`, `xclip`, `grim`, `wtype`.
* Browsers: `firefox` 151, `firefox-esr` 140, `chromium` 155.
* Other: `font-dejavu`, `spice-vdagent`, `bash`, `sudo`, `cloud-init` 26.1.
* Missing: there is **no `ydotool`**.

The image differs from the others in three ways:

* It uses OpenRC, not systemd.
* It has no bash, but our seed sets `shell: /bin/bash`.
* XFCE lives in `community`.

Seed additions, using cloud-init's `apk_configure` module:

```yaml
apk_repos:
  preserve_repositories: false
  alpine_repo:
    version: 'v3.24'
    community_enabled: true
packages: [bash, sudo]
```

`runcmd` blocks. `zguest-install` has already copied `/usr/local/bin/zguest` before it failed at the systemd unit.

```sh
set -e
grep -q '^hvc0:' /etc/inittab || echo 'hvc0::respawn:/sbin/getty -L hvc0 115200 vt100' >> /etc/inittab
kill -HUP 1
cat > /etc/init.d/zguest <<'EOF'
#!/sbin/openrc-run
description="Z Computer guest agent"
supervisor=supervise-daemon
command=/usr/local/bin/zguest
respawn_delay=2
depend() { need localmount; after net; }
EOF
chmod 0755 /etc/init.d/zguest
modprobe vmw_vsock_virtio_transport 2>/dev/null || true
rc-update add zguest default && rc-service zguest start
```

```sh
set -e
setup-xorg-base
apk add xfce4 xfce4-terminal lightdm lightdm-gtk-greeter dbus dbus-x11 elogind polkit-elogind \
  xdotool scrot xclip firefox font-dejavu adwaita-icon-theme spice-vdagent
# ...then block 2 from A.4.1 with the systemctl lines replaced by:
rc-update add dbus default && rc-update add elogind default && rc-update add lightdm default
rc-service dbus start && rc-service elogind start && rc-service lightdm start
```

`setup-xorg-base` comes from `alpine-conf`. It installs Xorg and switches device management to eudev, which libinput needs. All of A.4.6 is **UNVERIFIED in a VM**. Alpine 3.24's new Limine bootloader is also UNVERIFIED under VZ firmware. The 3.22.7 `uefi` image uses GRUB-EFI, which is the same layout as lima's tested `nocloud_` images.

#### A.4.7 Arch Linux (x86_64 hosts only)

Verified on archlinux.org (extra): `xorg-server` 21.1.25, `xf86-input-libinput`, `xorg-xrandr`, `xorg-xset`, `lightdm` 1.33.1, `lightdm-gtk-greeter` 2.0.9, `xfce4` (a group), `xfce4-terminal`, `xdotool` 4.20260303.1, `scrot` 2.0.0, `xclip`, `firefox` 159, `ttf-dejavu`, `spice-vdagent`.

```sh
set -e
pacman -Syu --noconfirm --needed xorg-server xf86-input-libinput xorg-xrandr xorg-xset \
  lightdm lightdm-gtk-greeter xfce4 xfce4-terminal xdotool scrot xclip firefox ttf-dejavu spice-vdagent
```

Then run block 2. On Arch, the `autologin` group is required for LightDM autologin.

### A.5 First-boot time (estimate)

There was no Mac to measure on, so these are **estimates**.

Method: the dependency closure was resolved from the real indexes, taking the first alternative of each dependency, minus the packages the image already has (from its manifest or JSON).

| Image + recipe | New packages | Download | Installed | Estimated power-on to autologin desktop |
|---|---|---|---|---|
| Debian 13 + A.4.1 (no Recommends) | 246 | **199 MB** (arm64), 217 MB (amd64) | 836 MB | **≈ 3–5 min** |
| Debian 13 with `packages:` (Recommends on) | 952 | 576 MB | 2.1 GB | ≈ 7–10 min |
| Ubuntu 24.04 server + A.4.2 (Mozilla Firefox, no Recommends) | 199 | **171 MB** | 681 MB | **≈ 3–5 min** |
| Ubuntu 24.04 server, Recommends on | 649 | 380 MB | 1.5 GB | ≈ 6–8 min |
| Ubuntu 24.04 **minimal** + A.4.2 | 246 | 197 MB | 794 MB | ≈ 3–5 min |
| Ubuntu `xubuntu-core` metapackage (for comparison) | 277 / 770 | 145 / 411 MB | 517 MB / 1.4 GB | — |

The time estimate assumes about 50–100 Mbit/s and 4 vCPUs on Apple silicon. It adds about 30 s for boot and growpart, about 15 s for `apt-get update`, the download time, and 1–2 min of dpkg unpacking and triggers (`--force-unsafe-io`, man-db auto-update off). Terminal-only images need no install: they are ready about 30–60 s after power-on, which is when `zguest` answers.

**Disk:** give the desktop VMs at least **12 GB**. Debian's 3 GiB image plus 0.85 GB of desktop leaves little room for browser caches.

### A.6 Ranking

1. **Agent desktop: Debian 13 generic (qcow2) + A.4.1.**
   * Runners-up: Ubuntu 24.04 + A.4.2, which needs Mozilla's repository for a non-snap browser, and Fedora 44 + A.4.3, which has newer XFCE 4.20 and Firefox.
   * On **Intel Macs older than macOS 15.5**, use Ubuntu 24.04 instead: its 6.8 kernel avoids the pkeys bug.
2. **Terminal / dev: Ubuntu 24.04 server.**
   * Runners-up: Fedora 44 Cloud (newest toolchains) and Debian 13 generic.
   * For RHEL-compatible work, Rocky 10 or Alma 10 (terminal only).
3. **Smallest download: Ubuntu 24.04 minimal** (224 MB arm64, 260 MB amd64).
   * Alpine 3.24.3 is smaller (192 MB / 158 MB) and could be an "advanced" entry once the OpenRC bits in A.4.6 are in the app.
   * Debian 13 `genericcloud` (337 MB) is small but headless.

Not offered as cloud images:

* **Arch Linux ARM:** there is no official image.
* **openSUSE MicroOS:** `openSUSE-MicroOS.aarch64-ContainerHost-OpenStack-Cloud.qcow2`, 561,840,128 B, exists, but its root is read-only. It needs `transactional-update` and reboots, so `runcmd`-style installs do not fit.
* **Fedora 42:** end of life, and gone from `releases/`.
* **Leap 15.6:** end of life.

### A.7 Wayland vs X11 for the agent

**Should the agent desktop avoid Wayland? Yes.**

* **xdotool's README:** "If you are using Wayland, please be aware this software will not work correctly … Typing, window searching, and many other functions of xdotool do not work, and it is unclear if they could ever work." It points Wayland users to ydotool and dotool ([github.com/jordansissel/xdotool](https://github.com/jordansissel/xdotool)). Through XWayland, xdotool only sees X11 clients, not native Wayland windows or the shell.
* **`ydotool`** works on every compositor, because it writes to `/dev/uinput` and the compositor sees a real device. It needs root and `ydotoold`, it has no window search, and it has no reliable Unicode typing. It is also not packaged in Debian 13 or Alpine 3.24.
* **`wtype`** needs the `virtual-keyboard` protocol, which only wlroots compositors implement.

**Does GNOME on Wayland block screenshot tools without a portal? Yes.**

* **`grim`** fails with `compositor doesn't support wlr-screencopy-unstable-v1`, and `wtype` with `Compositor does not support the virtual keyboard protocol`. These are the outputs reported on Debian 13 / GNOME Shell 48.4 ([Unix.SE 800680](https://unix.stackexchange.com/questions/800680)).
* The accepted answer there explains why: Mutter deliberately does not implement the wlroots protocols. Screen capture "is only accessible through the XDG Portal system … where the portal … always shows a GUI confirmation dialog unless previous access has been remembered."
* **GNOME Shell 41** restricted its private `org.gnome.Shell.Screenshot` D-Bus API to allow-listed callers (gnome-shell!1970). Third-party callers get `AccessDenied: Screenshot is not allowed`, and even `gnome-screenshot`'s CLI mode broke ([gnome-screenshot#179](https://gitlab.gnome.org/GNOME/gnome-screenshot/-/issues/179), [GIMP#7591](https://gitlab.gnome.org/GNOME/gimp/-/issues/7591)). GNOME's position is that apps should use the `org.freedesktop.portal.Screenshot` portal.
* For a headless agent, the portal's first-use permission dialog is a blocker, unless the permission is pre-seeded in the permission store. That is fragile and UNVERIFIED.

**X11 sessions that are gone:**

* **Fedora 43+:** GNOME is Wayland-only, and `gnome-session-xsession` was removed ([Fedora change](https://fedoraproject.org/wiki/Changes/WaylandOnlyGNOME)).
* **Ubuntu 26.04 / GNOME 50:** the GNOME X11 session no longer exists. Canonical says "the GNOME desktop session can no longer run as an X.org session" ([Linuxiac](https://linuxiac.com/ubuntu-26-04-lts-resolute-raccoon-released/)).
* **RHEL/Rocky/Alma 10:** these ship no Xorg server at all.
* **Pop!_OS 24.04:** COSMIC is Wayland-only.

In all of these, only XWayland apps can be driven with xdotool.

**What the app should do:**

* Offer only X11 desktops (XFCE, MATE, Cinnamon, LXQt-X11) as **agent** desktops.
* Mark GNOME, KDE Wayland and COSMIC as "manual use".
* On a Wayland guest, fall back to host-side capture (virtualization.md §4.3) and host-side `NSEvent` injection (§4.4). Both work on any guest, because they act on the VZ view rather than inside the guest.

---

## B. Installer ISOs (the user installs by hand in the VM window)

### B.1 How VZ boots an ISO, and what was checked

Apple's recipe attaches the ISO as `VZUSBMassStorageDeviceConfiguration`, a USB disk with 512-byte blocks, and boots `VZEFIBootLoader` (virtualization.md §2.1). The firmware therefore sees a **disk**, not a CD. Most ISOs are "isohybrid", so they carry an MBR or GPT with an EFI system partition, and they boot like a USB stick.

For each ISO we read:

* the partition table (first 64 KiB plus the GPT entries);
* the El Torito boot catalogue, and whether the EFI image contains `BOOTAA64.EFI` (arm64) or `BOOTX64.EFI` (x86_64).

Results for arm64:

| ISO (arm64) | Partition table | El Torito EFI image |
|---|---|---|
| Ubuntu 24.04.5 desktop and server | MBR, type `0xEF` partition | BOOTAA64 |
| Debian 13.7 netinst and DVD-1 | MBR, `0xEF` | BOOTAA64 |
| Kali 2026.3 installer | MBR, `0xEF` | BOOTAA64 |
| Fedora 44 Workstation and Xfce | GPT with ESP ("Appended2") | BOOTAA64 |
| Alpine 3.24.3 virt and standard | GPT with ESP | BOOTAA64 |
| openSUSE TW Xfce Live, Leap 16 offline | GPT with ESP | BOOTAA64 |
| openSUSE TW DVD and NET | MBR with a FAT32 (`0x0C`) partition, no `0xEF` | one entry, platform 0 |
| **NixOS 26.05 minimal** | **none (no 0x55AA signature)** | BOOTAA64 |
| **Rocky 10.2 minimal and DVD** | **none** | BOOTAA64 |
| **Pop!_OS 24.04 arm64** | **none** | BOOTAA64 |
| **elementary OS 8.1 arm64** | **none** | not read |

The four ISOs with no partition table can only boot if the firmware parses El Torito on a USB disk. EDK2 does ([ElTorito.c](https://github.com/tianocore/edk2/blob/master/MdeModulePkg/Universal/Disk/PartitionDxe/ElTorito.c)). Apple's VZ firmware is **UNVERIFIED**. The openSUSE DVD and NET should boot from the FAT32 partition, because UEFI firmware mounts any FAT volume and looks for `\EFI\BOOT\BOOTAA64.EFI` (also UNVERIFIED on VZ).

The x86_64 ISOs we checked (Ubuntu desktop, Debian netinst, Arch, Mint) are all hybrid with BIOS plus EFI(x64) entries. Arch and Mint also carry an ia32 EFI loader. **VZ has no legacy BIOS**, so only their EFI path matters.

### B.2 URLs, sizes and checksums (all HTTP 200 on 2026-10-27)

| id | arch | size | checksum | URL |
|---|---|---|---|---|
| `ubuntu-24.04.5-desktop-arm64-iso` | arm64 | 3,967,463,424 B (3,967 MB) | sha256 `2be09ca883921bff6d8e6b0bfbafd13e32436553b7086f33bce3a4c5bad8bd14` | https://cdimage.ubuntu.com/ubuntu/releases/24.04/release/ubuntu-24.04.5-desktop-arm64.iso |
| `ubuntu-24.04.5.1-desktop-x86_64-iso` | x86_64 | 6,250,332,160 B (6,250 MB) | sha256 `4da4a0c9035da8e68a59a838674f403f0a54472c78a83b4fb7f78d03588f85a7` | https://releases.ubuntu.com/24.04/ubuntu-24.04.5.1-desktop-amd64.iso |
| `ubuntu-24.04.5-server-arm64-iso` | arm64 | 3,825,512,448 B (3,826 MB) | sha256 `f12484464c7d4d73e2167e0a7dbda1e669f8fae9bcf778dc0944937034b320cb` | https://cdimage.ubuntu.com/ubuntu/releases/24.04/release/ubuntu-24.04.5-live-server-arm64.iso |
| `ubuntu-24.04.5-server-x86_64-iso` | x86_64 | 4,080,486,400 B (4,080 MB) | sha256 `97f3d7ffb032c3eb3b23d2c8be9cc76e60c2c1f2c0146ba5ba9fe01cafae0fd8` | https://releases.ubuntu.com/24.04/ubuntu-24.04.5-live-server-amd64.iso |
| `ubuntu-26.04.1-desktop-arm64-iso` | arm64 | 4,154,798,080 B (4,155 MB) | sha256 `c54d196489d3c867975fb3bbb72ca52ec2e137456e305481f81096304e4d2517` | https://cdimage.ubuntu.com/ubuntu/releases/26.04/release/ubuntu-26.04.1-desktop-arm64.iso |
| `ubuntu-26.04.1-desktop-x86_64-iso` | x86_64 | 6,482,409,472 B (6,482 MB) | sha256 `601e30fbf5d97759367c632e2c33630665039b7e2158fd068403da3ccf1bda1f` | https://releases.ubuntu.com/26.04/ubuntu-26.04.1-desktop-amd64.iso |
| `debian-13.7.0-netinst-arm64-iso` | arm64 | 735,358,976 B (735 MB) | sha512 `cff08e2f29c2846f0503fe57ad1085b5067f29acab444acdf7cdf5b10f2a11140a0e87828e4ffeb9828d188053690467ebe50151c142551d6053fc3288808b86` | https://cdimage.debian.org/debian-cd/current/arm64/iso-cd/debian-13.7.0-arm64-netinst.iso |
| `debian-13.7.0-dvd1-arm64-iso` | arm64 | 3,993,284,608 B (3,993 MB) | sha512 `2a2160f9777959b21386edf30940e3d66879e1f1ea193580303538ad87b2b8e8642bc2cb81743d256f79a8b35517449f0a4e234b7de6074222d16813f7c284bd` | https://cdimage.debian.org/debian-cd/current/arm64/iso-dvd/debian-13.7.0-arm64-DVD-1.iso |
| `debian-13.7.0-netinst-x86_64-iso` | x86_64 | 792,723,456 B (793 MB) | sha512 `ef04d0276850d70e4aaec0b55003628660e9631b26e35215a70ab3c8c707294a4b12731bc73c75a932902f703a7c278310ca99df28d6b36fb06d5618d8d0f678` | https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/debian-13.7.0-amd64-netinst.iso |
| `debian-13.7.0-dvd1-x86_64-iso` | x86_64 | 3,992,977,408 B (3,993 MB) | sha512 `305cc7a3f0d4e293ff979cc6c047d7fe46454853a0f170a0520acd8aab37c2f8839969c817afac2b4324ef5944e0038502b7fcca5dfcd48b5b77544ef1f14cee` | https://cdimage.debian.org/debian-cd/current/amd64/iso-dvd/debian-13.7.0-amd64-DVD-1.iso |
| `fedora-44-workstation-arm64-iso` | arm64 | 2,689,781,760 B (2,690 MB) | sha256 `162ba3c552a2d241c7c63ec26777af0255ee1b5a135adc0be986ceed999933ef` | https://download.fedoraproject.org/pub/fedora/linux/releases/44/Workstation/aarch64/iso/Fedora-Workstation-Live-44-1.7.aarch64.iso |
| `fedora-44-workstation-x86_64-iso` | x86_64 | 2,851,612,672 B (2,852 MB) | sha256 `1620295f6a00c27c3208f0c00b8ece4eab1ec69b9002152d97488bf26a426ddf` | https://download.fedoraproject.org/pub/fedora/linux/releases/44/Workstation/x86_64/iso/Fedora-Workstation-Live-44-1.7.x86_64.iso |
| `fedora-44-xfce-arm64-iso` | arm64 | 2,666,934,272 B (2,667 MB) | sha256 `c707af264df01b70fdf7abfd4fea44ee2942a6080d4353f4e61b23fe951c049e` | https://download.fedoraproject.org/pub/fedora/linux/releases/44/Spins/aarch64/iso/Fedora-Xfce-Live-44-1.7.aarch64.iso |
| `fedora-44-xfce-x86_64-iso` | x86_64 | 2,928,986,112 B (2,929 MB) | sha256 `55ea8cb52ac16e62f436e37f9fdb4e978d7b9f75814a9d42e8b69d05e3b496ad` | https://download.fedoraproject.org/pub/fedora/linux/releases/44/Spins/x86_64/iso/Fedora-Xfce-Live-44-1.7.x86_64.iso |
| `kali-2026.3-installer-arm64-iso` | arm64 | 4,051,513,344 B (4,052 MB) | sha256 `c4a7f9bf3a0ff07c8263fe9e9b0edba0cc3d9b408f1d8f06c066df0afce23072` | https://cdimage.kali.org/kali-2026.3/kali-linux-2026.3-installer-arm64.iso |
| `kali-2026.3-installer-x86_64-iso` | x86_64 | 5,047,031,808 B (5,047 MB) | sha256 `db9cbed33edb45727d16911813c2434fcd1419585007884153be22a03b30ec2f` | https://cdimage.kali.org/kali-2026.3/kali-linux-2026.3-installer-amd64.iso |
| `kali-2026.3-netinst-arm64-iso` | arm64 | 603,238,400 B (603 MB) | sha256 `a986c7fe0f8e887a77e7ea9f868da88eae04e7ac780ae75e6b702f243b63bf8d` | https://cdimage.kali.org/kali-2026.3/kali-linux-2026.3-installer-netinst-arm64.iso |
| `linuxmint-22.3-xfce-x86_64-iso` | x86_64 | 3,033,710,592 B (3,034 MB) | sha256 `45a835b5dddaf40e84d776549e0b19b3fbd49673b6cc6434ebddbfcd217df776` | https://mirrors.edge.kernel.org/linuxmint/stable/22.3/linuxmint-22.3-xfce-64bit.iso |
| `linuxmint-22.3-cinnamon-x86_64-iso` | x86_64 | 3,091,660,800 B (3,092 MB) | sha256 `a081ab202cfda17f6924128dbd2de8b63518ac0531bcfe3f1a1b88097c459bd4` | https://mirrors.edge.kernel.org/linuxmint/stable/22.3/linuxmint-22.3-cinnamon-64bit.iso |
| `archlinux-x86_64-iso` | x86_64 | 1,640,497,152 B (1,640 MB) | sha256 `684ded26c63240ff4a41e8c25ee84ea6da233f557364821f13d12c2b0a9059a5` | https://geo.mirror.pkgbuild.com/iso/latest/archlinux-x86_64.iso |
| `alpine-3.24.3-virt-arm64-iso` | arm64 | 93,452,288 B (93 MB) | sha256 `e34603080e942e9ebc670689eee77dd7a6551c823a6ff5a299e308ded268098f` | https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/aarch64/alpine-virt-3.24.3-aarch64.iso |
| `alpine-3.24.3-standard-arm64-iso` | arm64 | 394,645,504 B (395 MB) | sha256 `d4438d8973b7a4c50a2ee25d1555c537c1e6e91e25db28b7b683aa79c9ddba8f` | https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/aarch64/alpine-standard-3.24.3-aarch64.iso |
| `alpine-3.24.3-virt-x86_64-iso` | x86_64 | 70,254,592 B (70 MB) | sha256 `cdc1bc0efc64d8d611bf3733f54868172a545888dfd726f518bf279bcb0ff1af` | https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/x86_64/alpine-virt-3.24.3-x86_64.iso |
| `alpine-3.24.3-standard-x86_64-iso` | x86_64 | 370,147,328 B (370 MB) | sha256 `1629ffe7308d4f3d3eeeed3a97d09ad62293f6d37ef3e483a7306077fdac12be` | https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/x86_64/alpine-standard-3.24.3-x86_64.iso |
| `nixos-26.05-minimal-arm64-iso` | arm64 | 1,821,014,016 B (1,821 MB) | sha256 `8203bbfbdab0c3ed148dead9fed855a41b21f2c87e74d3a21413bd565b04bdfe` | https://releases.nixos.org/nixos/26.05/nixos-26.05.12707.718f670e8453/nixos-minimal-26.05.12707.718f670e8453-aarch64-linux.iso |
| `nixos-26.05-minimal-x86_64-iso` | x86_64 | 1,744,830,464 B (1,745 MB) | sha256 `12f093ce7bf7e9747c67730ee3cc7b22713912382e8d3d6f27ef6b19afd8c800` | https://releases.nixos.org/nixos/26.05/nixos-26.05.12707.718f670e8453/nixos-minimal-26.05.12707.718f670e8453-x86_64-linux.iso |
| `opensuse-tumbleweed-dvd-arm64-iso` | arm64 | 4,235,493,376 B (4,235 MB) | sha256 `3276133a3f691997f27e628531f959091c666fb37632675e54e64e84804d53ed` | https://download.opensuse.org/ports/aarch64/tumbleweed/iso/openSUSE-Tumbleweed-DVD-aarch64-Current.iso |
| `opensuse-tumbleweed-net-arm64-iso` | arm64 | 450,416,640 B (450 MB) | sha256 `33916688227949b0691502ed35f10329ce0047a7312239573bb99a93ce941f82` | https://download.opensuse.org/ports/aarch64/tumbleweed/iso/openSUSE-Tumbleweed-NET-aarch64-Current.iso |
| `opensuse-tumbleweed-xfce-live-arm64-iso` | arm64 | 1,400,252,416 B (1,400 MB) | sha256 `721bbfeccaf72f9526017985bec3f546734392a37a6b3e7362e93c72a6d3c85c` | https://download.opensuse.org/ports/aarch64/tumbleweed/iso/openSUSE-Tumbleweed-XFCE-Live-aarch64-Current.iso |
| `opensuse-tumbleweed-dvd-x86_64-iso` | x86_64 | 4,697,620,480 B (4,698 MB) | sha256 `b9422cb5640b4bd1a124c769749f1024f608149ef2747228bcbcce98bf9f97c6` | https://download.opensuse.org/tumbleweed/iso/openSUSE-Tumbleweed-DVD-x86_64-Current.iso |
| `opensuse-leap-16.0-offline-arm64-iso` | arm64 | 4,642,045,952 B (4,642 MB) | sha512 `a6328f07434875bd62ab57400829429ad0a908a0b2085a2323faf657bd7fecc6e1b7852531e562302a57e861c90b92935085d8352ebfa7d33a2cda5b96e577d4` | https://download.opensuse.org/distribution/leap/16.0/offline/Leap-16.0-offline-installer-aarch64.install.iso |
| `opensuse-leap-16.0-offline-x86_64-iso` | x86_64 | 4,538,236,928 B (4,538 MB) | sha512 `94411793a1878b3558211c8bbe4f3823c3c5212cc2dd9f9e4532a18be7eddd3be14db5a3bb47a2f36dd957e190ea706cd45af16bce218dfc00f71e64a8469971` | https://download.opensuse.org/distribution/leap/16.0/offline/Leap-16.0-offline-installer-x86_64.install.iso |
| `rocky-10-minimal-arm64-iso` | arm64 | 2,397,044,736 B (2,397 MB) | sha256 `1d1c21199df32f6d17eedb4f713ee0d089b49294401a364b640fcf4ffab45f35` | https://dl.rockylinux.org/pub/rocky/10/isos/aarch64/Rocky-10-latest-aarch64-minimal.iso |
| `rocky-10-dvd-arm64-iso` | arm64 | 9,659,678,720 B (9,660 MB) | sha256 `3b8253987604df1bc5e1c33c838ff3ee9ce4a8f02ed9e27e300ecff58c0c9588` | https://dl.rockylinux.org/pub/rocky/10/isos/aarch64/Rocky-10-latest-aarch64-dvd.iso |
| `rocky-10-minimal-x86_64-iso` | x86_64 | 2,072,444,928 B (2,072 MB) | sha256 `aac6ac3ce781b91a91ce78463405f66c611a5dca4b3840c79e5e01d97302f6c8` | https://dl.rockylinux.org/pub/rocky/10/isos/x86_64/Rocky-10-latest-x86_64-minimal.iso |
| `popos-24.04-generic-arm64-iso` | arm64 | 2,888,884,224 B (2,889 MB) | sha256 `7b4cce0e92dc5c903464e7e7c33760c4417f1400165e9ecfcd064fbceb68ef22` | https://iso.pop-os.org/24.04/arm64/generic/3/pop-os_24.04_arm64_generic_3.iso |
| `popos-24.04-generic-x86_64-iso` | x86_64 | 3,526,164,480 B (3,526 MB) | sha256 `8d78e500fc95da765a91cddcf2ab7ba71ce4e7997e4f008456d4d872ee8f8221` | https://iso.pop-os.org/24.04/amd64/generic/28/pop-os_24.04_amd64_generic_28.iso |
| `zorin-18.1-core-x86_64-iso` | x86_64 | 3,909,091,328 B (3,909 MB) | sha256 `44649b97bd307fc4c8529205d098ebbf98575a1e1ba2ee7d7005b697af1721d5` | https://mirrors.edge.kernel.org/zorinos-isos/18/Zorin-OS-18.1-Core-64-bit.iso |

### B.3 Per-distribution notes

| ISO | Arch availability | UEFI boot under VZ (evidence) | Desktop and display server | xdotool/scrot afterwards | Known VZ pitfalls |
|---|---|---|---|---|---|
| **Ubuntu Desktop 24.04.5** | **Official arm64 ISO exists** (`ubuntu-24.04.5-desktop-arm64.iso` in cdimage `releases/24.04/release/`) plus amd64 | Hybrid with ESP. UTM users run it with "Use Apple Virtualization" ([guide](https://gist.github.com/wenboown/4ede6dcb76851049d414aef705a73bfe)). Apple's own GUI-Linux sample targets Ubuntu, Fedora and Debian ISOs (virtualization.md §2.5) | GNOME 46, Wayland by default; "Ubuntu on Xorg" is still available | yes (`apt install xdotool scrot`), but only in the Xorg session (or set `WaylandEnable=false` in `/etc/gdm3/custom.conf`) | Installer output goes to tty, not hvc0; the GDM login screen blocks automation until autologin is set |
| **Ubuntu Server 24.04.5** | arm64 and amd64 (`+largemem` arm64 variant too) | Hybrid with ESP | none (subiquity TUI) | yes | Prefer the cloud image; the ISO only makes sense for a manual install |
| Ubuntu Desktop 26.04.1 | arm64 and amd64 | Hybrid (not inspected beyond HEAD) | GNOME 50, **Wayland-only** | only for XWayland apps | Intel hosts need macOS 15.5+ |
| **Debian 13.7 netinst / DVD-1** | arm64 and amd64 (no arm64 *live* ISO: `current-live` is amd64 only) | Hybrid with `0xEF` partition; Apple's sample uses Debian | tasksel: pick **Xfce** (X11) instead of the GNOME default | yes | File name changes at each point release (13.7.0 today) |
| **Fedora Workstation 44 Live** | aarch64 and x86_64 | GPT with ESP. A UTM user reports the Fedora "Display output is not active" boot problem is fixed by enabling Apple Virtualization ([UTM#6961](https://github.com/utmapp/UTM/issues/6961), 2026-07-25) | GNOME 50, **Wayland-only** since F43 | xdotool is useless here; `ydotool` is packaged | In the UTM#6961 thread (QEMU backend, display broken), the LUKS passphrase could only be typed on the serial console |
| **Fedora Xfce 44 Live** (spin) | aarch64 and x86_64 | GPT with ESP | **XFCE on X11**, LightDM | yes (`dnf install xdotool scrot`) | The agent-friendly Fedora ISO |
| **Kali 2026.3 installer** | **arm64** and amd64 (plus a 603 MB arm64 netinst) | Hybrid with `0xEF`, BOOTAA64. The VZ-based [arm64vm](https://github.com/pauloipf/arm64vm) "started with Kali Linux" (ISO attached as USB, UEFI). UTM *QEMU* users hit a black installer screen that a serial device works around ([UTM docs](https://docs.getutm.app/guides/kali/)) | XFCE on X11 (Kali default) | yes, from the Kali repo | Debian-installer: use the text "Install" entry if the graphical installer stays black (UNVERIFIED on VZ) |
| **Linux Mint 22.3** | **x86_64 only, no arm64** | Hybrid ESP plus BIOS | Cinnamon, MATE or Xfce, all X11 | yes | Intel Macs only |
| **Arch Linux 2026.10.01** | **x86_64 only.** Arch Linux ARM has **no ISO**, only rootfs tarballs at os.archlinuxarm.org | Hybrid ESP plus BIOS | none (archinstall TUI) | yes | Intel Macs only, and macOS 15.5+ (kernel ≥ 6.12) |
| **Alpine 3.24.3 virt / standard** | aarch64 and x86_64 | GPT with ESP. Lima's `alpine-iso` template boots alpine-lima ISOs (built from these) under vz, "requires macOS Ventura 13.3 or later" | none; `setup-desktop xfce` afterwards gives XFCE on X11 | yes (`xdotool`, `scrot` in community) | OpenRC: no getty on hvc0 by default; `virt` is 89 MiB |
| **NixOS 26.05 minimal** | aarch64 and x86_64 (the channel aliases for aarch64 `gnome` and `plasma6` ISOs also resolve; their files were not HEAD-checked) | **No MBR/GPT**, El Torito only: **UNVERIFIED** on VZ. NixOS-on-UTM guides mostly use the QEMU backend; one ([gist](https://gist.github.com/samelie/db65e7decbfdb74d748d44860840b51f)) cites Apple-backend projects | none (console); X11 XFCE through `services.xserver` in `configuration.nix` | yes (`environment.systemPackages`) | Same guides note "no ACPI shutdown support" |
| **openSUSE Tumbleweed** DVD / NET / Xfce Live | aarch64 (`ports/`) and x86_64 | DVD/NET: FAT32 partition, no `0xEF`. Xfce Live: GPT ESP. UTM#6961 has a Tumbleweed report of the same QEMU display issue | Installer offers KDE (Wayland), GNOME (Wayland), **Xfce (X11)** | yes | `-Current.iso.sha256` names the Snapshot file |
| openSUSE Leap 16.0 offline (Agama) | aarch64 and x86_64 | GPT with ESP | Installer desktop choices not checked; Xfce 4.20 (X11) and Xorg packages are in Leap 16 oss | yes | — |
| **Rocky Linux 10.2** minimal / DVD | aarch64 and x86_64 (x86-64-v3 only) | **No MBR/GPT**, El Torito only: **UNVERIFIED**. arm64vm lists Rocky/Alma ISOs as targets, without test results | GNOME **Wayland-only** (no Xorg in EL10) | xdotool not packaged in EL10/EPEL 10 | Prefer the Rocky 10 cloud image for terminal use |
| **Pop!_OS 24.04 LTS** | **arm64** ("generic" build 3, made for Thelio Astra) and amd64 | **No MBR/GPT**: UNVERIFIED | COSMIC, **Wayland-only** | not usable for automation | Checksum only from System76's build API |
| **elementary OS 8.1** | **arm64 and amd64** since 8.1 (Dec 2025) | **No MBR/GPT** (arm64 checked): UNVERIFIED | Pantheon; Wayland session by default since 8.1 | X11 session still selectable (UNVERIFIED) | **Not in `images.json`**: the only download links are tokenized and expire (`dl.elementaryos.org/<base64 expiry>/…`, then a pre-signed R2 URL), so the app cannot pin them. Files on 2026-10-27: `elementaryos-8.1-stable-arm64.20260219.iso` 3,191,691,264 B, `…-amd64.20260219.iso` 3,335,405,568 B |
| **Zorin OS 18.1** | **x86_64 only** (Core, Lite, Education) | Hybrid (not inspected) | Core: GNOME 46 (Wayland default, X11 available); **Lite: Xfce/X11** | yes | Intel Macs only |

---

## C. Windows

Windows is **not supported** by Virtualization.framework, and the catalogue should say so plainly instead of offering an ISO slot.

Apple describes the framework as one to "create virtual machines and run macOS and Linux-based operating systems" ([developer.apple.com/documentation/virtualization](https://developer.apple.com/documentation/virtualization)). An Apple engineer stated in May 2025 that "Windows 11 isn't supported by Virtualization Framework in macOS Sequoia. Other virtual machine software based on Hypervisor Framework do support Windows 11". Asked about macOS 27 in May 2026, Apple DTS would not comment beyond "If and when this changes, you should be informed via FB17582343" ([forum thread 784051](https://developer.apple.com/forums/thread/784051)).

VZ also has no TPM device and no Windows virtio-gpu driver (virtualization.md §2.6). Running Windows needs a Hypervisor.framework/QEMU product such as UTM's QEMU backend, Parallels or VMware Fusion. That is out of scope for Z Computer v1.

Suggested catalogue text: *"Windows can't run here. Apple's Virtualization framework only runs macOS and Linux guests."*

---

## Sources

**Image indexes and sums files.** All fetched 2026-10-27; the exact URLs are in `images.json`.

* Debian: cloud.debian.org, cdimage.debian.org.
* Ubuntu: cloud-images.ubuntu.com, cdimage.ubuntu.com, releases.ubuntu.com.
* Fedora: dl.fedoraproject.org.
* Alpine: dl-cdn.alpinelinux.org, alpinelinux.org/cloud.
* Arch: geo.mirror.pkgbuild.com.
* openSUSE: download.opensuse.org.
* Rocky: dl.rockylinux.org.
* AlmaLinux: repo.almalinux.org.
* Kali: cdimage.kali.org.
* Linux Mint and Zorin: mirrors.edge.kernel.org.
* NixOS: channels.nixos.org, releases.nixos.org.
* Pop!_OS: api.pop-os.org, iso.pop-os.org.
* elementary OS: elementary.io.

**Package indexes:**

* Debian: `deb.debian.org/debian/dists/trixie/main/binary-{arm64,amd64}/Packages.xz`.
* Ubuntu: `ports.ubuntu.com/ubuntu-ports/dists/noble/{main,universe}/binary-arm64/Packages.xz` and `archive.ubuntu.com/ubuntu/dists/noble/{main,universe}/binary-amd64/Packages.xz`.
* Mozilla: `packages.mozilla.org/apt/dists/mozilla/{Release,main/binary-arm64/Packages}`.
* Fedora: Fedora 44 Everything `Packages/` and comps.
* EPEL and EL: EPEL 9 and 10 `Packages/`, Rocky 9 and 10 AppStream/BaseOS.
* openSUSE: Leap 16.0 and Tumbleweed `repo/oss` jsontable.
* Alpine: `APKINDEX.tar.gz` (v3.24 main and community, aarch64).
* Arch: archlinux.org packages JSON.
* Debian file list: packages.debian.org (`xserver-xorg-core`, `xfce4-panel` file lists).

**Kernels:**

* Debian `config.cloud`: [salsa](https://salsa.debian.org/kernel-team/linux/-/raw/debian/6.12/trixie/debian/config/config.cloud).
* Ubuntu `generic.inclusion-list`: [launchpad](https://git.launchpad.net/~ubuntu-kernel/ubuntu/+source/linux/+git/noble/plain/debian.master/control.d/generic.inclusion-list).
* Alpine `virt.aarch64.config`: [aports mirror](https://github.com/alpinelinux/aports/blob/master/main/linux-lts/virt.aarch64.config).
* arch-boxes [build.sh](https://github.com/archlinux/arch-boxes/blob/master/build.sh).

**VZ evidence:**

* lima: [vmType docs](https://lima-vm.io/docs/config/vmtype/), `templates/_images/*.yaml`, [lima#3334](https://github.com/lima-vm/lima/issues/3334).
* UTM: [UTM#6961](https://github.com/utmapp/UTM/issues/6961), [UTM Linux guest docs](https://docs.getutm.app/guest-support/linux/).
* [arm64vm](https://github.com/pauloipf/arm64vm).
* EDK2 [ElTorito.c](https://github.com/tianocore/edk2/blob/master/MdeModulePkg/Universal/Disk/PartitionDxe/ElTorito.c).
* systemd [getty generator man page](https://www.freedesktop.org/software/systemd/man/latest/systemd-getty-generator.html) and [source](https://github.com/systemd/systemd/blob/main/src/getty-generator/getty-generator.c).

**Wayland and X11:**

* [xdotool README](https://github.com/jordansissel/xdotool).
* [Unix.SE 800680](https://unix.stackexchange.com/questions/800680).
* [gnome-screenshot#179](https://gitlab.gnome.org/GNOME/gnome-screenshot/-/issues/179) and [GIMP#7591](https://gitlab.gnome.org/GNOME/gimp/-/issues/7591).
* [Fedora WaylandOnlyGNOME](https://fedoraproject.org/wiki/Changes/WaylandOnlyGNOME).
* [Ubuntu 26.04 release (Linuxiac)](https://linuxiac.com/ubuntu-26-04-lts-resolute-raccoon-released/).

**elementary OS 8.1 arm64:** [It's FOSS](https://itsfoss.com/news/elementary-os-8-1-release/). **Pop!_OS arm64:** System76 build API.

**Windows:** [Apple forum 784051](https://developer.apple.com/forums/thread/784051), [Virtualization docs](https://developer.apple.com/documentation/virtualization).

---

## images.json

* One object per line, 71 entries: 33 `cloud`, 38 `iso`. Validated with `python -I` (`json.load`, unique `id`s, no `UNVERIFIED` checksum).
* `checksum.style` is one of:
  * `gnu`: `hex  name`;
  * `bsd`: `SHA256 (name) = hex`;
  * `bare`: the hash only;
  * `api-json`: the `sha_sum` field.
* `checksum.lookupName` is set where the sums file names a different file than the URL (openSUSE `-Current`).
* `cloudUser` is the distribution's default user. Our seed creates `z` instead.
* Sizes are bytes, from the 2026-10-27 response.

```json
[
{"id": "debian-13-generic-arm64", "name": "Debian 13 \"trixie\" generic (arm64)", "group": "cloud", "distro": "debian", "version": "13", "arch": "arm64", "url": "https://cloud.debian.org/images/cloud/trixie/latest/debian-13-generic-arm64.qcow2", "sizeBytes": 431882240, "checksum": {"algo": "sha512", "value": "5fc0eba340b16651f1b4163f3249b0c8fb91acd2bc5898b609181ee47ac50a5bf3e24166ba8647279db05e883883e22e9308193ef4ad75293cb254b919e358d8", "url": "https://cloud.debian.org/images/cloud/trixie/latest/SHA512SUMS", "style": "gnu"}, "format": "qcow2", "desktop": "xfce-x11", "recommended": "desktop", "cloudUser": "debian", "notes": ["qcow2 v3, zlib clusters, 3 GiB virtual: same image as the .raw at 1/7 of the download", "full linux-image-arm64 6.12 (virtio-gpu, USB HID, vsock)", "'latest' alias is rebuilt in place; re-read SHA512SUMS at download time", "Intel hosts: kernel 6.12 needs macOS 15.5+ under VZ (lima#3334) or 'nopku'"], "verifiedOn": "2026-10-27"},
{"id": "debian-13-generic-x86_64", "name": "Debian 13 \"trixie\" generic (amd64)", "group": "cloud", "distro": "debian", "version": "13", "arch": "x86_64", "url": "https://cloud.debian.org/images/cloud/trixie/latest/debian-13-generic-amd64.qcow2", "sizeBytes": 438894592, "checksum": {"algo": "sha512", "value": "5bd891c6e62d01639f52a5587b72a4607421e445732214be787dba6043cf9797a6ff90bed982aada6a6c7e619f1f956d961c4fad76757171abd607920aac098a", "url": "https://cloud.debian.org/images/cloud/trixie/latest/SHA512SUMS", "style": "gnu"}, "format": "qcow2", "desktop": "xfce-x11", "recommended": "desktop", "cloudUser": "debian", "notes": ["qcow2 v3, zlib clusters, 3 GiB virtual", "Intel hosts: kernel 6.12 needs macOS 15.5+ under VZ (lima#3334) or 'nopku'"], "verifiedOn": "2026-10-27"},
{"id": "debian-13-generic-arm64-raw", "name": "Debian 13 \"trixie\" generic RAW (arm64)", "group": "cloud", "distro": "debian", "version": "13", "arch": "arm64", "url": "https://cloud.debian.org/images/cloud/trixie/latest/debian-13-generic-arm64.raw", "sizeBytes": 3221225472, "checksum": {"algo": "sha512", "value": "58b265ee1286c7ad8a9c96dcde3dd2825c0b6e7e5dd26baea1c9ece7e46da6d6dee8a2d800a6c6eb882e53e87771168bc4786894a3d7e48fe608907ce61499d1", "url": "https://cloud.debian.org/images/cloud/trixie/latest/SHA512SUMS", "style": "gnu"}, "format": "raw", "desktop": "xfce-x11", "recommended": null, "cloudUser": "debian", "notes": ["what ImageCatalog.swift uses today: 3 GiB transfer; prefer the qcow2 entry"], "verifiedOn": "2026-10-27"},
{"id": "debian-13-generic-x86_64-raw", "name": "Debian 13 \"trixie\" generic RAW (amd64)", "group": "cloud", "distro": "debian", "version": "13", "arch": "x86_64", "url": "https://cloud.debian.org/images/cloud/trixie/latest/debian-13-generic-amd64.raw", "sizeBytes": 3221225472, "checksum": {"algo": "sha512", "value": "7ddcbc835b6d946e2cbe578bdd2142ce12d979fed124a13986089ab9eee9fa1e4c66d6ffd35416b473a200c8757272bb065e9b764179ba92519fbe463451c27e", "url": "https://cloud.debian.org/images/cloud/trixie/latest/SHA512SUMS", "style": "gnu"}, "format": "raw", "desktop": "xfce-x11", "recommended": null, "cloudUser": "debian", "notes": ["what ImageCatalog.swift uses today: 3 GiB transfer; prefer the qcow2 entry"], "verifiedOn": "2026-10-27"},
{"id": "debian-13-genericcloud-arm64", "name": "Debian 13 \"trixie\" genericcloud, headless (arm64)", "group": "cloud", "distro": "debian", "version": "13", "arch": "arm64", "url": "https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-arm64.qcow2", "sizeBytes": 336723968, "checksum": {"algo": "sha512", "value": "71aa5d5dbcb3d9ecfe96bc3f6dd41b6805a0a41c852204a32747d230b64b95912297fb453b11a6031fd54d84a0a0a430e137d07e6986dc9ebc9d41483be003c4", "url": "https://cloud.debian.org/images/cloud/trixie/latest/SHA512SUMS", "style": "gnu"}, "format": "qcow2", "desktop": null, "recommended": null, "cloudUser": "debian", "notes": ["cloud kernel: CONFIG_DRM, CONFIG_HID and CONFIG_USB_SUPPORT are not set, so no display and no USB keyboard/mouse under VZ: shell/zguest/serial only"], "verifiedOn": "2026-10-27"},
{"id": "debian-13-genericcloud-x86_64", "name": "Debian 13 \"trixie\" genericcloud, headless (amd64)", "group": "cloud", "distro": "debian", "version": "13", "arch": "x86_64", "url": "https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2", "sizeBytes": 341114880, "checksum": {"algo": "sha512", "value": "3ace18e33bdd036edb49d1f79342bd01d2ab980e35194edb0b410435cd543538d286a0bd13bbb0835f7862306e3d385ce2f6a70d8ecf0bd961111166adbc1b8e", "url": "https://cloud.debian.org/images/cloud/trixie/latest/SHA512SUMS", "style": "gnu"}, "format": "qcow2", "desktop": null, "recommended": null, "cloudUser": "debian", "notes": ["cloud kernel without DRM/HID/USB: headless only"], "verifiedOn": "2026-10-27"},
{"id": "ubuntu-24.04-server-arm64", "name": "Ubuntu 24.04 LTS server cloud image (arm64)", "group": "cloud", "distro": "ubuntu", "version": "24.04", "arch": "arm64", "url": "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-arm64.img", "sizeBytes": 616522752, "checksum": {"algo": "sha256", "value": "50e24e1fb79e89116e939d90aa7738f7af48c442fa1bc2510131e0b39c50348e", "url": "https://cloud-images.ubuntu.com/noble/current/SHA256SUMS", "style": "gnu"}, "format": "qcow2", "desktop": "xfce-x11", "recommended": "terminal", "cloudUser": "ubuntu", "notes": ["kernel 6.8 linux-generic; linux-modules includes virtio-gpu, usbhid, vsock", "Firefox/Chromium debs are snap shims: use Mozilla's APT repo for a deb Firefox", "serial 20261017 build"], "verifiedOn": "2026-10-27"},
{"id": "ubuntu-24.04-server-x86_64", "name": "Ubuntu 24.04 LTS server cloud image (amd64)", "group": "cloud", "distro": "ubuntu", "version": "24.04", "arch": "x86_64", "url": "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img", "sizeBytes": 621284352, "checksum": {"algo": "sha256", "value": "04e8f2461a16a44e78a370284471f29616cdd9baf1893df25807b71f985b6c94", "url": "https://cloud-images.ubuntu.com/noble/current/SHA256SUMS", "style": "gnu"}, "format": "qcow2", "desktop": "xfce-x11", "recommended": "terminal", "cloudUser": "ubuntu", "notes": ["kernel 6.8: unaffected by the Intel kernel-6.12 VZ boot bug"], "verifiedOn": "2026-10-27"},
{"id": "ubuntu-24.04-minimal-arm64", "name": "Ubuntu 24.04 LTS minimal cloud image (arm64)", "group": "cloud", "distro": "ubuntu", "version": "24.04", "arch": "arm64", "url": "https://cloud-images.ubuntu.com/minimal/releases/noble/release/ubuntu-24.04-minimal-cloudimg-arm64.img", "sizeBytes": 224002048, "checksum": {"algo": "sha256", "value": "6e971c7935c62c8ea7796b085e4ea038e2301a067f8c853e154133f8df192c85", "url": "https://cloud-images.ubuntu.com/minimal/releases/noble/release/SHA256SUMS", "style": "gnu"}, "format": "qcow2", "desktop": "xfce-x11", "recommended": "small", "cloudUser": "ubuntu", "notes": ["274 packages, no snapd; same 6.8 generic kernel as the server image", "minimised: no man pages; 'unminimize' restores them"], "verifiedOn": "2026-10-27"},
{"id": "ubuntu-24.04-minimal-x86_64", "name": "Ubuntu 24.04 LTS minimal cloud image (amd64)", "group": "cloud", "distro": "ubuntu", "version": "24.04", "arch": "x86_64", "url": "https://cloud-images.ubuntu.com/minimal/releases/noble/release/ubuntu-24.04-minimal-cloudimg-amd64.img", "sizeBytes": 260177920, "checksum": {"algo": "sha256", "value": "3839f148c5a3b4a736e7dbb0af75594743fa5ebee2a202424ba1a32e5d3b5d2c", "url": "https://cloud-images.ubuntu.com/minimal/releases/noble/release/SHA256SUMS", "style": "gnu"}, "format": "qcow2", "desktop": "xfce-x11", "recommended": "small", "cloudUser": "ubuntu", "notes": ["no snapd; kernel 6.8"], "verifiedOn": "2026-10-27"},
{"id": "ubuntu-26.04-server-arm64", "name": "Ubuntu 26.04 LTS server cloud image (arm64)", "group": "cloud", "distro": "ubuntu", "version": "26.04", "arch": "arm64", "url": "https://cloud-images.ubuntu.com/resolute/current/resolute-server-cloudimg-arm64.img", "sizeBytes": 940373504, "checksum": {"algo": "sha256", "value": "8eb876c2ccc4b6ff89e4a65d511815923b285e04503ba465809bf587f763da24", "url": "https://cloud-images.ubuntu.com/resolute/current/SHA256SUMS", "style": "gnu"}, "format": "qcow2", "desktop": "xfce-x11", "recommended": null, "cloudUser": "ubuntu", "notes": ["newer LTS; desktop package names not re-verified for resolute (UNVERIFIED)", "Intel hosts: needs macOS 15.5+ (kernel >= 6.12)"], "verifiedOn": "2026-10-27"},
{"id": "ubuntu-26.04-server-x86_64", "name": "Ubuntu 26.04 LTS server cloud image (amd64)", "group": "cloud", "distro": "ubuntu", "version": "26.04", "arch": "x86_64", "url": "https://cloud-images.ubuntu.com/resolute/current/resolute-server-cloudimg-amd64.img", "sizeBytes": 859090944, "checksum": {"algo": "sha256", "value": "5645d0318ad21f643ebb1ac4567514620e9893380b07b0201fda163baa5b7eb5", "url": "https://cloud-images.ubuntu.com/resolute/current/SHA256SUMS", "style": "gnu"}, "format": "qcow2", "desktop": "xfce-x11", "recommended": null, "cloudUser": "ubuntu", "notes": ["Intel hosts: needs macOS 15.5+ (kernel >= 6.12)"], "verifiedOn": "2026-10-27"},
{"id": "fedora-44-cloud-arm64", "name": "Fedora 44 Cloud Base Generic (aarch64)", "group": "cloud", "distro": "fedora", "version": "44", "arch": "arm64", "url": "https://download.fedoraproject.org/pub/fedora/linux/releases/44/Cloud/aarch64/images/Fedora-Cloud-Base-Generic-44-1.7.aarch64.qcow2", "sizeBytes": 528154624, "checksum": {"algo": "sha256", "value": "55c60a3b80d3616a08705afd0459e75fe9f03c54aba7a46e4002a41a72fa0d5b", "url": "https://dl.fedoraproject.org/pub/fedora/linux/releases/44/Cloud/aarch64/images/Fedora-Cloud-44-1.7-aarch64-CHECKSUM", "style": "bsd"}, "format": "qcow2", "desktop": "xfce-x11", "recommended": null, "cloudUser": "fedora", "notes": ["5 GiB virtual, btrfs root", "download.fedoraproject.org redirects to a mirror", "CHECKSUM is PGP-clearsigned BSD-style 'SHA256 (file) = hex'", "used by lima's fedora-44 template (vz default)"], "verifiedOn": "2026-10-27"},
{"id": "fedora-44-cloud-x86_64", "name": "Fedora 44 Cloud Base Generic (x86_64)", "group": "cloud", "distro": "fedora", "version": "44", "arch": "x86_64", "url": "https://download.fedoraproject.org/pub/fedora/linux/releases/44/Cloud/x86_64/images/Fedora-Cloud-Base-Generic-44-1.7.x86_64.qcow2", "sizeBytes": 583729152, "checksum": {"algo": "sha256", "value": "28680fe5b371a5a82ebf43a31926e086a168e59949d03969c5093e7071f90b7f", "url": "https://dl.fedoraproject.org/pub/fedora/linux/releases/44/Cloud/x86_64/images/Fedora-Cloud-44-1.7-x86_64-CHECKSUM", "style": "bsd"}, "format": "qcow2", "desktop": "xfce-x11", "recommended": null, "cloudUser": "fedora", "notes": ["Intel hosts: needs macOS 15.5+ under VZ (lima#3334)"], "verifiedOn": "2026-10-27"},
{"id": "fedora-43-cloud-arm64", "name": "Fedora 43 Cloud Base Generic (aarch64)", "group": "cloud", "distro": "fedora", "version": "43", "arch": "arm64", "url": "https://download.fedoraproject.org/pub/fedora/linux/releases/43/Cloud/aarch64/images/Fedora-Cloud-Base-Generic-43-1.6.aarch64.qcow2", "sizeBytes": 544997376, "checksum": {"algo": "sha256", "value": "66031aea9ec61e6d0d5bba12b9454e80ca94e8a79c913d37ded4c60311705b8b", "url": "https://dl.fedoraproject.org/pub/fedora/linux/releases/43/Cloud/aarch64/images/Fedora-Cloud-43-1.6-aarch64-CHECKSUM", "style": "bsd"}, "format": "qcow2", "desktop": "xfce-x11", "recommended": null, "cloudUser": "fedora", "notes": ["Fedora 42 is EOL and gone from releases/; 43 is supported until about four weeks after 45 ships"], "verifiedOn": "2026-10-27"},
{"id": "fedora-43-cloud-x86_64", "name": "Fedora 43 Cloud Base Generic (x86_64)", "group": "cloud", "distro": "fedora", "version": "43", "arch": "x86_64", "url": "https://download.fedoraproject.org/pub/fedora/linux/releases/43/Cloud/x86_64/images/Fedora-Cloud-Base-Generic-43-1.6.x86_64.qcow2", "sizeBytes": 583335936, "checksum": {"algo": "sha256", "value": "846574c8a97cd2d8dc1f231062d73107cc85cbbbda56335e264a46e3a6c8ab2f", "url": "https://dl.fedoraproject.org/pub/fedora/linux/releases/43/Cloud/x86_64/images/Fedora-Cloud-43-1.6-x86_64-CHECKSUM", "style": "bsd"}, "format": "qcow2", "desktop": "xfce-x11", "recommended": null, "cloudUser": "fedora", "notes": [], "verifiedOn": "2026-10-27"},
{"id": "alpine-3.24.3-cloudinit-arm64", "name": "Alpine 3.24.3 cloud-init (aarch64)", "group": "cloud", "distro": "alpine", "version": "3.24.3", "arch": "arm64", "url": "https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/cloud/alpine-3.24.3-aarch64-cloudinit-r0.qcow2", "sizeBytes": 191823872, "checksum": {"algo": "sha512", "value": "9eb2a1639df38123af47915938a4ebd2943ae543ac535c69e790e441ee11a74257ae80ad6ff10be22fdfacdf9e2b5510e0e2e6a65beaa7329d1f506ac213bebc", "url": "https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/cloud/alpine-3.24.3-aarch64-cloudinit-r0.qcow2.sha512", "style": "bare"}, "format": "qcow2", "desktop": "xfce-x11", "recommended": null, "cloudUser": "alpine", "notes": ["smallest image; Limine bootloader (new in 3.24), NoCloud supported per the image's .yaml", "OpenRC, no systemd: the zguest systemd installer fails; needs an OpenRC service", "no bash by default: our seed's shell /bin/bash must be installed", "linux-virt has virtio-gpu, vsock, virtiofs modules", "boot under VZ UNVERIFIED (lima tests 3.23 nocloud images)"], "verifiedOn": "2026-10-27"},
{"id": "alpine-3.24.3-cloudinit-x86_64", "name": "Alpine 3.24.3 cloud-init (x86_64)", "group": "cloud", "distro": "alpine", "version": "3.24.3", "arch": "x86_64", "url": "https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/cloud/alpine-3.24.3-x86_64-cloudinit-r0.qcow2", "sizeBytes": 157810688, "checksum": {"algo": "sha512", "value": "cf1b95fb4b77d32a9e5c3d02290e203f24907550192fe21819e1abaa28541dab3fe025aa2afa1b952773e3d8e6ea5593bc2e6bfcf398bff886fe5c6f2785f308", "url": "https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/cloud/alpine-3.24.3-x86_64-cloudinit-r0.qcow2.sha512", "style": "bare"}, "format": "qcow2", "desktop": "xfce-x11", "recommended": null, "cloudUser": "alpine", "notes": ["OpenRC; Limine (BIOS+UEFI); boot under VZ UNVERIFIED"], "verifiedOn": "2026-10-27"},
{"id": "alpine-3.22.7-uefi-cloudinit-arm64", "name": "Alpine 3.22.7 UEFI cloud-init (aarch64)", "group": "cloud", "distro": "alpine", "version": "3.22.7", "arch": "arm64", "url": "https://dl-cdn.alpinelinux.org/alpine/v3.22/releases/cloud/alpine-3.22.7-aarch64-uefi-cloudinit-r0.qcow2", "sizeBytes": 206176256, "checksum": {"algo": "sha512", "value": "c73ef67891b118f4939cdc45c2d891cbca77305f6e6073cb0d702c82aaf7eef3934cf81274c6b9f350efc03e904926316771aebfc3b67a677d890dd36d162401", "url": "https://dl-cdn.alpinelinux.org/alpine/v3.22/releases/cloud/alpine-3.22.7-aarch64-uefi-cloudinit-r0.qcow2.sha512", "style": "bare"}, "format": "qcow2", "desktop": "xfce-x11", "recommended": null, "cloudUser": "alpine", "notes": ["arm64 EFI cloud image as asked; GRUB-EFI generation; lima's alpine-3.22/3.23 templates use the equivalent nocloud_ images with vz"], "verifiedOn": "2026-10-27"},
{"id": "alpine-3.22.7-uefi-cloudinit-x86_64", "name": "Alpine 3.22.7 UEFI cloud-init (x86_64)", "group": "cloud", "distro": "alpine", "version": "3.22.7", "arch": "x86_64", "url": "https://dl-cdn.alpinelinux.org/alpine/v3.22/releases/cloud/alpine-3.22.7-x86_64-uefi-cloudinit-r0.qcow2", "sizeBytes": 183107584, "checksum": {"algo": "sha512", "value": "876ae6f11342cf45f46a1a748ff8d2b2ea220e9ec3b7c3774e1cfa0e90590e9fdff8d7808008eeee2787ea2e3ecdd5376ca733573c34ff0454882cdb22519600", "url": "https://dl-cdn.alpinelinux.org/alpine/v3.22/releases/cloud/alpine-3.22.7-x86_64-uefi-cloudinit-r0.qcow2.sha512", "style": "bare"}, "format": "qcow2", "desktop": "xfce-x11", "recommended": null, "cloudUser": "alpine", "notes": ["Alpine kernels lack CONFIG_X86_INTEL_MEMORY_PROTECTION_KEYS, so the Intel 6.12 VZ bug does not apply (lima#3334)"], "verifiedOn": "2026-10-27"},
{"id": "archlinux-cloudimg-x86_64", "name": "Arch Linux cloud image (x86_64)", "group": "cloud", "distro": "arch", "version": "rolling-20261015", "arch": "x86_64", "url": "https://geo.mirror.pkgbuild.com/images/latest/Arch-Linux-x86_64-cloudimg.qcow2", "sizeBytes": 576680960, "checksum": {"algo": "sha256", "value": "08754e28d91b1680086c6211ef4df13559e766fff7cdb4006489b14b5d281f08", "url": "https://geo.mirror.pkgbuild.com/images/latest/Arch-Linux-x86_64-cloudimg.qcow2.SHA256", "style": "gnu"}, "format": "qcow2", "desktop": "xfce-x11", "recommended": null, "cloudUser": "arch", "notes": ["x86_64 only: there is no official Arch Linux ARM cloud image (lima falls back to a 2022 community build)", "GPT with BIOS-boot + ESP, grub-install --target=x86_64-efi --removable", "Intel hosts: needs macOS 15.5+ (kernel >= 6.12)"], "verifiedOn": "2026-10-27"},
{"id": "opensuse-leap-16.0-cloud-arm64", "name": "openSUSE Leap 16.0 Minimal-VM Cloud (aarch64)", "group": "cloud", "distro": "opensuse-leap", "version": "16.0", "arch": "arm64", "url": "https://download.opensuse.org/distribution/leap/16.0/appliances/Leap-16.0-Minimal-VM.aarch64-Cloud.qcow2", "sizeBytes": 319029248, "checksum": {"algo": "sha256", "value": "38f2fdf9681081a95c8e8fabd12509e57c780f2d4f1e67fcbcc832292d8bf878", "url": "https://download.opensuse.org/distribution/leap/16.0/appliances/Leap-16.0-Minimal-VM.aarch64-Cloud.qcow2.sha256", "style": "gnu"}, "format": "qcow2", "desktop": "xfce-x11", "recommended": null, "cloudUser": null, "notes": ["kernel-default-base (reduced driver set): install kernel-default for a desktop (virtio-gpu in -base UNVERIFIED)", "Leap 15.6 reached end of life; use 16.0", "used by lima's opensuse-leap-16 template"], "verifiedOn": "2026-10-27"},
{"id": "opensuse-leap-16.0-cloud-x86_64", "name": "openSUSE Leap 16.0 Minimal-VM Cloud (x86_64)", "group": "cloud", "distro": "opensuse-leap", "version": "16.0", "arch": "x86_64", "url": "https://download.opensuse.org/distribution/leap/16.0/appliances/Leap-16.0-Minimal-VM.x86_64-Cloud.qcow2", "sizeBytes": 339871232, "checksum": {"algo": "sha256", "value": "4a8cb7ba5457ebe875005cfd2ce7ebfd4ab4109c69b6ee6519f0a5e23ff5dd74", "url": "https://download.opensuse.org/distribution/leap/16.0/appliances/Leap-16.0-Minimal-VM.x86_64-Cloud.qcow2.sha256", "style": "gnu"}, "format": "qcow2", "desktop": "xfce-x11", "recommended": null, "cloudUser": null, "notes": ["Intel hosts: needs macOS 15.5+ (kernel 6.12)"], "verifiedOn": "2026-10-27"},
{"id": "opensuse-tumbleweed-cloud-arm64", "name": "openSUSE Tumbleweed Minimal-VM Cloud (aarch64)", "group": "cloud", "distro": "opensuse-tumbleweed", "version": "rolling", "arch": "arm64", "url": "https://download.opensuse.org/ports/aarch64/tumbleweed/appliances/openSUSE-Tumbleweed-Minimal-VM.aarch64-Cloud.qcow2", "sizeBytes": 288803840, "checksum": {"algo": "sha256", "value": "854a94040fdf699582745106f233dab3ca3a838aa8c851b4cf43f9f561a4c166", "url": "https://download.opensuse.org/ports/aarch64/tumbleweed/appliances/openSUSE-Tumbleweed-Minimal-VM.aarch64-Cloud.qcow2.sha256", "style": "gnu"}, "format": "qcow2", "desktop": "xfce-x11", "recommended": null, "cloudUser": null, "notes": ["rolling snapshot: the file behind the alias changes several times a week", "has ydotool, grim, wtype, xdotool in oss"], "verifiedOn": "2026-10-27"},
{"id": "opensuse-tumbleweed-cloud-x86_64", "name": "openSUSE Tumbleweed Minimal-VM Cloud (x86_64)", "group": "cloud", "distro": "opensuse-tumbleweed", "version": "rolling", "arch": "x86_64", "url": "https://download.opensuse.org/tumbleweed/appliances/openSUSE-Tumbleweed-Minimal-VM.x86_64-Cloud.qcow2", "sizeBytes": 316864512, "checksum": {"algo": "sha256", "value": "374f925fc386a0fb3c30e3fbb8e083ade6441034bd37e1776123733d7266a4d9", "url": "https://download.opensuse.org/tumbleweed/appliances/openSUSE-Tumbleweed-Minimal-VM.x86_64-Cloud.qcow2.sha256", "style": "gnu"}, "format": "qcow2", "desktop": "xfce-x11", "recommended": null, "cloudUser": null, "notes": ["rolling; Intel hosts need macOS 15.5+"], "verifiedOn": "2026-10-27"},
{"id": "rocky-10-genericcloud-arm64", "name": "Rocky Linux 10 GenericCloud Base (aarch64)", "group": "cloud", "distro": "rocky", "version": "10.2", "arch": "arm64", "url": "https://dl.rockylinux.org/pub/rocky/10/images/aarch64/Rocky-10-GenericCloud-Base.latest.aarch64.qcow2", "sizeBytes": 469368832, "checksum": {"algo": "sha256", "value": "457c8375e19496f43a25c4a6169fa11237536c53cef6f85a20ea3c5a751aa0f5", "url": "https://dl.rockylinux.org/pub/rocky/10/images/aarch64/Rocky-10-GenericCloud-Base.latest.aarch64.qcow2.CHECKSUM", "style": "bsd"}, "format": "qcow2", "desktop": null, "recommended": null, "cloudUser": "rocky", "notes": ["terminal only for agents: EL10 ships no Xorg server (only Xwayland) and EPEL 10 has no XFCE, LightDM or xdotool", "10 GiB virtual", "used by lima's rocky-10 template"], "verifiedOn": "2026-10-27"},
{"id": "rocky-10-genericcloud-x86_64", "name": "Rocky Linux 10 GenericCloud Base (x86_64)", "group": "cloud", "distro": "rocky", "version": "10.2", "arch": "x86_64", "url": "https://dl.rockylinux.org/pub/rocky/10/images/x86_64/Rocky-10-GenericCloud-Base.latest.x86_64.qcow2", "sizeBytes": 544997376, "checksum": {"algo": "sha256", "value": "9fc9e9ff16888bb68ac39b0392e25c9c92684d50c85f1cce6ab549363bbc4b48", "url": "https://dl.rockylinux.org/pub/rocky/10/images/x86_64/Rocky-10-GenericCloud-Base.latest.x86_64.qcow2.CHECKSUM", "style": "bsd"}, "format": "qcow2", "desktop": null, "recommended": null, "cloudUser": "rocky", "notes": ["requires x86-64-v3 CPUs"], "verifiedOn": "2026-10-27"},
{"id": "rocky-9-genericcloud-arm64", "name": "Rocky Linux 9 GenericCloud Base (aarch64)", "group": "cloud", "distro": "rocky", "version": "9.8", "arch": "arm64", "url": "https://dl.rockylinux.org/pub/rocky/9/images/aarch64/Rocky-9-GenericCloud-Base.latest.aarch64.qcow2", "sizeBytes": 519831552, "checksum": {"algo": "sha256", "value": "24692a444f1f0b8bb95375c38c8b43f8099a115347623691be2c330b40c8a1fe", "url": "https://dl.rockylinux.org/pub/rocky/9/images/aarch64/Rocky-9-GenericCloud-Base.latest.aarch64.qcow2.CHECKSUM", "style": "bsd"}, "format": "qcow2", "desktop": "xfce-x11", "recommended": null, "cloudUser": "rocky", "notes": ["XFCE/LightDM/xdotool from EPEL 9 + Xorg from AppStream; scrot is not in EPEL 9, use maim"], "verifiedOn": "2026-10-27"},
{"id": "rocky-9-genericcloud-x86_64", "name": "Rocky Linux 9 GenericCloud Base (x86_64)", "group": "cloud", "distro": "rocky", "version": "9.8", "arch": "x86_64", "url": "https://dl.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud-Base.latest.x86_64.qcow2", "sizeBytes": 645988352, "checksum": {"algo": "sha256", "value": "92c206cc6f790c61583247eefe87890f8828420662c17cacf247cec78ab4eec8", "url": "https://dl.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud-Base.latest.x86_64.qcow2.CHECKSUM", "style": "bsd"}, "format": "qcow2", "desktop": "xfce-x11", "recommended": null, "cloudUser": "rocky", "notes": [], "verifiedOn": "2026-10-27"},
{"id": "almalinux-10-genericcloud-arm64", "name": "AlmaLinux 10 GenericCloud (aarch64)", "group": "cloud", "distro": "almalinux", "version": "10.2", "arch": "arm64", "url": "https://repo.almalinux.org/almalinux/10/cloud/aarch64/images/AlmaLinux-10-GenericCloud-latest.aarch64.qcow2", "sizeBytes": 478937088, "checksum": {"algo": "sha256", "value": "ca65d1c32430acd84e9126c2e48f3b4110cd649a592712bfb570a6650e7e19e7", "url": "https://repo.almalinux.org/almalinux/10/cloud/aarch64/images/CHECKSUM", "style": "gnu"}, "format": "qcow2", "desktop": null, "recommended": null, "cloudUser": "almalinux", "notes": ["terminal only for agents (EL10: no Xorg, no XFCE in EPEL 10)", "used by lima's almalinux-10 template"], "verifiedOn": "2026-10-27"},
{"id": "almalinux-10-genericcloud-x86_64", "name": "AlmaLinux 10 GenericCloud (x86_64)", "group": "cloud", "distro": "almalinux", "version": "10.2", "arch": "x86_64", "url": "https://repo.almalinux.org/almalinux/10/cloud/x86_64/images/AlmaLinux-10-GenericCloud-latest.x86_64.qcow2", "sizeBytes": 497876992, "checksum": {"algo": "sha256", "value": "cbee4726fc0f5a60694bb4f289003cc221e715dfbacebcce76b54daf386d8eca", "url": "https://repo.almalinux.org/almalinux/10/cloud/x86_64/images/CHECKSUM", "style": "gnu"}, "format": "qcow2", "desktop": null, "recommended": null, "cloudUser": "almalinux", "notes": ["AlmaLinux also ships an x86_64_v2 build for older CPUs"], "verifiedOn": "2026-10-27"},
{"id": "almalinux-9-genericcloud-arm64", "name": "AlmaLinux 9 GenericCloud (aarch64)", "group": "cloud", "distro": "almalinux", "version": "9.8", "arch": "arm64", "url": "https://repo.almalinux.org/almalinux/9/cloud/aarch64/images/AlmaLinux-9-GenericCloud-latest.aarch64.qcow2", "sizeBytes": 483262464, "checksum": {"algo": "sha256", "value": "15cf8257cb3c293268898309fe9f7d70e893b1eddff99bac9d7e53a2155d00ce", "url": "https://repo.almalinux.org/almalinux/9/cloud/aarch64/images/CHECKSUM", "style": "gnu"}, "format": "qcow2", "desktop": "xfce-x11", "recommended": null, "cloudUser": "almalinux", "notes": ["XFCE via EPEL 9 (same recipe as Rocky 9)"], "verifiedOn": "2026-10-27"},
{"id": "almalinux-9-genericcloud-x86_64", "name": "AlmaLinux 9 GenericCloud (x86_64)", "group": "cloud", "distro": "almalinux", "version": "9.8", "arch": "x86_64", "url": "https://repo.almalinux.org/almalinux/9/cloud/x86_64/images/AlmaLinux-9-GenericCloud-latest.x86_64.qcow2", "sizeBytes": 572850176, "checksum": {"algo": "sha256", "value": "25942b554efaac077e2f60d6bb27bd3332c171454cc21bbd33e5f79244d7570f", "url": "https://repo.almalinux.org/almalinux/9/cloud/x86_64/images/CHECKSUM", "style": "gnu"}, "format": "qcow2", "desktop": "xfce-x11", "recommended": null, "cloudUser": "almalinux", "notes": [], "verifiedOn": "2026-10-27"},
{"id": "ubuntu-24.04.5-desktop-arm64-iso", "name": "Ubuntu Desktop 24.04.5 LTS (arm64)", "group": "iso", "distro": "ubuntu", "version": "24.04.5", "arch": "arm64", "url": "https://cdimage.ubuntu.com/ubuntu/releases/24.04/release/ubuntu-24.04.5-desktop-arm64.iso", "sizeBytes": 3967463424, "checksum": {"algo": "sha256", "value": "2be09ca883921bff6d8e6b0bfbafd13e32436553b7086f33bce3a4c5bad8bd14", "url": "https://cdimage.ubuntu.com/ubuntu/releases/24.04/release/SHA256SUMS", "style": "gnu"}, "format": "iso", "desktop": "gnome-wayland", "recommended": null, "cloudUser": null, "notes": ["official arm64 desktop ISO (cdimage release dir, not releases.ubuntu.com)", "hybrid MBR with EFI partition; El Torito EFI image has BOOTAA64.EFI", "GNOME on Wayland by default: pick 'Ubuntu on Xorg' at login or set WaylandEnable=false in /etc/gdm3/custom.conf for xdotool"], "verifiedOn": "2026-10-27"},
{"id": "ubuntu-24.04.5.1-desktop-x86_64-iso", "name": "Ubuntu Desktop 24.04.5 LTS (amd64)", "group": "iso", "distro": "ubuntu", "version": "24.04.5.1", "arch": "x86_64", "url": "https://releases.ubuntu.com/24.04/ubuntu-24.04.5.1-desktop-amd64.iso", "sizeBytes": 6250332160, "checksum": {"algo": "sha256", "value": "4da4a0c9035da8e68a59a838674f403f0a54472c78a83b4fb7f78d03588f85a7", "url": "https://releases.ubuntu.com/24.04/SHA256SUMS", "style": "gnu"}, "format": "iso", "desktop": "gnome-wayland", "recommended": null, "cloudUser": null, "notes": ["BIOS + EFI(x64)"], "verifiedOn": "2026-10-27"},
{"id": "ubuntu-24.04.5-server-arm64-iso", "name": "Ubuntu Server 24.04.5 LTS (arm64)", "group": "iso", "distro": "ubuntu", "version": "24.04.5", "arch": "arm64", "url": "https://cdimage.ubuntu.com/ubuntu/releases/24.04/release/ubuntu-24.04.5-live-server-arm64.iso", "sizeBytes": 3825512448, "checksum": {"algo": "sha256", "value": "f12484464c7d4d73e2167e0a7dbda1e669f8fae9bcf778dc0944937034b320cb", "url": "https://cdimage.ubuntu.com/ubuntu/releases/24.04/release/SHA256SUMS", "style": "gnu"}, "format": "iso", "desktop": null, "recommended": null, "cloudUser": null, "notes": ["subiquity installer; prefer the cloud image unless the user wants a manual install"], "verifiedOn": "2026-10-27"},
{"id": "ubuntu-24.04.5-server-x86_64-iso", "name": "Ubuntu Server 24.04.5 LTS (amd64)", "group": "iso", "distro": "ubuntu", "version": "24.04.5", "arch": "x86_64", "url": "https://releases.ubuntu.com/24.04/ubuntu-24.04.5-live-server-amd64.iso", "sizeBytes": 4080486400, "checksum": {"algo": "sha256", "value": "97f3d7ffb032c3eb3b23d2c8be9cc76e60c2c1f2c0146ba5ba9fe01cafae0fd8", "url": "https://releases.ubuntu.com/24.04/SHA256SUMS", "style": "gnu"}, "format": "iso", "desktop": null, "recommended": null, "cloudUser": null, "notes": [], "verifiedOn": "2026-10-27"},
{"id": "ubuntu-26.04.1-desktop-arm64-iso", "name": "Ubuntu Desktop 26.04.1 LTS (arm64)", "group": "iso", "distro": "ubuntu", "version": "26.04.1", "arch": "arm64", "url": "https://cdimage.ubuntu.com/ubuntu/releases/26.04/release/ubuntu-26.04.1-desktop-arm64.iso", "sizeBytes": 4154798080, "checksum": {"algo": "sha256", "value": "c54d196489d3c867975fb3bbb72ca52ec2e137456e305481f81096304e4d2517", "url": "https://cdimage.ubuntu.com/ubuntu/releases/26.04/release/SHA256SUMS", "style": "gnu"}, "format": "iso", "desktop": "gnome-wayland", "recommended": null, "cloudUser": null, "notes": ["newer LTS; GNOME 50 era: the Xorg session is gone, so xdotool cannot drive native windows (Wayland-only)"], "verifiedOn": "2026-10-27"},
{"id": "ubuntu-26.04.1-desktop-x86_64-iso", "name": "Ubuntu Desktop 26.04.1 LTS (amd64)", "group": "iso", "distro": "ubuntu", "version": "26.04.1", "arch": "x86_64", "url": "https://releases.ubuntu.com/26.04/ubuntu-26.04.1-desktop-amd64.iso", "sizeBytes": 6482409472, "checksum": {"algo": "sha256", "value": "601e30fbf5d97759367c632e2c33630665039b7e2158fd068403da3ccf1bda1f", "url": "https://releases.ubuntu.com/26.04/SHA256SUMS", "style": "gnu"}, "format": "iso", "desktop": "gnome-wayland", "recommended": null, "cloudUser": null, "notes": ["Intel hosts: needs macOS 15.5+ (kernel >= 6.12)"], "verifiedOn": "2026-10-27"},
{"id": "debian-13.7.0-netinst-arm64-iso", "name": "Debian 13.7.0 netinst (arm64)", "group": "iso", "distro": "debian", "version": "13.7.0", "arch": "arm64", "url": "https://cdimage.debian.org/debian-cd/current/arm64/iso-cd/debian-13.7.0-arm64-netinst.iso", "sizeBytes": 735358976, "checksum": {"algo": "sha512", "value": "cff08e2f29c2846f0503fe57ad1085b5067f29acab444acdf7cdf5b10f2a11140a0e87828e4ffeb9828d188053690467ebe50151c142551d6053fc3288808b86", "url": "https://cdimage.debian.org/debian-cd/current/arm64/iso-cd/SHA512SUMS", "style": "gnu"}, "format": "iso", "desktop": null, "recommended": null, "cloudUser": null, "notes": ["file name changes at each point release: resolve it from SHA512SUMS", "tasksel offers Xfce/GNOME/KDE; pick Xfce for X11 + xdotool", "no arm64 live ISO exists (current-live is amd64 only)"], "verifiedOn": "2026-10-27"},
{"id": "debian-13.7.0-dvd1-arm64-iso", "name": "Debian 13.7.0 DVD-1 (arm64)", "group": "iso", "distro": "debian", "version": "13.7.0", "arch": "arm64", "url": "https://cdimage.debian.org/debian-cd/current/arm64/iso-dvd/debian-13.7.0-arm64-DVD-1.iso", "sizeBytes": 3993284608, "checksum": {"algo": "sha512", "value": "2a2160f9777959b21386edf30940e3d66879e1f1ea193580303538ad87b2b8e8642bc2cb81743d256f79a8b35517449f0a4e234b7de6074222d16813f7c284bd", "url": "https://cdimage.debian.org/debian-cd/current/arm64/iso-dvd/SHA512SUMS", "style": "gnu"}, "format": "iso", "desktop": null, "recommended": null, "cloudUser": null, "notes": ["offline install of a desktop (GNOME by default on DVD-1)"], "verifiedOn": "2026-10-27"},
{"id": "debian-13.7.0-netinst-x86_64-iso", "name": "Debian 13.7.0 netinst (amd64)", "group": "iso", "distro": "debian", "version": "13.7.0", "arch": "x86_64", "url": "https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/debian-13.7.0-amd64-netinst.iso", "sizeBytes": 792723456, "checksum": {"algo": "sha512", "value": "ef04d0276850d70e4aaec0b55003628660e9631b26e35215a70ab3c8c707294a4b12731bc73c75a932902f703a7c278310ca99df28d6b36fb06d5618d8d0f678", "url": "https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/SHA512SUMS", "style": "gnu"}, "format": "iso", "desktop": null, "recommended": null, "cloudUser": null, "notes": ["Intel hosts: kernel 6.12 needs macOS 15.5+"], "verifiedOn": "2026-10-27"},
{"id": "debian-13.7.0-dvd1-x86_64-iso", "name": "Debian 13.7.0 DVD-1 (amd64)", "group": "iso", "distro": "debian", "version": "13.7.0", "arch": "x86_64", "url": "https://cdimage.debian.org/debian-cd/current/amd64/iso-dvd/debian-13.7.0-amd64-DVD-1.iso", "sizeBytes": 3992977408, "checksum": {"algo": "sha512", "value": "305cc7a3f0d4e293ff979cc6c047d7fe46454853a0f170a0520acd8aab37c2f8839969c817afac2b4324ef5944e0038502b7fcca5dfcd48b5b77544ef1f14cee", "url": "https://cdimage.debian.org/debian-cd/current/amd64/iso-dvd/SHA512SUMS", "style": "gnu"}, "format": "iso", "desktop": null, "recommended": null, "cloudUser": null, "notes": [], "verifiedOn": "2026-10-27"},
{"id": "fedora-44-workstation-arm64-iso", "name": "Fedora Workstation 44 Live (aarch64)", "group": "iso", "distro": "fedora", "version": "44", "arch": "arm64", "url": "https://download.fedoraproject.org/pub/fedora/linux/releases/44/Workstation/aarch64/iso/Fedora-Workstation-Live-44-1.7.aarch64.iso", "sizeBytes": 2689781760, "checksum": {"algo": "sha256", "value": "162ba3c552a2d241c7c63ec26777af0255ee1b5a135adc0be986ceed999933ef", "url": "https://dl.fedoraproject.org/pub/fedora/linux/releases/44/Workstation/aarch64/iso/Fedora-Workstation-44-1.7-aarch64-CHECKSUM", "style": "bsd"}, "format": "iso", "desktop": "gnome-wayland", "recommended": null, "cloudUser": null, "notes": ["GNOME is Wayland-only since Fedora 43: xdotool cannot drive it; grim unsupported", "GPT hybrid with ESP; UTM users report the boot splash display problem goes away with Apple Virtualization (UTM#6961)"], "verifiedOn": "2026-10-27"},
{"id": "fedora-44-workstation-x86_64-iso", "name": "Fedora Workstation 44 Live (x86_64)", "group": "iso", "distro": "fedora", "version": "44", "arch": "x86_64", "url": "https://download.fedoraproject.org/pub/fedora/linux/releases/44/Workstation/x86_64/iso/Fedora-Workstation-Live-44-1.7.x86_64.iso", "sizeBytes": 2851612672, "checksum": {"algo": "sha256", "value": "1620295f6a00c27c3208f0c00b8ece4eab1ec69b9002152d97488bf26a426ddf", "url": "https://dl.fedoraproject.org/pub/fedora/linux/releases/44/Workstation/x86_64/iso/Fedora-Workstation-44-1.7-x86_64-CHECKSUM", "style": "bsd"}, "format": "iso", "desktop": "gnome-wayland", "recommended": null, "cloudUser": null, "notes": [], "verifiedOn": "2026-10-27"},
{"id": "fedora-44-xfce-arm64-iso", "name": "Fedora Xfce 44 Live (aarch64)", "group": "iso", "distro": "fedora", "version": "44", "arch": "arm64", "url": "https://download.fedoraproject.org/pub/fedora/linux/releases/44/Spins/aarch64/iso/Fedora-Xfce-Live-44-1.7.aarch64.iso", "sizeBytes": 2666934272, "checksum": {"algo": "sha256", "value": "c707af264df01b70fdf7abfd4fea44ee2942a6080d4353f4e61b23fe951c049e", "url": "https://dl.fedoraproject.org/pub/fedora/linux/releases/44/Spins/aarch64/iso/Fedora-Spins-44-1.7-aarch64-CHECKSUM", "style": "bsd"}, "format": "iso", "desktop": "xfce-x11", "recommended": null, "cloudUser": null, "notes": ["the agent-friendly Fedora ISO: Xfce on X11 with LightDM; dnf install xdotool scrot afterwards"], "verifiedOn": "2026-10-27"},
{"id": "fedora-44-xfce-x86_64-iso", "name": "Fedora Xfce 44 Live (x86_64)", "group": "iso", "distro": "fedora", "version": "44", "arch": "x86_64", "url": "https://download.fedoraproject.org/pub/fedora/linux/releases/44/Spins/x86_64/iso/Fedora-Xfce-Live-44-1.7.x86_64.iso", "sizeBytes": 2928986112, "checksum": {"algo": "sha256", "value": "55ea8cb52ac16e62f436e37f9fdb4e978d7b9f75814a9d42e8b69d05e3b496ad", "url": "https://dl.fedoraproject.org/pub/fedora/linux/releases/44/Spins/x86_64/iso/Fedora-Spins-44-1.7-x86_64-CHECKSUM", "style": "bsd"}, "format": "iso", "desktop": "xfce-x11", "recommended": null, "cloudUser": null, "notes": [], "verifiedOn": "2026-10-27"},
{"id": "kali-2026.3-installer-arm64-iso", "name": "Kali Linux 2026.3 installer (arm64)", "group": "iso", "distro": "kali", "version": "2026.3", "arch": "arm64", "url": "https://cdimage.kali.org/kali-2026.3/kali-linux-2026.3-installer-arm64.iso", "sizeBytes": 4051513344, "checksum": {"algo": "sha256", "value": "c4a7f9bf3a0ff07c8263fe9e9b0edba0cc3d9b408f1d8f06c066df0afce23072", "url": "https://kali.download/base-images/kali-2026.3/SHA256SUMS", "style": "gnu"}, "format": "iso", "desktop": "xfce-x11", "recommended": null, "cloudUser": null, "notes": ["Debian-installer based; hybrid MBR + EFI partition, BOOTAA64.EFI present", "default desktop Xfce on X11: xdotool/scrot available from the Kali repo", "the arm64vm VZ manager was built around this ISO (USB-attached, UEFI); UTM QEMU users hit a black screen that a serial console works around"], "verifiedOn": "2026-10-27"},
{"id": "kali-2026.3-installer-x86_64-iso", "name": "Kali Linux 2026.3 installer (amd64)", "group": "iso", "distro": "kali", "version": "2026.3", "arch": "x86_64", "url": "https://cdimage.kali.org/kali-2026.3/kali-linux-2026.3-installer-amd64.iso", "sizeBytes": 5047031808, "checksum": {"algo": "sha256", "value": "db9cbed33edb45727d16911813c2434fcd1419585007884153be22a03b30ec2f", "url": "https://kali.download/base-images/kali-2026.3/SHA256SUMS", "style": "gnu"}, "format": "iso", "desktop": "xfce-x11", "recommended": null, "cloudUser": null, "notes": [], "verifiedOn": "2026-10-27"},
{"id": "kali-2026.3-netinst-arm64-iso", "name": "Kali Linux 2026.3 netinst (arm64)", "group": "iso", "distro": "kali", "version": "2026.3", "arch": "arm64", "url": "https://cdimage.kali.org/kali-2026.3/kali-linux-2026.3-installer-netinst-arm64.iso", "sizeBytes": 603238400, "checksum": {"algo": "sha256", "value": "a986c7fe0f8e887a77e7ea9f868da88eae04e7ac780ae75e6b702f243b63bf8d", "url": "https://kali.download/base-images/kali-2026.3/SHA256SUMS", "style": "gnu"}, "format": "iso", "desktop": "xfce-x11", "recommended": null, "cloudUser": null, "notes": ["downloads packages during install"], "verifiedOn": "2026-10-27"},
{"id": "linuxmint-22.3-xfce-x86_64-iso", "name": "Linux Mint 22.3 Xfce (64-bit)", "group": "iso", "distro": "linuxmint", "version": "22.3", "arch": "x86_64", "url": "https://mirrors.edge.kernel.org/linuxmint/stable/22.3/linuxmint-22.3-xfce-64bit.iso", "sizeBytes": 3033710592, "checksum": {"algo": "sha256", "value": "45a835b5dddaf40e84d776549e0b19b3fbd49673b6cc6434ebddbfcd217df776", "url": "https://mirrors.edge.kernel.org/linuxmint/stable/22.3/sha256sum.txt", "style": "gnu"}, "format": "iso", "desktop": "xfce-x11", "recommended": null, "cloudUser": null, "notes": ["x86_64 only: Mint has no arm64 build, so Intel Macs only"], "verifiedOn": "2026-10-27"},
{"id": "linuxmint-22.3-cinnamon-x86_64-iso", "name": "Linux Mint 22.3 Cinnamon (64-bit)", "group": "iso", "distro": "linuxmint", "version": "22.3", "arch": "x86_64", "url": "https://mirrors.edge.kernel.org/linuxmint/stable/22.3/linuxmint-22.3-cinnamon-64bit.iso", "sizeBytes": 3091660800, "checksum": {"algo": "sha256", "value": "a081ab202cfda17f6924128dbd2de8b63518ac0531bcfe3f1a1b88097c459bd4", "url": "https://mirrors.edge.kernel.org/linuxmint/stable/22.3/sha256sum.txt", "style": "gnu"}, "format": "iso", "desktop": "cinnamon-x11", "recommended": null, "cloudUser": null, "notes": ["x86_64 only"], "verifiedOn": "2026-10-27"},
{"id": "archlinux-x86_64-iso", "name": "Arch Linux 2026.10.01 (x86_64)", "group": "iso", "distro": "arch", "version": "2026.10.01", "arch": "x86_64", "url": "https://geo.mirror.pkgbuild.com/iso/latest/archlinux-x86_64.iso", "sizeBytes": 1640497152, "checksum": {"algo": "sha256", "value": "684ded26c63240ff4a41e8c25ee84ea6da233f557364821f13d12c2b0a9059a5", "url": "https://geo.mirror.pkgbuild.com/iso/latest/sha256sums.txt", "style": "gnu"}, "format": "iso", "desktop": null, "recommended": null, "cloudUser": null, "notes": ["x86_64 only; Arch Linux ARM ships rootfs tarballs, no ISO", "console installer (archinstall); Intel hosts need macOS 15.5+"], "verifiedOn": "2026-10-27"},
{"id": "alpine-3.24.3-virt-arm64-iso", "name": "Alpine 3.24.3 virt (aarch64)", "group": "iso", "distro": "alpine", "version": "3.24.3", "arch": "arm64", "url": "https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/aarch64/alpine-virt-3.24.3-aarch64.iso", "sizeBytes": 93452288, "checksum": {"algo": "sha256", "value": "e34603080e942e9ebc670689eee77dd7a6551c823a6ff5a299e308ded268098f", "url": "https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/aarch64/alpine-virt-3.24.3-aarch64.iso.sha256", "style": "gnu"}, "format": "iso", "desktop": null, "recommended": null, "cloudUser": null, "notes": ["89 MiB; GPT with ESP; console only, setup-alpine then setup-desktop xfce"], "verifiedOn": "2026-10-27"},
{"id": "alpine-3.24.3-standard-arm64-iso", "name": "Alpine 3.24.3 standard (aarch64)", "group": "iso", "distro": "alpine", "version": "3.24.3", "arch": "arm64", "url": "https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/aarch64/alpine-standard-3.24.3-aarch64.iso", "sizeBytes": 394645504, "checksum": {"algo": "sha256", "value": "d4438d8973b7a4c50a2ee25d1555c537c1e6e91e25db28b7b683aa79c9ddba8f", "url": "https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/aarch64/alpine-standard-3.24.3-aarch64.iso.sha256", "style": "gnu"}, "format": "iso", "desktop": null, "recommended": null, "cloudUser": null, "notes": ["linux-lts kernel + firmware; console only"], "verifiedOn": "2026-10-27"},
{"id": "alpine-3.24.3-virt-x86_64-iso", "name": "Alpine 3.24.3 virt (x86_64)", "group": "iso", "distro": "alpine", "version": "3.24.3", "arch": "x86_64", "url": "https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/x86_64/alpine-virt-3.24.3-x86_64.iso", "sizeBytes": 70254592, "checksum": {"algo": "sha256", "value": "cdc1bc0efc64d8d611bf3733f54868172a545888dfd726f518bf279bcb0ff1af", "url": "https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/x86_64/alpine-virt-3.24.3-x86_64.iso.sha256", "style": "gnu"}, "format": "iso", "desktop": null, "recommended": null, "cloudUser": null, "notes": [], "verifiedOn": "2026-10-27"},
{"id": "alpine-3.24.3-standard-x86_64-iso", "name": "Alpine 3.24.3 standard (x86_64)", "group": "iso", "distro": "alpine", "version": "3.24.3", "arch": "x86_64", "url": "https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/x86_64/alpine-standard-3.24.3-x86_64.iso", "sizeBytes": 370147328, "checksum": {"algo": "sha256", "value": "1629ffe7308d4f3d3eeeed3a97d09ad62293f6d37ef3e483a7306077fdac12be", "url": "https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/x86_64/alpine-standard-3.24.3-x86_64.iso.sha256", "style": "gnu"}, "format": "iso", "desktop": null, "recommended": null, "cloudUser": null, "notes": [], "verifiedOn": "2026-10-27"},
{"id": "nixos-26.05-minimal-arm64-iso", "name": "NixOS 26.05 minimal (aarch64)", "group": "iso", "distro": "nixos", "version": "26.05", "arch": "arm64", "url": "https://releases.nixos.org/nixos/26.05/nixos-26.05.12707.718f670e8453/nixos-minimal-26.05.12707.718f670e8453-aarch64-linux.iso", "sizeBytes": 1821014016, "checksum": {"algo": "sha256", "value": "8203bbfbdab0c3ed148dead9fed855a41b21f2c87e74d3a21413bd565b04bdfe", "url": "https://releases.nixos.org/nixos/26.05/nixos-26.05.12707.718f670e8453/nixos-minimal-26.05.12707.718f670e8453-aarch64-linux.iso.sha256", "style": "gnu"}, "format": "iso", "desktop": null, "recommended": null, "cloudUser": null, "notes": ["resolved from https://channels.nixos.org/nixos-26.05/latest-nixos-minimal-aarch64-linux.iso (302); re-resolve per download", "no MBR/GPT: boots only through El Torito EFI on a USB-attached disk (EDK2 supports this; VZ firmware UNVERIFIED)", "console only; set services.xserver + xfce in configuration.nix for an X11 desktop"], "verifiedOn": "2026-10-27"},
{"id": "nixos-26.05-minimal-x86_64-iso", "name": "NixOS 26.05 minimal (x86_64)", "group": "iso", "distro": "nixos", "version": "26.05", "arch": "x86_64", "url": "https://releases.nixos.org/nixos/26.05/nixos-26.05.12707.718f670e8453/nixos-minimal-26.05.12707.718f670e8453-x86_64-linux.iso", "sizeBytes": 1744830464, "checksum": {"algo": "sha256", "value": "12f093ce7bf7e9747c67730ee3cc7b22713912382e8d3d6f27ef6b19afd8c800", "url": "https://releases.nixos.org/nixos/26.05/nixos-26.05.12707.718f670e8453/nixos-minimal-26.05.12707.718f670e8453-x86_64-linux.iso.sha256", "style": "gnu"}, "format": "iso", "desktop": null, "recommended": null, "cloudUser": null, "notes": ["resolved from the nixos-26.05 channel redirect"], "verifiedOn": "2026-10-27"},
{"id": "opensuse-tumbleweed-dvd-arm64-iso", "name": "openSUSE Tumbleweed DVD (aarch64)", "group": "iso", "distro": "opensuse-tumbleweed", "version": "Snapshot20261020", "arch": "arm64", "url": "https://download.opensuse.org/ports/aarch64/tumbleweed/iso/openSUSE-Tumbleweed-DVD-aarch64-Current.iso", "sizeBytes": 4235493376, "checksum": {"algo": "sha256", "value": "3276133a3f691997f27e628531f959091c666fb37632675e54e64e84804d53ed", "url": "https://download.opensuse.org/ports/aarch64/tumbleweed/iso/openSUSE-Tumbleweed-DVD-aarch64-Current.iso.sha256", "style": "gnu", "lookupName": "openSUSE-Tumbleweed-DVD-aarch64-Snapshot20261020-Media.iso"}, "format": "iso", "desktop": null, "recommended": null, "cloudUser": null, "notes": ["the .sha256 names the Snapshot file, not '-Current': look up by the redirect target", "MBR with a FAT32 (0x0c) partition, no 0xEF/GPT ESP: UEFI finds it as a FAT volume (UNVERIFIED on VZ)", "installer offers KDE (Wayland), GNOME, Xfce (X11)"], "verifiedOn": "2026-10-27"},
{"id": "opensuse-tumbleweed-net-arm64-iso", "name": "openSUSE Tumbleweed NET (aarch64)", "group": "iso", "distro": "opensuse-tumbleweed", "version": "Snapshot20261020", "arch": "arm64", "url": "https://download.opensuse.org/ports/aarch64/tumbleweed/iso/openSUSE-Tumbleweed-NET-aarch64-Current.iso", "sizeBytes": 450416640, "checksum": {"algo": "sha256", "value": "33916688227949b0691502ed35f10329ce0047a7312239573bb99a93ce941f82", "url": "https://download.opensuse.org/ports/aarch64/tumbleweed/iso/openSUSE-Tumbleweed-NET-aarch64-Current.iso.sha256", "style": "gnu", "lookupName": "openSUSE-Tumbleweed-NET-aarch64-Snapshot20261020-Media.iso"}, "format": "iso", "desktop": null, "recommended": null, "cloudUser": null, "notes": ["the .sha256 names the Snapshot file"], "verifiedOn": "2026-10-27"},
{"id": "opensuse-tumbleweed-xfce-live-arm64-iso", "name": "openSUSE Tumbleweed Xfce Live (aarch64)", "group": "iso", "distro": "opensuse-tumbleweed", "version": "Snapshot20261020", "arch": "arm64", "url": "https://download.opensuse.org/ports/aarch64/tumbleweed/iso/openSUSE-Tumbleweed-XFCE-Live-aarch64-Current.iso", "sizeBytes": 1400252416, "checksum": {"algo": "sha256", "value": "721bbfeccaf72f9526017985bec3f546734392a37a6b3e7362e93c72a6d3c85c", "url": "https://download.opensuse.org/ports/aarch64/tumbleweed/iso/openSUSE-Tumbleweed-XFCE-Live-aarch64-Current.iso.sha256", "style": "gnu", "lookupName": "openSUSE-Tumbleweed-XFCE-Live-aarch64-Snapshot20261020-Media.iso"}, "format": "iso", "desktop": "xfce-x11", "recommended": null, "cloudUser": null, "notes": ["GPT hybrid with ESP", "openSUSE users report the same QEMU boot-display issue as Fedora (UTM#6961)"], "verifiedOn": "2026-10-27"},
{"id": "opensuse-tumbleweed-dvd-x86_64-iso", "name": "openSUSE Tumbleweed DVD (x86_64)", "group": "iso", "distro": "opensuse-tumbleweed", "version": "Snapshot20261026", "arch": "x86_64", "url": "https://download.opensuse.org/tumbleweed/iso/openSUSE-Tumbleweed-DVD-x86_64-Current.iso", "sizeBytes": 4697620480, "checksum": {"algo": "sha256", "value": "b9422cb5640b4bd1a124c769749f1024f608149ef2747228bcbcce98bf9f97c6", "url": "https://download.opensuse.org/tumbleweed/iso/openSUSE-Tumbleweed-DVD-x86_64-Current.iso.sha256", "style": "gnu", "lookupName": "openSUSE-Tumbleweed-DVD-x86_64-Snapshot20261026-Media.iso"}, "format": "iso", "desktop": null, "recommended": null, "cloudUser": null, "notes": ["the .sha256 names the Snapshot file"], "verifiedOn": "2026-10-27"},
{"id": "opensuse-leap-16.0-offline-arm64-iso", "name": "openSUSE Leap 16.0 offline installer (aarch64)", "group": "iso", "distro": "opensuse-leap", "version": "16.0", "arch": "arm64", "url": "https://download.opensuse.org/distribution/leap/16.0/offline/Leap-16.0-offline-installer-aarch64.install.iso", "sizeBytes": 4642045952, "checksum": {"algo": "sha512", "value": "a6328f07434875bd62ab57400829429ad0a908a0b2085a2323faf657bd7fecc6e1b7852531e562302a57e861c90b92935085d8352ebfa7d33a2cda5b96e577d4", "url": "https://download.opensuse.org/distribution/leap/16.0/offline/Leap-16.0-offline-installer-aarch64.install.iso.sha512", "style": "gnu"}, "format": "iso", "desktop": null, "recommended": null, "cloudUser": null, "notes": ["Agama installer; GPT hybrid with ESP"], "verifiedOn": "2026-10-27"},
{"id": "opensuse-leap-16.0-offline-x86_64-iso", "name": "openSUSE Leap 16.0 offline installer (x86_64)", "group": "iso", "distro": "opensuse-leap", "version": "16.0", "arch": "x86_64", "url": "https://download.opensuse.org/distribution/leap/16.0/offline/Leap-16.0-offline-installer-x86_64.install.iso", "sizeBytes": 4538236928, "checksum": {"algo": "sha512", "value": "94411793a1878b3558211c8bbe4f3823c3c5212cc2dd9f9e4532a18be7eddd3be14db5a3bb47a2f36dd957e190ea706cd45af16bce218dfc00f71e64a8469971", "url": "https://download.opensuse.org/distribution/leap/16.0/offline/Leap-16.0-offline-installer-x86_64.install.iso.sha512", "style": "gnu"}, "format": "iso", "desktop": null, "recommended": null, "cloudUser": null, "notes": [], "verifiedOn": "2026-10-27"},
{"id": "rocky-10-minimal-arm64-iso", "name": "Rocky Linux 10.2 minimal (aarch64)", "group": "iso", "distro": "rocky", "version": "10.2", "arch": "arm64", "url": "https://dl.rockylinux.org/pub/rocky/10/isos/aarch64/Rocky-10-latest-aarch64-minimal.iso", "sizeBytes": 2397044736, "checksum": {"algo": "sha256", "value": "1d1c21199df32f6d17eedb4f713ee0d089b49294401a364b640fcf4ffab45f35", "url": "https://dl.rockylinux.org/pub/rocky/10/isos/aarch64/CHECKSUM", "style": "bsd"}, "format": "iso", "desktop": null, "recommended": null, "cloudUser": null, "notes": ["no MBR/GPT: El Torito EFI only (UNVERIFIED on VZ firmware)", "EL10 has no Xorg server: GNOME on Wayland only"], "verifiedOn": "2026-10-27"},
{"id": "rocky-10-dvd-arm64-iso", "name": "Rocky Linux 10.2 DVD (aarch64)", "group": "iso", "distro": "rocky", "version": "10.2", "arch": "arm64", "url": "https://dl.rockylinux.org/pub/rocky/10/isos/aarch64/Rocky-10-latest-aarch64-dvd.iso", "sizeBytes": 9659678720, "checksum": {"algo": "sha256", "value": "3b8253987604df1bc5e1c33c838ff3ee9ce4a8f02ed9e27e300ecff58c0c9588", "url": "https://dl.rockylinux.org/pub/rocky/10/isos/aarch64/CHECKSUM", "style": "bsd"}, "format": "iso", "desktop": "gnome-wayland", "recommended": null, "cloudUser": null, "notes": ["9 GiB; same El Torito-only layout as the minimal ISO (UNVERIFIED)"], "verifiedOn": "2026-10-27"},
{"id": "rocky-10-minimal-x86_64-iso", "name": "Rocky Linux 10.2 minimal (x86_64)", "group": "iso", "distro": "rocky", "version": "10.2", "arch": "x86_64", "url": "https://dl.rockylinux.org/pub/rocky/10/isos/x86_64/Rocky-10-latest-x86_64-minimal.iso", "sizeBytes": 2072444928, "checksum": {"algo": "sha256", "value": "aac6ac3ce781b91a91ce78463405f66c611a5dca4b3840c79e5e01d97302f6c8", "url": "https://dl.rockylinux.org/pub/rocky/10/isos/x86_64/CHECKSUM", "style": "bsd"}, "format": "iso", "desktop": null, "recommended": null, "cloudUser": null, "notes": ["x86-64-v3 CPUs only"], "verifiedOn": "2026-10-27"},
{"id": "popos-24.04-generic-arm64-iso", "name": "Pop!_OS 24.04 LTS generic (arm64)", "group": "iso", "distro": "popos", "version": "24.04 build 3", "arch": "arm64", "url": "https://iso.pop-os.org/24.04/arm64/generic/3/pop-os_24.04_arm64_generic_3.iso", "sizeBytes": 2888884224, "checksum": {"algo": "sha256", "value": "7b4cce0e92dc5c903464e7e7c33760c4417f1400165e9ecfcd064fbceb68ef22", "url": "https://api.pop-os.org/builds/24.04/generic?arch=arm64", "style": "api-json"}, "format": "iso", "desktop": "cosmic-wayland", "recommended": null, "cloudUser": null, "notes": ["checksum comes from System76's build API (field sha_sum), there is no SUMS file", "COSMIC is Wayland-only: xdotool cannot drive it", "no MBR/GPT: El Torito EFI only (UNVERIFIED on VZ); built for Thelio Astra"], "verifiedOn": "2026-10-27"},
{"id": "popos-24.04-generic-x86_64-iso", "name": "Pop!_OS 24.04 LTS generic (amd64)", "group": "iso", "distro": "popos", "version": "24.04 build 28", "arch": "x86_64", "url": "https://iso.pop-os.org/24.04/amd64/generic/28/pop-os_24.04_amd64_generic_28.iso", "sizeBytes": 3526164480, "checksum": {"algo": "sha256", "value": "8d78e500fc95da765a91cddcf2ab7ba71ce4e7997e4f008456d4d872ee8f8221", "url": "https://api.pop-os.org/builds/24.04/generic?arch=amd64", "style": "api-json"}, "format": "iso", "desktop": "cosmic-wayland", "recommended": null, "cloudUser": null, "notes": ["COSMIC Wayland-only"], "verifiedOn": "2026-10-27"},
{"id": "zorin-18.1-core-x86_64-iso", "name": "Zorin OS 18.1 Core (64-bit)", "group": "iso", "distro": "zorin", "version": "18.1", "arch": "x86_64", "url": "https://mirrors.edge.kernel.org/zorinos-isos/18/Zorin-OS-18.1-Core-64-bit.iso", "sizeBytes": 3909091328, "checksum": {"algo": "sha256", "value": "44649b97bd307fc4c8529205d098ebbf98575a1e1ba2ee7d7005b697af1721d5", "url": "https://mirrors.edge.kernel.org/zorinos-isos/18/SHA256SUMS.txt", "style": "gnu"}, "format": "iso", "desktop": "gnome-wayland", "recommended": null, "cloudUser": null, "notes": ["x86_64 only (no arm64 build)", "Zorin Lite (Xfce, X11) is the agent-friendlier edition"], "verifiedOn": "2026-10-27"}
]
```

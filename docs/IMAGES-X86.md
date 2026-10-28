# Z Alpine Desktop (x86): the prebuilt v86 image

A small 32-bit x86 Alpine Linux disk image with an agent-ready XFCE desktop, made for the
[v86](https://github.com/copy/v86) WebAssembly x86 emulator that the iOS app runs in a `WKWebView`, plus a v86
**saved state** taken at the finished desktop: the app restores the state and is on the desktop in about a second,
instead of booting for a minute and a half.

`.github/workflows/images.yml` builds it, boots it once in v86 under Node, saves the state, compresses both files and
smoke-tests a restore. The output is a **workflow artifact only** (private to this repository's Actions, kept 30
days). Nothing is released or published by the workflow; `tools/images/publish.sh` does that, by hand, after review.

## The files

The artifact `z-alpine-desktop-x86` holds four files:

| file | what |
|---|---|
| `z-alpine-desktop-x86.img.xz` | the raw disk image (MBR, one ext4 partition = `/dev/sda1`, extlinux), `xz -T0 -9` |
| `z-alpine-desktop-x86.state.xz` | the v86 state at the desktop (`save_state()` output), `xz -T0 -9` |
| `manifest.json` | machine-readable description: sizes, sha256s, the v86 build and machine options a restore must use |
| `README.md` | the same for people, with this build's smoke-test results |

Build `2026.10.28-148b6c6` (run [40661141488](https://github.com/Everaldtah/zcomputer/actions/runs/40661141488)):

| file | compressed | decompressed | sha256 (compressed file) |
|---|---|---|---|
| `z-alpine-desktop-x86.img.xz` | SIZE_IMG | 1 610 612 736 B (1.5 GiB sparse, ~282 MiB used) | `SHA_IMG` |
| `z-alpine-desktop-x86.state.xz` | SIZE_STATE | SIZE_STATE_RAW | `SHA_STATE` |

Every build changes the sha256s (timestamps, machine-id, a fresh state); `manifest.json` of the build you publish is
the authority. Each image entry in it looks like this (abridged):

```json
{
  "version": "2026.10.28-148b6c6", "builtAt": "…", "baseUrl": "https://github.com/Everaldtah/zcomputer/releases/download/images-v1/",
  "images": [{
    "id": "z-alpine-desktop-x86", "name": "Z Alpine Desktop (x86)", "arch": "x86", "format": "raw",
    "diskBytes": 1610612736,
    "files": {
      "img":   {"name": "z-alpine-desktop-x86.img.xz",   "url": "…", "compression": "xz", "sizeBytes": 0, "sha256": "…", "decompressedBytes": 1610612736, "decompressedSha256": "…"},
      "state": {"name": "z-alpine-desktop-x86.state.xz", "url": "…", "compression": "xz", "sizeBytes": 0, "sha256": "…", "decompressedBytes": 0, "decompressedSha256": "…"}
    },
    "memoryMB": 512, "vgaMemoryMB": 8, "screen": {"w": 1024, "h": 768},
    "user": "z", "password": "z", "desktop": "xfce-x11", "agentPort": 5555, "agentAddress": "127.0.0.1:5555",
    "serial": {"port": "ttyS0", "baud": 115200, "loggedIn": true},
    "hostShare": {"type": "9p", "mountTag": "host9p", "mountPoint": "/mnt/host"},
    "browser": "netsurf",
    "emulator": {"name": "v86", "npm": "v86@0.5.472", "commit": "cc37f35c…", "bios": {…}, "vgaBios": {…}, "options": {…}},
    "bootToDesktopSec": 90.6, "bootToSettledSec": 101, "restoreToShellSec": 0.7,
    "notes": ["…"]
  }]
}
```

### Download URLs

Once published, every file is a GitHub Release asset of the release `images-v1`:

```
https://github.com/Everaldtah/zcomputer/releases/download/images-v1/<file>
https://github.com/Everaldtah/zcomputer/releases/download/images-v1/manifest.json
https://github.com/Everaldtah/zcomputer/releases/download/images-v1/z-alpine-desktop-x86.img.xz
https://github.com/Everaldtah/zcomputer/releases/download/images-v1/z-alpine-desktop-x86.state.xz
```

The app fetches `manifest.json` first, then the two `.xz` files, checks `sha256` (compressed) and, after
decompressing, `decompressedSha256`. Republishing keeps the URLs (assets are replaced in place), so the app must
compare the manifest's `version` / sha256s with what it has, not rely on the URL.

## What is in the image

* **Alpine Linux 3.22** (x86 = i686), kernel `linux-virt` 6.12 (its config has everything v86 needs: ATA/`ata_piix`
  for v86's hda = `/dev/sda`, PS/2 + the kernel's VMware VMMouse protocol, `bochs` DRM for v86's Bochs VBE display,
  virtio-net, 9p over virtio, 8250 serial). About 308 packages, ~282 MiB used of a 1536 MiB disk.
* **Desktop:** Xorg (`fbdev` driver on bochs-drm's `/dev/fb0`, 1024×768×32, ShadowFB, GLX and glamor off), XFCE 4.20
  (`xfce4-session`, `xfwm4` without compositing, `xfce4-panel` with one preconfigured top panel, `xfdesktop`,
  `xfce4-settings`, Thunar, `xfce4-appfinder`, `xfce4-terminal`), Adwaita icons, DejaVu + Noto fonts. LightDM with
  the GTK greeter autologs in `z` straight into XFCE. No screensaver, no locker, no DPMS (X `-s 0 -dpms`, `xset s off
  -dpms` in the display-setup script and in XFCE autostart; `xfce4-screensaver`/`-power-manager` are not installed).
  XFCE's first-run panel dialog does not appear (the panel is preconfigured).
* **Browser:** NetSurf (`netsurf-gtk3`, ~5 MB). `firefox-esr` exists for x86 in Alpine's community repo but adds
  ~250 MB and is far too heavy for an interpreted x86 in a phone; `sudo apk add firefox-esr` if needed.
* **Agent tooling:** `zguest` (this repo's `guest-agent/`, built `CGO_ENABLED=0 GOOS=linux GOARCH=386`),
  `xdotool`, `scrot`, `xclip`, `python3`, `curl`, `bash`, `sudo`, `nano`, `openssh` (client + server, sshd not
  started), `e2fsprogs`, `util-linux`, `procps`, `ca-certificates`.
* **Not in the image:** OpenGL. `xorg-server` pulls Mesa, and Mesa pulls LLVM (~350 MB); nothing renders with GL here,
  so the build deletes LLVM, SPIRV-Tools and Mesa's gallium drivers and then checks that every program still loads
  all its libraries. `sudo apk fix mesa llvm20-libs` restores them. The `xfce4` metapackage is not used either: it
  pulls `tumbler` → WebKitGTK + GStreamer + FFmpeg (~250 MB) for thumbnails.

### Login and services

| | |
|---|---|
| user | **`z`**, password **`z`**, groups `wheel` (sudo **without** password), `video`, `input`, `audio` |
| root | password login disabled (`passwd -l root`); use `sudo` |
| ttyS0 | `getty -L 115200 ttyS0 vt100`; **in the saved state it is a logged-in `bash` of `z`** |
| tty1 | `getty 38400 tty1`; X runs on vt7 |
| hostname | `z-alpine` |

OpenRC runlevels: *sysinit* `devfs dmesg cgroups udev udev-trigger udev-settle` (sysfs comes in as a dependency),
*boot* `modules sysctl hostname bootmisc syslog hwclock seedrng`, *default* `networking` (eth0 DHCP via `udhcpc`,
backgrounds itself and keeps retrying when no server answers) `udev-postmount dbus elogind zshare zguest lightdm`.

* Kernel command line (extlinux): `root=/dev/sda1 rw rootfstype=ext4 rootflags=noatime modules=sd-mod,ext4
  console=tty0 console=ttyS0,115200 video=1024x768-32 init_on_free=1 mitigations=off`. `init_on_free=1` zeroes freed
  pages so the saved state compresses well.
* `/etc/fstab` mounts v86's 9p share: `host9p /mnt/host 9p trans=virtio,version=9p2000.L,nofail,noauto 0 0`. The mount
  tag is `host9p` because that is the tag v86's virtio-9p device has (it is not configurable). `noauto` + the
  `zshare` service: the share is mounted only when the emulator has one, so the image also boots without it.
* Root fs: ext4 without `64bit`, `metadata_csum_seed` and `orphan_file` (syslinux 6.04 cannot read those), inode
  tables initialised at build time (no `ext4lazyinit` writes after boot). `/tmp` is a 128 MiB tmpfs.
* `/etc/zcomputer-image` records the image id, version, Alpine release and build time; `/etc/motd` and `/etc/issue`
  print the credentials and the agent address on the serial console.

## Restoring the state in v86

The state is a snapshot of one exact virtual machine. A restore must use **the same v86 build, the same BIOS files, the
same machine options, and the pristine image**:

```js
const emulator = new V86({
  wasm_path: "v86.wasm",                      // npm v86@0.5.472 = copy/v86 cc37f35c43bf14865d74ad76879ecf9410f69eb1
  bios: { url: "seabios.bin" },               // copy/v86 bios/ at that commit, sha256 73e3f359…
  vga_bios: { url: "vgabios.bin" },           // sha256 a4bc0d80…
  memory_size: 512 * 1024 * 1024,
  vga_memory_size: 8 * 1024 * 1024,
  hda: { url: "z-alpine-desktop-x86.img", async: true, size: 1610612736 },
  net_device: { type: "virtio", relay_url: "fetch" },   // any backend; the state has a virtio-net device
  preserve_mac_from_state_image: true,
  filesystem: {},                              // required: the state has a virtio-9p device (tag host9p)
  acpi: false,
  initial_state: { url: "z-alpine-desktop-x86.state" },
  autostart: true,
});
```

* **The image must stay pristine.** The state holds the guest's page cache and the ext4 journal position as they were
  at the snapshot; v86 with `async: true` (or a `File`/`Blob`) reads the image lazily and keeps every guest write in
  memory, so the image file is never modified. If an app persists guest writes into the image, it can no longer
  restore *this* state from that image; keep a pristine copy (or persist v86 states instead, which carry the
  written blocks). The workflow checks that the boot left the image byte-identical.
* `manifest.json` → `images[0].emulator` has the exact options, the BIOS URLs + sha256s and the commit.
* The decompressed image is 1.5 GiB of which ~282 MiB is data; write it **sparsely** (skip all-zero blocks while
  decompressing; APFS and ext4 keep the holes). `hda: { url, async: true, size }` makes v86 fetch byte ranges, so a
  `WKURLSchemeHandler` serving the file must answer `Range` requests; a `File`/`Blob` works too.
* The guest **clock** resumes at the snapshot time. Set it after restoring, e.g. `sudo date -s @<unix-seconds>` on
  the serial console or with zguest `exec` (zguest runs as root).
* **Network:** with `preserve_mac_from_state_image: true` the NIC keeps the MAC the guest knows. Without it, run
  `z-net-reset` (reloads `virtio_net`, then DHCP). `udhcpc` keeps retrying in the background, so eth0 gets a lease as
  soon as the app's network backend answers DHCP.

## Driving the guest from the app

* **Serial console (ttyS0).** `emulator.serial0_send(text)` and the `serial0-output-byte` event. In the saved state
  it is a logged-in bash of `z` (echo on, prompt `z@z-alpine:~$ `, bracketed paste off). Send a newline first. For
  machine use, `stty -echo; PS1=` and end each command with a marker such as `; echo "@@$?@@"`
  (`tools/images/x86/v86-common.mjs` → `SerialConsole` does exactly this). v86's UART is not rate-limited, so 115200
  is not a bottleneck.
* **The agent.** `zguest` runs as root under `supervise-daemon` and listens on **TCP 127.0.0.1:5555** inside the guest
  (`/etc/conf.d/zguest`; v86 has no virtio-vsock). It speaks [guest-agent/PROTOCOL.md](../guest-agent/PROTOCOL.md)
  version 1: `ping`, `sysinfo`, `exec` (also as the desktop user), `read_file`, `write_file`, `list_dir`,
  `screenshot` (scrot, PNG of the X display), `input` (xdotool: move, click, drag, scroll, type, key), `shutdown`,
  `reboot`. `sysinfo` finds the XFCE session through elogind (`loginctl`) and reports
  `display.type = "x11"`, user `z`, `DISPLAY=:0`. From the serial console, `/usr/local/bin/zg` sends one request and
  prints the response line: `zg ping`, `zg sysinfo`, `zg '{"op":"exec","cmd":"uname -a"}'`. Large results go through
  the 9p share: `zg --png /mnt/host/s.png screenshot` writes the PNG there and `await emulator.read_file("/s.png")`
  reads it on the host side. zguest has **no authentication**: it stays on 127.0.0.1 unless the guest network is
  private to the app (then set `ZGUEST_LISTEN` in `/etc/conf.d/zguest`).
* **Screen.** v86 draws the Bochs VBE framebuffer, 1024×768×32 (`screen-set-size` → `[1024, 768, 32]` on restore).
  The smoke test also reads it directly (`captureScreen()` in `v86-common.mjs`) and compares it with the guest's own
  screenshot.
* **Pointer.** v86 implements the VMware backdoor, and the kernel's `vmmouse` protocol turns it into an absolute
  pointer ("VirtualPS/2 VMware VMMouse", used by Xorg through libinput; v86 reports `vmware-absolute-mouse: true`).
  Send `bus.send("mouse-absolute", [x, y, screenWidth, screenHeight])` **followed by**
  `bus.send("mouse-click", [left, middle, right])` (the current button state): the guest reads the backdoor queue only
  when a PS/2 mouse interrupt arrives, and v86 raises one for a click event but not for a zero `mouse-delta`. The
  browser `MouseAdapter` sends a non-zero `mouse-delta` with every move, which also works. Wheel: `mouse-wheel`.
* **Keyboard.** PS/2: `emulator.keyboard_send_scancodes([...])` with scan code set 1 (press, then `| 0x80` release).
  `keyboard_send_text` needs v86's browser keyboard adapter (`disable_keyboard: false`).
* **Files.** `/mnt/host` is v86's 9p filesystem (`emulator.create_file` / `read_file` on the host side).

## Measurements (GitHub Actions `ubuntu-latest`, Node 22, v86 JIT)

| | |
|---|---|
| image build (apk.static + chroot + mkfs + extlinux) | ~40 s with a warm apk cache |
| power-on → ttyS0 login prompt | BOOT_LOGIN s |
| power-on → `xfce4-session` running | BOOT_SESSION s |
| **power-on → desktop visible** (Xorg, xfce4-session, xfwm4, xfce4-panel, xfdesktop running; panel + desktop windows mapped) | **BOOT_DESKTOP s** |
| power-on → desktop idle (guest CPU > 85 % idle twice in a row) | BOOT_SETTLED s |
| **state restore → serial shell answers** | **RESTORE_SHELL s** |
| whole workflow | ~WORKFLOW_MIN min |

A phone's JIT will differ; the ratio is what matters: a restore is about two orders of magnitude faster than a boot.
Guest memory at the desktop: ~80 MiB used of 488 MiB.

## How it is built

`tools/images/` (all LF line endings, see its `.gitattributes`):

| path | what |
|---|---|
| `x86/packages.txt` | the Alpine packages (one or more per line, `#` comments) |
| `x86/build-image.sh` | needs root on an x86_64 Linux host: downloads `apk-tools-static` for x86, `apk.static --arch x86 --root` installs the packages (with an apk download cache), copies `overlay/` and the zguest binary in, runs `configure.sh` in a chroot (the image's 32-bit binaries run natively on x86_64), then makes a sparse 1536 MiB MBR disk with one ext4 partition, copies the rootfs, installs extlinux + `mbr.bin`, and writes `build-info.txt` |
| `x86/configure.sh` | inside the chroot: apk repositories, hostname, machine-id, user `z`, OpenRC runlevels, initramfs (`ata base ext4 scsi virtio`), `/boot/extlinux.conf`, font/icon/mime caches, the OpenGL prune, the shared-library check |
| `x86/overlay/` | files copied over the rootfs: inittab, fstab, network, Xorg + LightDM + XFCE (xfconf) settings, the `zguest` and `zshare` OpenRC services, `zg`, `z-net-reset`, motd/issue, sudoers |
| `x86/boot-snapshot.mjs` | boots the image in v86 under Node, logs in on ttyS0, waits for the desktop and an idle CPU, collects `guest-info.txt` + a screenshot, checks v86 is on the SVGA framebuffer, `save_state()` |
| `x86/smoke-test.mjs` | restores the state **from the decompressed `.xz` files** and checks it (below) |
| `x86/v86-common.mjs` | the machine options both share, the serial-console driver, v86 framebuffer capture, host pointer input |
| `x86/manifest.mjs` | `manifest.json` + `README.md` |
| `x86/package.json`, `package-lock.json` | pins `v86@0.5.472` |
| `publish.sh` | uploads a downloaded artifact as release `images-v1` (by hand, see below) |

The workflow (`images.yml`, job *Z Alpine Desktop (x86)*): Go 1.23 builds `zguest-linux-386`; `build-image.sh`
(apk cache in `actions/cache`); `npm ci` + SeaBIOS/VGABIOS from the pinned v86 commit, sha256-checked;
`boot-snapshot.mjs`; checks the image is unchanged; `xz -T0 -9`; `smoke-test.mjs`; `manifest.mjs`; uploads the
artifact `z-alpine-desktop-x86` (30 days, uncompressed zip) and `z-alpine-desktop-x86-logs` (serial logs, boot and
smoke reports, guest info, `desktop-*.png` from scrot and `v86-screen-*.png` from v86's framebuffer, the installed
package list). Triggers: `workflow_dispatch`, a monthly `schedule` (Alpine security updates), and — while the branch
is unmerged — pushes to `x86-image-pipeline` that touch the pipeline (`workflow_dispatch` only works once the file is
on the default branch).

Run it by hand (after merge): `gh workflow run images.yml`, `gh run watch`, `gh run download <id> -n z-alpine-desktop-x86`.

Locally on x86_64 Linux: `cd guest-agent && CGO_ENABLED=0 GOOS=linux GOARCH=386 go build -o /tmp/zguest-386 .`, then
`sudo tools/images/x86/build-image.sh out /tmp/zguest-386`, then (in `tools/images/x86`, after `npm ci` and fetching
the two BIOS files) `node boot-snapshot.mjs --bios BIOS --img out/z-alpine-desktop-x86.img --state out/z.state --logs out/logs`
and `node smoke-test.mjs` with the same arguments.

### What the smoke test checks

On a fresh v86 restored from the state (pristine image as an async disk):

1. the serial shell answers `echo ok`;
2. v86's VGA is in graphics mode 1024×768×32, on the SVGA (Bochs VBE) framebuffer;
3. the guest's `/dev/fb0` and X display `:0` are 1024×768; Xorg, xfce4-session, xfwm4, xfce4-panel and xfdesktop run;
   the panel window is mapped;
4. zguest answers `ping` and `sysinfo` (X11 session of `z`), takes a 1024×768 screenshot that is read back over 9p,
   and moves the pointer with `input`;
5. **v86's framebuffer matches the guest's screenshot** (≥ 97 % of pixels; the software cursor and the clock may
   differ) — what the app would show is the desktop;
6. **host input as an app sends it:** a v86 absolute pointer move lands at the right X pointer position, and PS/2
   scancodes type `ok⏎` into an `xfce4-terminal`.

## Publishing (`tools/images/publish.sh`)

The workflow never publishes. After someone has looked at a build (artifact, logs, screenshots) and approved it:

```sh
gh run download <run-id> -R Everaldtah/zcomputer -n z-alpine-desktop-x86 -D /tmp/zad
tools/images/publish.sh /tmp/zad --dry-run      # checks every file against manifest.json, uploads nothing
tools/images/publish.sh /tmp/zad                # creates release images-v1, or replaces its assets
```

The script checks sizes and sha256s against `manifest.json`, then `gh release create images-v1` (not marked latest)
or `gh release upload --clobber` + `gh release edit` with the artifact's `README.md` as release notes. Options:
`--repo OWNER/REPO`, `--tag NAME`. It needs `gh` logged in with write access. Note: release assets of a public
repository are public.

## Updating

* Packages: edit `x86/packages.txt` (the apk cache key follows it); settings: `x86/overlay/` or `configure.sh`.
* A new v86: bump `package.json` + `package-lock.json`, set `V86_COMMIT` and the two BIOS sha256s in `images.yml` to
  the commit that npm build came from (the `version` in the tarball's own `package.json` ends in `+g<short sha>`),
  rebuild. **Every v86 bump needs a
  new state** (and the app must ship the same v86 build that made it).
* Any image change needs a new state; never publish an image without the state built from it (`manifest.json` binds
  them through `decompressedSha256`).

## Known limits

* No OpenGL / no compositor; software rendering only.
* One vCPU (v86 emulates one); the state was taken with 512 MiB RAM, so restore with the same `memory_size`.
* xf86-input-vmmouse is installed but unused: the kernel's vmmouse protocol + libinput is the path Xorg takes.
* No audio: the image has no ALSA/PulseAudio userspace (v86 emulates a SoundBlaster 16, unused here).
* zguest over the serial console or 127.0.0.1 only; there is no virtio-vsock in v86.

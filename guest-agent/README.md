# zguest — Z Computer guest agent

`zguest` is a small daemon that runs inside a Linux VM and lets the Z Computer
macOS app drive it: run shell commands, read/write/list files, take
screenshots, inject mouse and keyboard input, read system info, and power off
or reboot. It listens on **AF_VSOCK port 5555** and speaks newline-delimited
JSON — the wire format is specified in [PROTOCOL.md](PROTOCOL.md).

* Go, standard library only, no cgo: one static binary per architecture
  (`linux/arm64` for Apple-silicon hosts, `linux/amd64`).
* Runs as root under systemd; screenshot and input (and `exec` with
  `"desktop": true`) run as the logged-in desktop user with that session's
  `DISPLAY` / `WAYLAND_DISPLAY` / `XAUTHORITY` / `XDG_RUNTIME_DIR`.
* Logs to stderr (the journal under systemd): `journalctl -u zguest -f`.

## Build

```sh
cd guest-agent
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -trimpath -ldflags="-s -w" -o zguest-linux-arm64 .
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags="-s -w" -o zguest-linux-amd64 .
go test ./...
```

Set the version with `-ldflags "-X main.version=1.2.3"`. CI (`Guest agent (Go)`
in `.github/workflows/ci.yml`) builds both binaries and runs the tests; the
macOS app bundles them as resources.

## Provisioning a guest

What ends up in the VM:

| path | what |
|---|---|
| `/usr/local/bin/zguest` | the binary for the guest's architecture |
| `/etc/systemd/system/zguest.service` | [`systemd/zguest.service`](systemd/zguest.service): runs `/usr/local/bin/zguest` as root, `Restart=always`, enabled for `multi-user.target` |
| `/etc/systemd/system/zguest.service.d/listen.conf` | only when installed with `--tcp`/`--port` (overrides `ExecStart`) |

`install.sh` does all of it. Put `zguest-linux-<arch>` (or `zguest`),
`install.sh` and `systemd/` in one directory — the app shares such a folder into
the guest over virtio-fs — and run:

```sh
sudo sh install.sh                           # vsock, port 5555
sudo sh install.sh --binary ./zguest-linux-arm64
sudo sh install.sh --tcp 127.0.0.1:5555      # no virtio-vsock device
sudo sh install.sh --uninstall
```

The script copies the binary, installs the unit (an embedded copy is used when
`systemd/zguest.service` is not next to it), loads the virtio vsock transport
if `/dev/vsock` is missing, then `systemctl enable` + `restart` and checks that
the service is running. Without systemd it prints the command to start the
agent manually.

Manual equivalent, e.g. typed by the host into the serial console of a fresh
guest with the share mounted at `/mnt/zshare`:

```sh
install -m 0755 /mnt/zshare/zguest-linux-arm64 /usr/local/bin/zguest
install -m 0644 /mnt/zshare/systemd/zguest.service /etc/systemd/system/zguest.service
systemctl daemon-reload && systemctl enable --now zguest
```

### Command line

```
zguest [--port N | --tcp HOST:PORT] [--version]
  --port N          AF_VSOCK port (default 5555), any CID
  --tcp HOST:PORT   listen on TCP instead, e.g. 127.0.0.1:5555
  --version         print the version and exit
```

`--tcp` is the fallback for VMs without virtio-vsock (other hypervisors, nested
setups); reach it through a port forward or SSH tunnel. **There is no
authentication** — anyone who can connect gets root — so never bind it to an
address outside a private host-only network.

If the vsock socket cannot be created at start-up (transport module not loaded
yet) the agent retries for 30 s, then exits and systemd restarts it.

SIGTERM/SIGINT: stops accepting, lets running requests finish for up to 10 s,
then kills remaining commands and exits.

## Desktop tools in the guest

`exec`, files and `sysinfo` need nothing extra. Screenshot and input use
whatever is installed (see `sysinfo.tools`):

| desktop | screenshot | input |
|---|---|---|
| GNOME (Wayland/X11) | `gnome-screenshot` | X11: `xdotool`; Wayland: `ydotool` + `ydotoold` |
| KDE Plasma | `spectacle` | X11: `xdotool`; Wayland: `ydotool` |
| sway / Hyprland / wlroots | `grim` | `ydotool` (mouse), `wtype` (keyboard) |
| Xfce, LXQt, MATE, i3, Xvfb (X11) | `scrot`, ImageMagick `import`, or `xwd` + `convert` | `xdotool` |

Debian/Ubuntu: `sudo apt install scrot xdotool` covers X11 desktops;
`sudo apt install grim wtype ydotool` covers wlroots compositors. ydotool needs
its daemon (`ydotoold`, e.g. `systemctl enable --now ydotoold` where packaged)
and works on every Wayland compositor because it injects events through
`/dev/uinput`.

When no tool works the error message lists what was tried and what to install.

The graphical session is found through `loginctl` (first graphical user
session), falling back to scanning `/proc/*/environ`; with GDM auto-login or a
logged-in user this needs no configuration. A login screen (greeter session) is
used only when no user is logged in.

## Layout

| file | |
|---|---|
| `main.go` | flags, logging, listener, signals |
| `server.go` | connections, framing (64 MiB lines), dispatch, graceful shutdown |
| `protocol.go` | request/response encoding, error codes |
| `vsock_linux.go` / `vsock_other.go` | raw-syscall AF_VSOCK listener / stub |
| `session.go` | desktop session detection, running helpers as the session user |
| `ops_info.go` | `ping`, `sysinfo` |
| `ops_exec.go` | `exec` |
| `ops_files.go` | `read_file`, `write_file`, `list_dir` |
| `ops_screenshot.go` | `screenshot` |
| `ops_input.go` | `input` (xdotool / ydotool / wtype command builders) |
| `ops_power.go` | `shutdown`, `reboot` |
| `sys_unix.go` / `sys_other.go` | process groups, credentials, file owners |

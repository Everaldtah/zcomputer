# zguest wire protocol (version 1)

The contract between the guest agent `zguest` (this directory) and the host-side
`GuestAgentClient` (Swift, ZVM). Everything here is implemented and covered by
`go test`; when the two disagree, fix one of them and this file.

## Transport

* **AF_VSOCK** stream socket, guest listens on **port 5555**, any CID
  (`VMADDR_CID_ANY`). On Apple Virtualization the host connects with
  `VZVirtioSocketDevice.connect(toPort: 5555)`.
* Fallback: TCP, when the agent runs with `--tcp HOST:PORT` (VMs without a
  virtio-vsock device). Same protocol, no authentication.
* A client may open **several connections at once**; they are served
  concurrently. On one connection requests are handled **strictly one after
  another** and responses come back **in request order**, so a client may
  pipeline (send several requests before reading) and match responses by order
  or by `id`. A long `exec` blocks only its own connection; use a second
  connection for screenshots/pings while a command runs.
* The agent never sends anything unsolicited. Connections stay open until the
  client closes them (no idle timeout).

## Framing

* UTF-8 JSON, **one object per line**, terminated by `\n` (a trailing `\r` is
  tolerated). Blank lines are ignored (no response).
* Request lines may be up to **64 MiB** (67 108 864 bytes, newline not counted).
  A longer line is read and discarded, answered with
  `{"id":"","ok":false,"code":"too_large",...}`, and the connection stays usable.
* Responses are single lines as well. The largest responses are `read_file`
  (≤ 48 MiB of data → ≤ 64 MiB base64), `screenshot` and `exec`
  (≤ 2 × 8 MiB of output), so a client should allow lines of at least 64 MiB.
* A final request without a trailing newline is still answered when the client
  half-closes (EOF).

## Requests

```json
{"id":"42","op":"exec","cmd":"uname -a","timeout_ms":5000}
```

| field | type | |
|---|---|---|
| `id` | string, optional | Echoed verbatim in the response. Absent or `null` → `""`. A non-string id is a `bad_request`. |
| `op` | string, required | One of the ops below. |
| … | | Op parameters, at the top level next to `id`/`op`. Unknown fields are ignored. |

## Responses

Success — `id`, `ok:true`, then the op's result fields **flattened at the top level**:

```json
{"id":"42","ok":true,"stdout":"Linux vm 6.8.0 ...\n","stderr":"","exit_code":0, ...}
```

Failure:

```json
{"id":"42","ok":false,"error":"open /nope: no such file or directory","code":"not_found"}
```

`id` is `""` when the request could not be parsed (malformed JSON, non-object,
non-string id, line too long).

| `code` | meaning |
|---|---|
| `bad_request` | malformed JSON, missing/invalid parameter |
| `unknown_op` | the op does not exist in this agent version (check `ping.ops`) |
| `too_large` | request line longer than 64 MiB |
| `not_found` | file, directory or `cwd` does not exist (ENOENT) |
| `permission_denied` | EACCES / EPERM |
| `unavailable` | no desktop session, required tool not installed, unsupported here; the message says what to install |
| `failed` | the operation ran and failed (tool exited non-zero, I/O error, …) |
| `internal` | bug in the agent (recovered panic) |

`error` is always a human-readable message suitable for showing to the model.

Conventions: integers are JSON numbers; times are milliseconds (`*_ms`),
seconds (`uptime`, a float) or Unix seconds (`mtime`); binary data is standard
base64 with padding (`*_b64`); text output is UTF-8 with invalid bytes replaced
by U+FFFD. Optional result fields marked "omitted when empty" are absent rather
than `""`.

---

## Ops

### `ping`

No parameters.

| result | type | |
|---|---|---|
| `version` | string | agent version, e.g. `"0.1.0"` |
| `protocol` | int | protocol version, `1` |
| `uptime` | number | seconds since the agent started (3 decimals) |
| `ops` | [string] | ops this agent supports, sorted |

```json
{"id":"1","op":"ping"}
{"id":"1","ok":true,"version":"0.1.0","protocol":1,"uptime":12.345,"ops":["exec","input","list_dir","ping","read_file","reboot","screenshot","shutdown","sysinfo","write_file"]}
```

### `sysinfo`

No parameters.

| result | type | |
|---|---|---|
| `version` | string | agent version |
| `hostname` | string | |
| `os` | string | `PRETTY_NAME` from `/etc/os-release` (e.g. `"Ubuntu 24.04.1 LTS"`) |
| `osId` | string | `ID` (e.g. `"ubuntu"`, `"debian"`, `"fedora"`), may be `""` |
| `osVersion` | string | `VERSION_ID`, may be `""` |
| `kernel` | string | kernel release (`uname -r`) |
| `arch` | string | `uname -m` style: `"aarch64"`, `"x86_64"` |
| `cpus` | int | online CPUs |
| `memTotal` | int | bytes |
| `memFree` | int | bytes available (`MemAvailable`; `MemFree` on very old kernels) |
| `uptime` | number | system uptime in seconds |
| `agentUser` | string | user the agent runs as (normally `"root"`) |
| `display` | object | the graphical session, see below |
| `tools` | {string: bool} | presence on `PATH` of: `grim`, `spectacle`, `gnome-screenshot`, `scrot`, `import`, `xwd`, `convert`, `magick`, `xdotool`, `ydotool`, `wtype`, `loginctl`, `systemctl`, `bash` |

`display`:

| field | type | |
|---|---|---|
| `wayland` | bool | a Wayland compositor socket is known (`WAYLAND_DISPLAY`) |
| `x11` | bool | an X display is known (`DISPLAY`; XWayland counts) |
| `type` | string | `"wayland"`, `"x11"` or `""` (no session) |
| `user` | string | session user name, `""` when none |
| `uid` | int | session user id, `-1` when none |
| `session` | string | logind session id, `""` when found without logind |
| `desktop` | string | `XDG_CURRENT_DESKTOP` (e.g. `"ubuntu:GNOME"`), may be `""` |
| `source` | string | how it was found: `"loginctl"`, `"proc"` (scan of `/proc/*/environ`), `"self"` (agent's own env), `""` |
| `env` | {string: string} | the session variables used for screenshot/input: any of `DISPLAY`, `WAYLAND_DISPLAY`, `XAUTHORITY`, `XDG_RUNTIME_DIR`, `DBUS_SESSION_BUS_ADDRESS`, `XDG_SESSION_TYPE`, `XDG_CURRENT_DESKTOP`, `XDG_SESSION_DESKTOP`, `DESKTOP_SESSION`, `SWAYSOCK`, `HYPRLAND_INSTANCE_SIGNATURE`, `YDOTOOL_SOCKET`; `{}` when none |
| `error` | string | why no session was found; omitted when one was |

Session detection (also used by `screenshot`, `input`, `exec` with
`desktop:true`; cached for 5 s): the agent's own `DISPLAY`/`WAYLAND_DISPLAY`
if set → the first graphical logind session (user sessions before greeters,
active before online, local before remote) → any process with
`DISPLAY`/`WAYLAND_DISPLAY` in its environment. The environment is copied from
that user's compositor/desktop-shell process when recognisable; missing values
are derived from `/run/user/<uid>` (`wayland-*` socket, `bus`) and
`/tmp/.X11-unix`, `XAUTHORITY` from `~/.Xauthority`, GDM's runtime file or the X
server's `-auth` argument.

### `exec`

Runs a shell command: `bash -lc <cmd>` (login shell), or `sh -c <cmd>` when bash
is not installed.

| param | type | default | |
|---|---|---|---|
| `cmd` | string | required | shell command line |
| `timeout_ms` | int | `60000` | kill after this long; `0` = default; max 24 h (larger values are clamped); negative = `bad_request` |
| `cwd` | string | `$HOME` of the user it runs as | absolute path; must be an existing directory (`not_found` / `bad_request`) |
| `env` | {string: string} | | added to / overrides the environment (the agent's own, or the session's with `desktop:true`; `TERM=dumb` and `DEBIAN_FRONTEND=noninteractive` are set when absent) |
| `stdin` | string | | fed to the command's stdin; when absent stdin is `/dev/null` (EOF) |
| `desktop` | bool | `false` | run as the logged-in desktop user with the session environment (`DISPLAY`, `WAYLAND_DISPLAY`, `XAUTHORITY`, `XDG_RUNTIME_DIR`, `DBUS_SESSION_BUS_ADDRESS`, `HOME`, `USER`) — use it to launch GUI apps; `unavailable` when there is no session |

| result | type | |
|---|---|---|
| `stdout` | string | first 8 MiB of stdout |
| `stderr` | string | first 8 MiB of stderr |
| `exit_code` | int | exit status; `-1` when killed by a signal |
| `signal` | string | e.g. `"SIGKILL"` when killed by a signal; omitted otherwise |
| `timed_out` | bool | the timeout fired and the process group was killed |
| `truncated` | bool | `stdout_truncated || stderr_truncated` |
| `stdout_truncated` | bool | more than 8 MiB was written to stdout (the rest was discarded) |
| `stderr_truncated` | bool | same for stderr |
| `duration_ms` | int | wall time |
| `shell` | string | `"bash"` or `"sh"` |
| `user` | string | session user name when `desktop:true`; omitted otherwise |

A non-zero exit or a timeout is still `ok:true` — inspect `exit_code` /
`timed_out`. `ok:false` means the command could not be run at all.

The command runs in its own process group; on timeout the **whole group** gets
SIGKILL. Background processes: exec returns about 2 s after the shell exits
even if a background child still holds stdout/stderr open, then closes the
pipes — so start long-running programs with their output redirected and
detached, e.g. `setsid nohup firefox >/dev/null 2>&1 &` (they then also survive
the timeout kill).

```json
{"id":"7","op":"exec","cmd":"echo hi; exit 3","timeout_ms":5000}
{"id":"7","ok":true,"stdout":"hi\n","stderr":"","exit_code":3,"timed_out":false,"truncated":false,"stdout_truncated":false,"stderr_truncated":false,"duration_ms":4,"shell":"bash"}
```

### `read_file`

| param | type | default | |
|---|---|---|---|
| `path` | string | required | absolute path of a regular file (`/proc` and `/sys` files work) |
| `max_bytes` | int | 16 MiB | return at most this many bytes; capped at 48 MiB |
| `offset` | int | `0` | start reading at this byte offset |

| result | type | |
|---|---|---|
| `path` | string | cleaned path |
| `data_b64` | string | base64 of the bytes read |
| `size` | int | file size in bytes (for size-0 pseudo files: bytes read) |
| `truncated` | bool | more data follows after `offset + len(data)`; read again with a larger `offset` |

Errors: `not_found`, `permission_denied`, `bad_request` (relative path,
directory, FIFO/device/socket, negative numbers).

### `write_file`

| param | type | default | |
|---|---|---|---|
| `path` | string | required | absolute path |
| `data_b64` | string | required | base64 content; `""` writes an empty file |
| `mode` | string or int | `"0644"` for new files, unchanged for existing ones | octal string (`"0755"`, `"755"`, `"0o755"`) or the numeric value (`493`); `0`–`07777` incl. setuid/setgid/sticky. When given it is applied with chmod after writing (not subject to the umask). |
| `mkdir` | bool | `false` | create missing parent directories (mode 0755) |
| `append` | bool | `false` | append instead of truncating |

| result | type | |
|---|---|---|
| `path` | string | cleaned path |
| `written` | int | bytes written by this call |
| `size` | int | file size after the write |

Ownership: the agent runs as root; a **newly created** file (and directories
made by `mkdir`) gets the owner and group of its parent directory, so files
written into `/home/alice/...` belong to alice. Existing files keep their owner.
Errors: `not_found` (parent directory missing without `mkdir`),
`permission_denied`, `bad_request` (relative path, invalid base64/mode),
`failed` (e.g. path is a directory).

### `list_dir`

| param | type | |
|---|---|---|
| `path` | string, required | absolute path of a directory |

| result | type | |
|---|---|---|
| `path` | string | cleaned path |
| `entries` | [entry] | sorted by name; `[]` for an empty directory; at most 10 000 |
| `truncated` | bool | there were more than 10 000 entries |

entry:

| field | type | |
|---|---|---|
| `name` | string | file name (not a path) |
| `isDir` | bool | directory, or a symlink to one |
| `isSymlink` | bool | the entry itself is a symlink |
| `size` | int | bytes (of the target for symlinks that resolve) |
| `mode` | string | `ls`-style mode of the entry itself, e.g. `"-rw-r--r--"`, `"drwxr-xr-x"`, `"Lrwxrwxrwx"` (symlink) |
| `mtime` | int | modification time of the entry, Unix seconds |

Errors: `not_found`, `permission_denied`, `bad_request` (relative path, not a directory).

### `screenshot`

Captures the whole desktop of the graphical session as PNG, running the capture
tool as the session user with the session environment.

| param | type | |
|---|---|---|
| `display` | string, optional | `":N"` → capture X display `:N` with X11 tools only (also works without a detected session, e.g. an Xvfb); any other value → Wayland output name for `grim -o` |

Tools are tried in this order, skipping those that do not apply to the
session or are not installed; the first one that produces a valid PNG wins:

1. `grim <file>` — Wayland (wlroots: sway, Hyprland, labwc, …)
2. `spectacle -b -n -f -o <file>` — KDE
3. `gnome-screenshot -f <file>` — GNOME
4. `scrot <file>` — X11
5. `import -window root <file>` — X11 (ImageMagick)
6. `xwd -root -silent | convert xwd:- png:<file>` (or `magick`) — X11

| result | type | |
|---|---|---|
| `png_b64` | string | base64 PNG |
| `width` | int | pixels |
| `height` | int | pixels |
| `tool` | string | `"grim"`, `"spectacle"`, `"gnome-screenshot"`, `"scrot"`, `"import"` or `"xwd"` |
| `session` | string | `"wayland"` or `"x11"` |
| `warning` | string | omitted when empty; set when an X11 tool captured a Wayland session through XWayland (native Wayland windows may be missing) |

Errors: `unavailable` when there is no graphical session, or when no tool
worked — the message lists each tool's failure, the tools that are not
installed, and what to install (`sudo apt install grim` / `gnome-screenshot` /
`kde-spectacle` / `scrot`).

### `input`

Injects mouse and keyboard events into the session, in order. Coordinates are
screen pixels of the session (the same space as `screenshot`).

| param | type | |
|---|---|---|
| `actions` | [action], required | 1–200 actions, performed in order; stops at the first failure |
| `backend` | string, optional | `"auto"` (default), `"xdotool"`, `"wayland"`, `"ydotool"` (Wayland, ydotool only), `"wtype"` (Wayland, wtype only) |

action:

| `type` | fields | effect |
|---|---|---|
| `click` | `x`,`y` optional; `button` `"left"`(default)/`"right"`/`"middle"`; `count` 1–10 (default 1) | move to (x,y) when given, then click |
| `double_click` | `x`,`y` optional | left double click |
| `right_click` | `x`,`y` optional | right click |
| `middle_click` | `x`,`y` optional | middle click |
| `mouse_move` | `x`,`y` required | move the pointer |
| `mouse_down` | `x`,`y` optional; `button` | press and hold a button |
| `mouse_up` | `x`,`y` optional; `button` | release a button |
| `drag` | `x`,`y` required (start); `to_x`,`to_y` (end) — or `dx`,`dy` relative to the start | left-button drag |
| `scroll` | `x`,`y` optional; `dx`,`dy` wheel steps (−100…100, at least one non-zero) | `dy > 0` scrolls down, `dy < 0` up, `dx > 0` right, `dx < 0` left |
| `type` | `text` required | types the text literally (unicode with xdotool/wtype; US-ASCII with ydotool) |
| `key` | `key` required | key combos, xdotool style: `"Return"`, `"ctrl+c"`, `"ctrl+shift+t"`, `"alt+F4"`, `"super"`; several combos separated by spaces are pressed one after another (`"ctrl+a Delete"`) |

`x`/`y` must be given together and must not be negative. Key names are case
insensitive aliases or X keysym names: modifiers `ctrl`/`control`, `alt`/`option`,
`shift`, `super`/`cmd`/`meta`/`win`; keys `Return`/`enter`, `Escape`/`esc`,
`Tab`, `space`, `BackSpace`, `Delete`, `Insert`, `Home`, `End`,
`Page_Up`/`pageup`, `Page_Down`/`pagedown`, `Up`, `Down`, `Left`, `Right`,
`F1`–`F24`, `Caps_Lock`, `Print`, `Menu`, single characters (`a`, `A`, `1`, `/`,
`+` … — `ctrl++` is ctrl and plus) and any other keysym (`XF86AudioMute`,
`KP_Enter`; xdotool/wtype only).

Backends (`auto`):

* X11 session → `xdotool` (as the session user).
* Wayland session → mouse via `ydotool` ≥ 1.0 (needs `ydotoold` running; run as
  root; the socket is taken from `YDOTOOL_SOCKET`,
  `$XDG_RUNTIME_DIR/.ydotool_socket` or `/tmp/.ydotool_socket`); `type`/`key`
  via `wtype` (wlroots compositors) when installed, else via ydotool.
  Without ydotool/wtype but with XWayland and xdotool, xdotool is used and a
  `warning` is returned (only X11 windows receive the input).
* Absolute pointer positioning with ydotool can be off on scaled displays.

| result | type | |
|---|---|---|
| `backend` | string | tools actually used, joined with `+` and sorted: `"xdotool"`, `"ydotool"`, `"wtype"`, `"wtype+ydotool"` |
| `performed` | int | number of actions performed (= `len(actions)` on success) |
| `warning` | string | omitted when empty |

Errors: `bad_request` (invalid action — nothing is performed; the message names
the action index), `unavailable` (no session / backend not installed, with the
install command), `failed` (a tool failed; the message says how many actions
were performed before it).

```json
{"id":"9","op":"input","actions":[{"type":"click","x":640,"y":400},{"type":"type","text":"hello"},{"type":"key","key":"Return"}]}
{"id":"9","ok":true,"backend":"xdotool","performed":3}
```

### `shutdown` / `reboot`

No parameters. Answers first, then runs `systemctl poweroff` / `systemctl reboot`
(fallback `shutdown -h|-r now`, then `poweroff`/`reboot`) after 500 ms. The
connection then drops.

| result | type | |
|---|---|---|
| `action` | string | `"poweroff"` or `"reboot"` |
| `delay_ms` | int | `500` |

Errors: `unavailable` when none of the commands exists.

---

## Versioning

New ops and new optional fields may be added without changing `protocol`;
clients must ignore unknown response fields and should check `ping.ops` before
using an op. Incompatible changes bump `protocol`.

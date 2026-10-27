#!/bin/sh
# Installs the Z Computer guest agent: /usr/local/bin/zguest plus the
# zguest.service systemd unit, then enables and (re)starts it.
#
#   sudo ./install.sh [--binary PATH] [--tcp HOST:PORT] [--port N]
#   sudo ./install.sh --uninstall
#
# Without --binary the script looks next to itself for zguest,
# zguest-linux-<arch> or bin/zguest-linux-<arch>.
# --tcp makes the agent listen on TCP instead of AF_VSOCK (VMs without a
# virtio-vsock device). The TCP port is unauthenticated root access: bind it
# to 127.0.0.1 or a private host-only network only.
set -eu

BIN_DST=/usr/local/bin/zguest
UNIT_DST=/etc/systemd/system/zguest.service
DROPIN_DIR=/etc/systemd/system/zguest.service.d
DROPIN="$DROPIN_DIR/listen.conf"
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

binary=""
tcp=""
port=""
uninstall=0

usage() {
    sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --binary) binary=${2:?--binary needs a path}; shift 2 ;;
        --tcp) tcp=${2:?--tcp needs HOST:PORT}; shift 2 ;;
        --port) port=${2:?--port needs a number}; shift 2 ;;
        --uninstall) uninstall=1; shift ;;
        -h|--help) usage 0 ;;
        *) echo "install.sh: unknown argument: $1" >&2; usage 2 ;;
    esac
done

if [ "$(id -u)" -ne 0 ]; then
    echo "install.sh: must run as root (try: sudo $0)" >&2
    exit 1
fi

have_systemd() {
    command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]
}

if [ "$uninstall" -eq 1 ]; then
    if have_systemd; then
        systemctl disable --now zguest.service 2>/dev/null || true
    fi
    rm -f "$UNIT_DST" "$DROPIN" "$BIN_DST"
    rmdir "$DROPIN_DIR" 2>/dev/null || true
    if have_systemd; then systemctl daemon-reload; fi
    echo "zguest removed"
    exit 0
fi

case "$(uname -m)" in
    x86_64|amd64) arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) arch=$(uname -m) ;;
esac

if [ -z "$binary" ]; then
    for cand in "$HERE/zguest" "$HERE/zguest-linux-$arch" "$HERE/bin/zguest-linux-$arch" "$HERE/../out/zguest-linux-$arch"; do
        if [ -f "$cand" ]; then binary=$cand; break; fi
    done
fi
if [ -z "$binary" ] || [ ! -f "$binary" ]; then
    echo "install.sh: zguest binary not found; pass --binary PATH (expected zguest-linux-$arch)" >&2
    exit 1
fi

# Stop a running copy first so the binary can be replaced.
if have_systemd && systemctl is-active --quiet zguest.service 2>/dev/null; then
    systemctl stop zguest.service
fi
install -D -m 0755 "$binary" "$BIN_DST"
echo "installed $BIN_DST ($("$BIN_DST" --version 2>/dev/null || echo 'version unknown'))"

if ! have_systemd; then
    echo "install.sh: systemd not found; start the agent from your init system, e.g.:" >&2
    echo "  $BIN_DST ${tcp:+--tcp $tcp} >/var/log/zguest.log 2>&1 &" >&2
    exit 0
fi

if [ -f "$HERE/systemd/zguest.service" ]; then
    install -D -m 0644 "$HERE/systemd/zguest.service" "$UNIT_DST"
elif [ -f "$HERE/zguest.service" ]; then
    install -D -m 0644 "$HERE/zguest.service" "$UNIT_DST"
else
    # Keep in sync with systemd/zguest.service.
    cat >"$UNIT_DST" <<'EOF'
[Unit]
Description=Z Computer guest agent (zguest)
Documentation=https://github.com/Everaldtah/zcomputer/tree/main/guest-agent
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=/usr/local/bin/zguest
User=root
Restart=always
RestartSec=2
KillMode=process

[Install]
WantedBy=multi-user.target
EOF
    chmod 0644 "$UNIT_DST"
fi
echo "installed $UNIT_DST"

# Listening options go into a drop-in so the unit file stays pristine.
args=""
[ -n "$tcp" ] && args="$args --tcp $tcp"
[ -n "$port" ] && args="$args --port $port"
if [ -n "$args" ]; then
    mkdir -p "$DROPIN_DIR"
    printf '[Service]\nExecStart=\nExecStart=%s%s\n' "$BIN_DST" "$args" >"$DROPIN"
    echo "installed $DROPIN (zguest$args)"
else
    rm -f "$DROPIN"
fi

# The vsock transport for Apple Virtualization / QEMU guests.
if [ -z "$tcp" ] && [ ! -e /dev/vsock ]; then
    modprobe vmw_vsock_virtio_transport 2>/dev/null || true
    [ -e /dev/vsock ] || echo "warning: /dev/vsock is missing; this VM may have no virtio-vsock device (consider --tcp)" >&2
fi

systemctl daemon-reload
systemctl enable zguest.service >/dev/null
systemctl restart zguest.service
sleep 1
if systemctl is-active --quiet zguest.service; then
    echo "zguest is running ($(systemctl show -p MainPID --value zguest.service 2>/dev/null | sed 's/^/pid /'))"
else
    echo "zguest failed to start; see: journalctl -u zguest -n 50" >&2
    exit 1
fi

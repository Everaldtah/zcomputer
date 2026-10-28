import Foundation
import ZCore

/// The desktop cloud-init installs on first boot.
public enum DesktopPreset: String, Codable, Sendable, Hashable, CaseIterable {
    /// Terminal only.
    case none
    /// Xfce on Xorg with LightDM auto-login, xdotool/scrot/xclip, a browser and spice-vdagent; no blanking or
    /// locking; 1280×800 when the scanout offers it (docs/research/images.md A.4). X11 because xdotool and
    /// screenshots do not work on GNOME/Wayland (A.7).
    case xfceX11

    public var displayName: String {
        switch self {
        case .none: return "No desktop"
        case .xfceX11: return "Xfce (X11)"
        }
    }

    /// Whether this preset has a recipe for `family`. Debian 13 and Ubuntu 24.04 package lists are verified against
    /// the real indexes; Fedora, EL9, openSUSE, Arch and Alpine follow the research recipes (UNVERIFIED in a VM).
    /// EL10 has no Xorg server and no XFCE in EPEL 10, so it stays terminal-only.
    public func isSupported(on family: DistroFamily) -> Bool {
        switch self {
        case .none: return true
        case .xfceX11: return ProvisionScripts.desktopPackages(family) != nil
        }
    }
}

/// Developer tools installed on first boot from the distribution's own repositories.
public enum DevPreset: String, Codable, Sendable, Hashable, CaseIterable {
    case none
    /// git, curl, a C toolchain, Python 3 (+ pip/venv), Node.js + npm, tmux, ripgrep.
    case standard

    public var displayName: String {
        switch self {
        case .none: return "No developer tools"
        case .standard: return "git, build tools, Python, Node.js, tmux, ripgrep"
        }
    }

    public func isSupported(on family: DistroFamily) -> Bool {
        self == .none || ProvisionScripts.devTools(family) != nil
    }
}

/// One first-boot provisioning step, run by `/usr/local/sbin/zc-provision` from cloud-init's `runcmd`.
public struct ProvisionStep: Sendable, Hashable {
    /// Machine-readable stage (`agent`, `desktop-packages`, `desktop-config`, `dev-tools`).
    public var stage: String
    public var label: String
    /// Where the step's script is written in the guest (nil: the step only records progress).
    public var scriptPath: String?
    public var script: String?

    public init(stage: String, label: String, scriptPath: String? = nil, script: String? = nil) {
        self.stage = stage; self.label = label; self.scriptPath = scriptPath; self.script = script
    }
}

/// The progress file the seed writes in the guest (`/var/lib/zguest/provision.status`, `key=value` lines). The app
/// reads it through the guest agent's `read_file` to show "desktop installing (n/total)".
public struct ProvisionStatus: Sendable, Hashable {
    public enum State: String, Sendable, Hashable {
        /// The step is running.
        case running
        /// The step finished; the next one has not started yet.
        case ok
        /// Every step finished: the machine is ready.
        case done
        case failed
    }

    public static let path = "/var/lib/zguest/provision.status"
    /// The runner's log in the guest.
    public static let logPath = "/var/log/zcomputer-provision.log"

    public var step: Int
    public var total: Int
    public var stage: String
    public var state: State
    public var label: String
    public var detail: String?
    public var updated: Date?

    public init(step: Int, total: Int, stage: String, state: State, label: String, detail: String? = nil, updated: Date? = nil) {
        self.step = step; self.total = total; self.stage = stage; self.state = state; self.label = label
        self.detail = detail; self.updated = updated
    }

    public var isDone: Bool { state == .done }
    public var isFailed: Bool { state == .failed }

    /// Parses the file; nil when it has no `state` / `stage`.
    public static func parse(_ text: String) -> ProvisionStatus? {
        var fields: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
            fields[key] = String(line[line.index(after: eq)...])
        }
        guard let rawState = fields["state"], let state = State(rawValue: rawState),
              let stage = fields["stage"], !stage.isEmpty else { return nil }
        let step = fields["step"].flatMap { Int($0) } ?? 0
        let total = fields["total"].flatMap { Int($0) } ?? 0
        let updated = fields["updated"].flatMap { Double($0) }.map { Date(timeIntervalSince1970: $0) }
        let detail = fields["detail"].flatMap { $0.isEmpty ? nil : $0 }
        return ProvisionStatus(step: step, total: total, stage: stage, state: state, label: fields["label"] ?? stage,
                               detail: detail, updated: updated)
    }
}

/// The shell scripts behind the presets (POSIX `sh`, run as root). Package lists come from
/// docs/research/images.md A.4: Debian 13 and Ubuntu 24.04 were verified against the real package indexes.
public enum ProvisionScripts {
    /// Folder for the step scripts in the guest.
    public static let directory = "/usr/local/lib/zcomputer/provision"
    /// The step runner.
    public static let runnerPath = "/usr/local/sbin/zc-provision"

    /// apt with a long lock timeout (first-boot apt-daily / unattended-upgrades) and no fsync per package.
    static let aptPrelude = #"""
        set -e
        export DEBIAN_FRONTEND=noninteractive
        echo 'man-db man-db/auto-update boolean false' | debconf-set-selections
        apt_get() { apt-get -y -q -o DPkg::Lock::Timeout=600 -o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-unsafe-io "$@"; }
        """#

    /// The verified Debian 13 (trixie main, arm64 + amd64) package line, without Recommends (A.4.1, block 1).
    public static let debianDesktopInstall = #"""
        apt_get install --no-install-recommends \
          xserver-xorg-core xserver-xorg-input-libinput x11-xserver-utils \
          lightdm lightdm-gtk-greeter \
          xfce4 xfce4-terminal dbus-x11 dbus-user-session at-spi2-core adwaita-icon-theme \
          xdotool scrot xclip \
          firefox-esr fonts-dejavu-core fonts-liberation2 \
          spice-vdagent
        """#

    /// The verified Ubuntu 24.04 (noble main + universe) package line: `firefox` comes from Mozilla's APT repo (A.4.2).
    public static let ubuntuDesktopInstall = #"""
        apt_get install --no-install-recommends \
          xserver-xorg-core xserver-xorg-input-libinput x11-xserver-utils \
          lightdm lightdm-gtk-greeter \
          xfce4 xfce4-terminal dbus-x11 dbus-user-session at-spi2-core adwaita-icon-theme \
          xdotool scrot xclip \
          firefox fonts-dejavu-core fonts-liberation2 \
          spice-vdagent
        """#

    /// SHA-256 of https://packages.mozilla.org/apt/repo-signing-key.gpg (fingerprint 35BA A0B3 3E9E B396 F59C
    /// A838 C0BA 5CE6 DC63 15A3, checked 2026-10-27). The minimal image has no gpg, so the file hash is pinned.
    public static let mozillaKeySHA256 = "3ecc63922b7795eb23fdc449ff9396f9114cb3cf186d6f5b53ad4cc3ebfbb11f"

    /// Ubuntu's noble `firefox` is a snap shim: add Mozilla's APT repo (arm64 + amd64) with a pin above the shim.
    static let mozillaRepository = #"""
        command -v curl >/dev/null 2>&1 || { apt_get update; apt_get install --no-install-recommends curl ca-certificates; }
        install -d -m 0755 /etc/apt/keyrings
        curl -fsSL https://packages.mozilla.org/apt/repo-signing-key.gpg -o /etc/apt/keyrings/packages.mozilla.org.asc
        echo '\#(mozillaKeySHA256)  /etc/apt/keyrings/packages.mozilla.org.asc' | sha256sum -c -
        echo 'deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.asc] https://packages.mozilla.org/apt mozilla main' > /etc/apt/sources.list.d/mozilla.list
        printf 'Package: *\nPin: origin packages.mozilla.org\nPin-Priority: 1000\n' > /etc/apt/preferences.d/mozilla
        """#

    /// Installs the Xfce/X11 packages (nil when the family has no recipe).
    public static func desktopPackages(_ family: DistroFamily) -> String? {
        switch family {
        case .debian:
            return [aptPrelude, "apt_get update", debianDesktopInstall].joined(separator: "\n") + "\n"
        case .ubuntu:
            return [aptPrelude, mozillaRepository, "apt_get update", ubuntuDesktopInstall].joined(separator: "\n") + "\n"
        case .fedora:
            return #"""
                set -e
                dnf -y install --setopt=install_weak_deps=False \
                  xorg-x11-server-Xorg xorg-x11-xinit xorg-x11-drv-libinput mesa-dri-drivers \
                  lightdm lightdm-gtk \
                  xfce4-session xfwm4 xfce4-panel xfdesktop xfce4-settings xfce4-terminal Thunar \
                  dbus-x11 adwaita-icon-theme \
                  xdotool scrot xclip \
                  firefox dejavu-sans-fonts google-noto-sans-fonts \
                  spice-vdagent

                """#
        case .enterprise9:
            return #"""
                set -e
                dnf -y install epel-release
                crb enable || dnf config-manager --set-enabled crb
                dnf -y install --setopt=install_weak_deps=False \
                  xorg-x11-server-Xorg xorg-x11-xinit xorg-x11-drv-libinput \
                  lightdm lightdm-gtk xfce4-session xfwm4 xfce4-panel xfdesktop xfce4-settings xfce4-terminal Thunar \
                  dbus-x11 xdotool maim xclip firefox dejavu-sans-fonts spice-vdagent

                """#
        case .opensuse:
            return #"""
                set -e
                zypper --non-interactive install --no-recommends kernel-default \
                  xorg-x11-server xf86-input-libinput xrandr xset lightdm lightdm-gtk-greeter \
                  xfce4-session xfwm4 xfce4-panel xfdesktop xfce4-settings xfce4-terminal thunar \
                  xdotool scrot xclip MozillaFirefox dejavu-fonts adwaita-icon-theme spice-vdagent

                """#
        case .arch:
            return #"""
                set -e
                pacman -Syu --noconfirm --needed xorg-server xf86-input-libinput xorg-xrandr xorg-xset \
                  lightdm lightdm-gtk-greeter xfce4 xfce4-terminal xdotool scrot xclip firefox ttf-dejavu spice-vdagent

                """#
        case .alpine:
            return #"""
                set -e
                setup-xorg-base
                apk add xfce4 xfce4-terminal lightdm lightdm-gtk-greeter dbus dbus-x11 elogind polkit-elogind \
                  xdotool scrot xclip firefox font-dejavu adwaita-icon-theme spice-vdagent

                """#
        case .enterprise10, .other:
            return nil
        }
    }

    /// LightDM auto-login for `user`, no blanking/DPMS/locker, `width`×`height` when Xorg offers it, and no XFCE
    /// first-run panel dialog; then switches to the graphical target (A.4.1, block 2).
    public static func desktopConfig(_ family: DistroFamily, user rawUser: String, width: Int = 1280, height: Int = 800) -> String? {
        guard desktopPackages(family) != nil else { return nil }
        let user = CloudInitConfig.sanitizedUserName(rawUser)
        let mode = "\(max(320, width))x\(max(200, height))"
        let autologinGroup = family == .alpine
            ? "addgroup -S autologin 2>/dev/null || true\naddgroup \(user) autologin"
            : "getent group autologin >/dev/null || groupadd -r autologin\nusermod -aG autologin \(user)"
        let services = family == .alpine
            ? """
              rc-update add dbus default && rc-update add elogind default && rc-update add lightdm default
              rc-service dbus start && rc-service elogind start && rc-service lightdm start
              """
            : """
              systemctl set-default graphical.target
              systemctl enable lightdm.service 2>/dev/null || true
              systemctl restart display-manager.service 2>/dev/null || systemctl restart lightdm.service
              """
        return #"""
            set -e
            install -d /etc/lightdm/lightdm.conf.d
            cat > /etc/lightdm/lightdm.conf.d/50-zcomputer.conf <<'EOF'
            [Seat:*]
            autologin-user=\#(user)
            autologin-user-timeout=0
            autologin-session=xfce
            user-session=xfce
            greeter-session=lightdm-gtk-greeter
            xserver-command=X -s 0 -dpms
            display-setup-script=/usr/local/sbin/zc-display-setup
            EOF
            cat > /usr/local/sbin/zc-display-setup <<'EOF'
            #!/bin/sh
            # Runs as root on LightDM's X server before the session. Prefer \#(mode), keep VZ's mode otherwise.
            out=$(xrandr --query 2>/dev/null | awk '/ connected/ {print $1; exit}')
            [ -n "$out" ] && xrandr --output "$out" --mode \#(mode) 2>/dev/null
            xset s off s noblank -dpms 2>/dev/null
            exit 0
            EOF
            chmod 0755 /usr/local/sbin/zc-display-setup
            \#(autologinGroup)
            x=/home/\#(user)/.config/xfce4/xfconf/xfce-perchannel-xml
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
            chown -R "\#(user):$(id -gn \#(user))" /home/\#(user)/.config
            \#(services)

            """#
    }

    /// Developer tools from the distribution's repositories (nil when there is no recipe). apt lists are names that
    /// exist in Debian 13 main and Ubuntu 24.04 main/universe; the other families are UNVERIFIED.
    public static func devTools(_ family: DistroFamily) -> String? {
        switch family {
        case .debian, .ubuntu:
            return aptPrelude + "\n" + #"""
                apt_get update
                apt_get install --no-install-recommends \
                  git curl ca-certificates build-essential \
                  python3 python3-pip python3-venv nodejs npm \
                  tmux ripgrep

                """#
        case .fedora:
            return #"""
                set -e
                dnf -y install --setopt=install_weak_deps=False \
                  git gcc gcc-c++ make python3 python3-pip nodejs npm tmux ripgrep

                """#
        case .enterprise9, .enterprise10:
            return #"""
                set -e
                dnf -y install epel-release
                dnf -y install --setopt=install_weak_deps=False \
                  git gcc gcc-c++ make python3 python3-pip nodejs npm tmux ripgrep

                """#
        case .opensuse:
            return #"""
                set -e
                zypper --non-interactive install --no-recommends \
                  git curl gcc gcc-c++ make python3 python3-pip nodejs-default npm-default tmux ripgrep

                """#
        case .arch:
            return #"""
                set -e
                pacman -Syu --noconfirm --needed git curl base-devel python python-pip nodejs npm tmux ripgrep

                """#
        case .alpine:
            return #"""
                set -e
                apk add git curl build-base python3 py3-pip nodejs npm tmux ripgrep bash

                """#
        case .other:
            return nil
        }
    }

    /// Alpine: a getty on hvc0 and an OpenRC service for `zguest` (its installer is systemd-only, A.4.6).
    public static let alpineAgent = #"""
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

        """#

    /// `zc-provision STEP TOTAL STAGE LABEL [SCRIPT]`: runs SCRIPT (logging to `ProvisionStatus.logPath`) and records
    /// running / ok / failed in `ProvisionStatus.path`; stage `done` without a script marks the machine ready. After
    /// a failure every later step is skipped, so the file keeps the first error.
    public static let runner = #"""
        #!/bin/sh
        # Z Computer first-boot provisioning step runner (written by the app's cloud-init seed).
        dir=/var/lib/zguest
        file=$dir/provision.status
        log=\#(ProvisionStatus.logPath)
        step=$1
        total=$2
        stage=$3
        label=$4
        script=$5
        write_status() {
          mkdir -p "$dir"
          tmp="$file.tmp.$$"
          {
            echo "version=1"
            echo "step=$step"
            echo "total=$total"
            echo "stage=$stage"
            echo "state=$1"
            echo "label=$label"
            echo "updated=$(date +%s)"
            if [ -n "$2" ]; then echo "detail=$2"; fi
          } > "$tmp" && mv -f "$tmp" "$file"
        }
        if grep -qs '^state=failed' "$file"; then
          echo "skipping $stage: an earlier step failed" >> "$log"
          exit 1
        fi
        if [ -z "$script" ]; then
          if [ "$stage" = done ]; then write_status done; else write_status ok; fi
          exit 0
        fi
        write_status running
        echo "=== $(date) step $step/$total $stage: $label" >> "$log"
        if sh "$script" >> "$log" 2>&1; then
          write_status ok
          exit 0
        fi
        write_status failed "$(tail -n 5 "$log" | tr '\n' ' ' | cut -c 1-400)"
        exit 1

        """#
}

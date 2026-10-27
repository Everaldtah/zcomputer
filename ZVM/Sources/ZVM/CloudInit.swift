import Foundation
import ZCore

/// cloud-init configuration for a fresh cloud image: a user (default `z`) with password + sudo, SSH with password
/// login, and the `zguest` agent installed from the `zguest` virtio-fs share as a systemd service, so the VM
/// boots straight into usable Linux that the app can drive.
public struct CloudInitConfig: Sendable, Hashable {
    public var instanceID: String
    public var hostname: String
    public var user: String
    public var password: String
    public var fullName: String
    public var sshAuthorizedKeys: [String]
    /// Extra apt packages (installing them needs network on first boot and takes a while).
    public var packages: [String]
    /// File name of the agent binary in the `zguest` share; nil = do not install the agent.
    public var agentBinaryName: String?
    public var timezone: String?
    /// Extra shell commands run once at the end of first boot (as root).
    public var runCommands: [String]

    public init(instanceID: String = UUID().uuidString.lowercased(),
                hostname: String = "zcomputer",
                user: String = "z",
                password: String,
                fullName: String = "Z Computer",
                sshAuthorizedKeys: [String] = [],
                packages: [String] = [],
                agentBinaryName: String? = "zguest",
                timezone: String? = nil,
                runCommands: [String] = []) {
        self.instanceID = instanceID; self.hostname = hostname; self.user = user; self.password = password
        self.fullName = fullName; self.sshAuthorizedKeys = sshAuthorizedKeys; self.packages = packages
        self.agentBinaryName = agentBinaryName; self.timezone = timezone; self.runCommands = runCommands
    }

    /// Packages for a light X11 desktop the agent can screenshot and drive (Xfce + LightDM, xdotool, scrot,
    /// spice-vdagent for the shared clipboard). Debian/Ubuntu names. Auto-login is not configured.
    public static let desktopPackages = ["xfce4", "lightdm", "xdotool", "scrot", "spice-vdagent", "dbus-x11"]

    /// `user-data` (#cloud-config YAML). Strings are emitted as JSON-style double-quoted YAML scalars.
    public func userData() -> String {
        var y = "#cloud-config\n"
        y += "hostname: \(yaml(hostname))\n"
        y += "manage_etc_hosts: true\n"
        y += "ssh_pwauth: true\n"
        if let timezone { y += "timezone: \(yaml(timezone))\n" }
        y += "users:\n"
        y += "  - name: \(yaml(user))\n"
        y += "    gecos: \(yaml(fullName))\n"
        y += "    shell: /bin/bash\n"
        y += "    groups: [sudo, adm]\n"
        y += "    sudo: \"ALL=(ALL) NOPASSWD:ALL\"\n"
        y += "    lock_passwd: false\n"
        y += "    plain_text_passwd: \(yaml(password))\n"
        if !sshAuthorizedKeys.isEmpty {
            y += "    ssh_authorized_keys:\n"
            for k in sshAuthorizedKeys { y += "      - \(yaml(k))\n" }
        }
        y += "chpasswd:\n  expire: false\n"
        if !packages.isEmpty {
            y += "package_update: true\n"
            y += "packages:\n"
            for p in packages { y += "  - \(yaml(p))\n" }
        }
        var commands: [String] = ["systemctl enable --now ssh 2>/dev/null || systemctl enable --now sshd 2>/dev/null || true"]
        if agentBinaryName != nil {
            y += "write_files:\n"
            y += "  - path: /usr/local/sbin/zguest-install\n"
            y += "    permissions: \"0755\"\n"
            y += "    content: \(yaml(agentInstallScript))\n"
            commands.append("/usr/local/sbin/zguest-install")
        }
        commands += runCommands
        y += "runcmd:\n"
        for c in commands { y += "  - [sh, -c, \(yaml(c))]\n" }
        y += "final_message: \(yaml("Z Computer guest ready after $UPTIME seconds"))\n"
        return y
    }

    /// `meta-data`.
    public func metaData() -> String {
        "instance-id: \(yaml(instanceID))\nlocal-hostname: \(yaml(hostname))\n"
    }

    /// The agent installer written to `/usr/local/sbin/zguest-install` (same steps as `AutoProvisioner`).
    public var agentInstallScript: String {
        "#!/bin/sh\n" + GuestAgentInstall.script(binaryName: agentBinaryName ?? "zguest")
    }

    /// A YAML double-quoted scalar (JSON string syntax is valid YAML).
    func yaml(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    let hex = String(scalar.value, radix: 16)
                    out += "\\u" + String(repeating: "0", count: max(0, 4 - hex.count)) + hex
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}

/// Builds the NoCloud seed image: an ISO 9660 + Joliet volume labelled `cidata` holding `user-data` and
/// `meta-data`. Attach it read-only (VMController does when `seed.iso` exists in the bundle).
public enum CloudInitSeed {
    public static let volumeLabel = "cidata"

    public static func makeImage(_ config: CloudInitConfig, date: Date = Date()) -> Data {
        var iso = ISO9660Builder(volumeIdentifier: volumeLabel, date: date)
        iso.addFile(path: "user-data", contents: Data(config.userData().utf8))
        iso.addFile(path: "meta-data", contents: Data(config.metaData().utf8))
        return iso.build()
    }

    public static func write(_ config: CloudInitConfig, to url: URL) throws {
        try makeImage(config).write(to: url, options: .atomic)
    }
}

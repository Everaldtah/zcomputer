import Foundation
import ZCore

/// cloud-init configuration for a fresh cloud image: a user (default `z`) with password + sudo, SSH with password
/// login, and the `zguest` agent installed from the `zguest` virtio-fs share as a systemd service, so the VM
/// boots straight into usable Linux that the app can drive.
///
/// Presets (`desktop`, `dev`) are installed from `runcmd` **after** the agent install, so the agent answers within
/// a minute of boot and the app can follow the install through `/var/lib/zguest/provision.status`
/// (`ProvisionStatus`). `packages:` would run before `runcmd` and pull in Recommends (research finding 4).
public struct CloudInitConfig: Sendable, Hashable {
    public var instanceID: String
    public var hostname: String
    public var user: String
    public var password: String
    public var fullName: String
    public var sshAuthorizedKeys: [String]
    /// Extra packages through cloud-init's `packages:` (runs before `runcmd`; prefer the presets).
    public var packages: [String]
    /// File name of the agent binary in the `zguest` share; nil = do not install the agent.
    public var agentBinaryName: String?
    public var timezone: String?
    /// Extra shell commands run once at the end of first boot (as root), after the preset steps.
    public var runCommands: [String]
    /// The guest's distribution family (package manager, init system) for the presets.
    public var family: DistroFamily
    public var desktop: DesktopPreset
    public var dev: DevPreset
    /// Write the progress file even without presets (the app's library flows always do).
    public var progressMarker: Bool
    /// The display mode the desktop preset asks Xorg for (match `VMSpec.display`).
    public var displayWidth: Int
    public var displayHeight: Int
    /// The distribution release (`CatalogImage.version`; Alpine's repository branch is derived from it).
    public var releaseVersion: String?

    public init(instanceID: String = UUID().uuidString.lowercased(),
                hostname: String = "zcomputer",
                user: String = "z",
                password: String,
                fullName: String = "Z Computer",
                sshAuthorizedKeys: [String] = [],
                packages: [String] = [],
                agentBinaryName: String? = "zguest",
                timezone: String? = nil,
                runCommands: [String] = [],
                family: DistroFamily = .debian,
                desktop: DesktopPreset = .none,
                dev: DevPreset = .none,
                progressMarker: Bool = false,
                displayWidth: Int = 1280,
                displayHeight: Int = 800,
                releaseVersion: String? = nil) {
        self.instanceID = instanceID; self.hostname = hostname; self.user = user; self.password = password
        self.fullName = fullName; self.sshAuthorizedKeys = sshAuthorizedKeys; self.packages = packages
        self.agentBinaryName = agentBinaryName; self.timezone = timezone; self.runCommands = runCommands
        self.family = family; self.desktop = desktop; self.dev = dev; self.progressMarker = progressMarker
        self.displayWidth = displayWidth; self.displayHeight = displayHeight; self.releaseVersion = releaseVersion
    }

    /// The seed for a catalogue cloud image with presets and the progress file. Throws when a preset has no recipe
    /// for the image's distribution (e.g. a desktop on Rocky/Alma 10) or the user name is not a valid login.
    public static func forImage(_ image: CatalogImage, hostname: String, user: String, password: String,
                                desktop: DesktopPreset, dev: DevPreset = .none,
                                agentBinaryName: String? = "zguest-linux-\(GuestArchitecture.host.debianName)",
                                display: DisplaySpec = DisplaySpec()) throws -> CloudInitConfig {
        guard image.isCloudImage else { throw ZError.invalidArgument("\(image.name) is an installer ISO, not a cloud image") }
        guard isValidUserName(user) else {
            throw ZError.invalidArgument("“\(user)” is not a valid Linux user name (lowercase letters, digits, - and _)")
        }
        let family = image.family
        guard desktop.isSupported(on: family) else {
            throw ZError.unsupported("\(image.name) has no \(desktop.displayName) recipe (EL10 ships no Xorg server): use it as a terminal machine")
        }
        guard dev.isSupported(on: family) else {
            throw ZError.unsupported("\(image.name) has no developer-tools recipe")
        }
        return CloudInitConfig(hostname: hostname, user: user, password: password, agentBinaryName: agentBinaryName,
                               family: family, desktop: desktop, dev: dev, progressMarker: true,
                               displayWidth: display.width, displayHeight: display.height, releaseVersion: image.version)
    }

    /// `[a-z_][a-z0-9_-]{0,31}`: safe in useradd, LightDM's config and shell paths.
    public static func isValidUserName(_ name: String) -> Bool {
        guard let first = name.first, name.count <= 32, first == "_" || ("a"..."z").contains(first) else { return false }
        return name.allSatisfy { $0 == "_" || $0 == "-" || ("a"..."z").contains($0) || ("0"..."9").contains($0) }
    }

    /// `name` when valid, else `z` (the preset scripts interpolate the user name).
    public static func sanitizedUserName(_ name: String) -> String {
        isValidUserName(name) ? name : "z"
    }

    // MARK: Provisioning steps

    /// The first-boot steps in run order: agent, desktop packages, desktop configuration, developer tools.
    /// Empty when there is nothing to report (no presets and no `progressMarker`).
    public var provisionSteps: [ProvisionStep] {
        guard progressMarker || desktop != .none || dev != .none else { return [] }
        let dir = ProvisionScripts.directory
        var steps: [ProvisionStep] = []
        if agentBinaryName != nil {
            if family == .alpine {
                steps.append(ProvisionStep(stage: "agent", label: "Starting the guest agent (OpenRC)",
                                           scriptPath: dir + "/10-agent-openrc.sh", script: ProvisionScripts.alpineAgent))
            } else {
                steps.append(ProvisionStep(stage: "agent", label: "Guest agent installed"))
            }
        }
        if desktop == .xfceX11, let packages = ProvisionScripts.desktopPackages(family),
           let config = ProvisionScripts.desktopConfig(family, user: user, width: displayWidth, height: displayHeight) {
            steps.append(ProvisionStep(stage: "desktop-packages", label: "Installing the Xfce desktop (X11)",
                                       scriptPath: dir + "/20-desktop-packages.sh", script: packages))
            steps.append(ProvisionStep(stage: "desktop-config", label: "Setting up auto-login and the display",
                                       scriptPath: dir + "/30-desktop-config.sh", script: config))
        }
        if dev == .standard, let tools = ProvisionScripts.devTools(family) {
            steps.append(ProvisionStep(stage: "dev-tools", label: "Installing developer tools",
                                       scriptPath: dir + "/40-dev-tools.sh", script: tools))
        }
        return steps
    }

    /// The `runcmd` entries in order: SSH, the agent install, the provisioning steps, `runCommands`, the done marker.
    public var runcmdCommands: [String] {
        var commands: [String] = ["systemctl enable --now ssh 2>/dev/null || systemctl enable --now sshd 2>/dev/null || true"]
        if agentBinaryName != nil { commands.append("/usr/local/sbin/zguest-install") }
        let steps = provisionSteps
        for (index, step) in steps.enumerated() {
            commands.append(Self.runnerCommand(step: index + 1, total: steps.count, stage: step.stage, label: step.label,
                                               script: step.scriptPath))
        }
        commands += runCommands
        if !steps.isEmpty {
            commands.append(Self.runnerCommand(step: steps.count, total: steps.count, stage: "done", label: "Ready", script: nil))
        }
        return commands
    }

    static func runnerCommand(step: Int, total: Int, stage: String, label: String, script: String?) -> String {
        var parts = [ProvisionScripts.runnerPath, String(step), String(total), shellQuote(stage), shellQuote(label)]
        if let script { parts.append(shellQuote(script)) }
        return parts.joined(separator: " ")
    }

    // MARK: Rendering

    /// `user-data` (#cloud-config YAML). Strings are emitted as JSON-style double-quoted YAML scalars.
    public func userData() -> String {
        let alpine = family == .alpine
        var y = "#cloud-config\n"
        y += "hostname: \(yaml(hostname))\n"
        y += "manage_etc_hosts: true\n"
        y += "ssh_pwauth: true\n"
        if let timezone { y += "timezone: \(yaml(timezone))\n" }
        if alpine {
            // XFCE lives in `community` (research A.4.6).
            y += "apk_repos:\n  preserve_repositories: false\n  alpine_repo:\n    version: \(yaml(alpineBranch))\n"
            y += "    community_enabled: true\n"
        }
        y += "users:\n"
        y += "  - name: \(yaml(user))\n"
        y += "    gecos: \(yaml(fullName))\n"
        y += alpine ? "    shell: /bin/sh\n" : "    shell: /bin/bash\n"
        y += alpine ? "    groups: [wheel]\n" : "    groups: [sudo, adm]\n"
        y += "    sudo: \"ALL=(ALL) NOPASSWD:ALL\"\n"
        y += "    lock_passwd: false\n"
        y += "    plain_text_passwd: \(yaml(password))\n"
        if !sshAuthorizedKeys.isEmpty {
            y += "    ssh_authorized_keys:\n"
            for k in sshAuthorizedKeys { y += "      - \(yaml(k))\n" }
        }
        y += "chpasswd:\n  expire: false\n"
        var allPackages = packages
        if alpine {
            for p in ["bash", "sudo"] where !allPackages.contains(p) { allPackages.append(p) }
        }
        if !allPackages.isEmpty {
            y += "package_update: true\n"
            y += "packages:\n"
            for p in allPackages { y += "  - \(yaml(p))\n" }
        }

        var files: [(path: String, content: String)] = []
        if agentBinaryName != nil { files.append(("/usr/local/sbin/zguest-install", agentInstallScript)) }
        let steps = provisionSteps
        if !steps.isEmpty {
            files.append((ProvisionScripts.runnerPath, ProvisionScripts.runner))
            for step in steps {
                if let path = step.scriptPath, let script = step.script { files.append((path, script)) }
            }
        }
        if !files.isEmpty {
            y += "write_files:\n"
            for file in files {
                y += "  - path: \(file.path)\n"
                y += "    permissions: \"0755\"\n"
                y += "    content: \(yaml(file.content))\n"
            }
        }

        y += "runcmd:\n"
        for c in runcmdCommands { y += "  - [sh, -c, \(yaml(c))]\n" }
        if desktop == .xfceX11 && family == .opensuse {
            // The Minimal-VM kernel-default-base may lack virtio-gpu/USB HID: reboot into kernel-default (A.4.5).
            y += "power_state:\n  mode: reboot\n  message: \"Z Computer: rebooting into kernel-default for the desktop\"\n  condition: true\n"
        }
        y += "final_message: \(yaml("Z Computer guest ready after $UPTIME seconds"))\n"
        return y
    }

    /// Alpine's repository branch (`v3.24` for release 3.24.3).
    var alpineBranch: String {
        let parts = (releaseVersion ?? "3.24").split(separator: ".").prefix(2)
        return parts.count == 2 ? "v" + parts.joined(separator: ".") : "v3.24"
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

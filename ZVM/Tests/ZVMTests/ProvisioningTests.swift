import Foundation
import XCTest
import ZCore
@testable import ZVM

final class ProvisioningPresetTests: XCTestCase {
    private func image(_ id: String) throws -> CatalogImage {
        try XCTUnwrap(ImageCatalog.image(id: id), id)
    }

    func testDebianDesktopPackagesAreTheVerifiedList() throws {
        let script = try XCTUnwrap(ProvisionScripts.desktopPackages(.debian))
        let exact = """
            apt_get install --no-install-recommends \\
              xserver-xorg-core xserver-xorg-input-libinput x11-xserver-utils \\
              lightdm lightdm-gtk-greeter \\
              xfce4 xfce4-terminal dbus-x11 dbus-user-session at-spi2-core adwaita-icon-theme \\
              xdotool scrot xclip \\
              firefox-esr fonts-dejavu-core fonts-liberation2 \\
              spice-vdagent
            """
        XCTAssertTrue(script.contains(exact), script)
        XCTAssertTrue(script.hasPrefix("set -e\n"))
        XCTAssertTrue(script.contains("echo 'man-db man-db/auto-update boolean false' | debconf-set-selections\n"))
        XCTAssertTrue(script.contains("-o DPkg::Lock::Timeout=600"))
        XCTAssertTrue(script.contains("\napt_get update\n"))
    }

    func testUbuntuDesktopUsesMozillasRepository() throws {
        let script = try XCTUnwrap(ProvisionScripts.desktopPackages(.ubuntu))
        let exact = """
            apt_get install --no-install-recommends \\
              xserver-xorg-core xserver-xorg-input-libinput x11-xserver-utils \\
              lightdm lightdm-gtk-greeter \\
              xfce4 xfce4-terminal dbus-x11 dbus-user-session at-spi2-core adwaita-icon-theme \\
              xdotool scrot xclip \\
              firefox fonts-dejavu-core fonts-liberation2 \\
              spice-vdagent
            """
        XCTAssertTrue(script.contains(exact), script)
        XCTAssertFalse(script.contains("firefox-esr"))
        XCTAssertTrue(script.contains("echo '3ecc63922b7795eb23fdc449ff9396f9114cb3cf186d6f5b53ad4cc3ebfbb11f  "
                                      + "/etc/apt/keyrings/packages.mozilla.org.asc' | sha256sum -c -"))
        XCTAssertTrue(script.contains("printf 'Package: *\\nPin: origin packages.mozilla.org\\nPin-Priority: 1000\\n'"))
        let repo = try XCTUnwrap(script.range(of: "https://packages.mozilla.org/apt mozilla main"))
        let install = try XCTUnwrap(script.range(of: "apt_get install --no-install-recommends \\\n  xserver-xorg-core"))
        XCTAssertLessThan(repo.lowerBound, install.lowerBound)
    }

    func testAutologinBlock() throws {
        let block = try XCTUnwrap(ProvisionScripts.desktopConfig(.debian, user: "z"))
        for line in ["[Seat:*]\n", "autologin-user=z\n", "autologin-user-timeout=0\n", "autologin-session=xfce\n",
                     "user-session=xfce\n", "greeter-session=lightdm-gtk-greeter\n", "xserver-command=X -s 0 -dpms\n",
                     "display-setup-script=/usr/local/sbin/zc-display-setup\n", "--mode 1280x800",
                     "xset s off s noblank -dpms", "usermod -aG autologin z\n",
                     "cp /etc/xdg/xfce4/panel/default.xml \"$x/xfce4-panel.xml\"",
                     "<property name=\"dpms-enabled\" type=\"bool\" value=\"false\"/>",
                     "<property name=\"lock\" type=\"empty\"><property name=\"enabled\" type=\"bool\" value=\"false\"/></property>",
                     "x=/home/z/.config/xfce4/xfconf/xfce-perchannel-xml\n", "systemctl set-default graphical.target\n",
                     "systemctl restart display-manager.service 2>/dev/null || systemctl restart lightdm.service"] {
            XCTAssertTrue(block.contains(line), line)
        }
        let wide = try XCTUnwrap(ProvisionScripts.desktopConfig(.ubuntu, user: "agent", width: 1440, height: 900))
        XCTAssertTrue(wide.contains("autologin-user=agent\n"))
        XCTAssertTrue(wide.contains("--mode 1440x900"))
        // Invalid names never reach the scripts.
        let hostile = try XCTUnwrap(ProvisionScripts.desktopConfig(.debian, user: "z\nautologin-user=root"))
        XCTAssertFalse(hostile.contains("autologin-user=root"))
        XCTAssertTrue(hostile.contains("autologin-user=z\n"))
        XCTAssertNil(ProvisionScripts.desktopConfig(.enterprise10, user: "z"))
    }

    func testDebianDesktopSeedRunsTheDesktopAfterTheAgent() throws {
        let config = try CloudInitConfig.forImage(image("debian-13-generic-arm64"), hostname: "agent", user: "z",
                                                  password: "pw", desktop: .xfceX11, agentBinaryName: "zguest-linux-arm64")
        let commands = config.runcmdCommands
        let agent = try XCTUnwrap(commands.firstIndex(of: "/usr/local/sbin/zguest-install"))
        let packages = try XCTUnwrap(commands.firstIndex { $0.contains("20-desktop-packages.sh") })
        let autologin = try XCTUnwrap(commands.firstIndex { $0.contains("30-desktop-config.sh") })
        XCTAssertLessThan(agent, packages)
        XCTAssertLessThan(packages, autologin)
        XCTAssertEqual(commands[packages], "/usr/local/sbin/zc-provision 2 3 'desktop-packages' "
                       + "'Installing the Xfce desktop (X11)' '/usr/local/lib/zcomputer/provision/20-desktop-packages.sh'")
        XCTAssertEqual(commands.last, "/usr/local/sbin/zc-provision 3 3 'done' 'Ready'")
        XCTAssertEqual(commands[agent + 1], "/usr/local/sbin/zc-provision 1 3 'agent' 'Guest agent installed'")

        let yaml = config.userData()
        let runcmd = try XCTUnwrap(yaml.range(of: "runcmd:\n"))
        let agentLine = try XCTUnwrap(yaml.range(of: "  - [sh, -c, \"/usr/local/sbin/zguest-install\"]\n"))
        let desktopLine = try XCTUnwrap(yaml.range(of: "  - [sh, -c, \"/usr/local/sbin/zc-provision 2 3 'desktop-packages'"))
        XCTAssertLessThan(runcmd.lowerBound, agentLine.lowerBound)
        XCTAssertLessThan(agentLine.lowerBound, desktopLine.lowerBound)
        // The desktop is not installed through `packages:` (that runs before runcmd and pulls in Recommends).
        XCTAssertFalse(yaml.contains("\npackages:\n"))
        XCTAssertFalse(yaml.contains("package_update"))
        // The scripts and the runner are in write_files, YAML-escaped.
        let packagesScript = try XCTUnwrap(ProvisionScripts.desktopPackages(.debian))
        XCTAssertTrue(yaml.contains("    content: \(config.yaml(packagesScript))\n"))
        XCTAssertTrue(yaml.contains("  - path: /usr/local/sbin/zc-provision\n"))
        XCTAssertTrue(yaml.contains("  - path: /usr/local/lib/zcomputer/provision/30-desktop-config.sh\n"))
        XCTAssertTrue(yaml.contains(config.yaml(ProvisionScripts.runner)))
        XCTAssertTrue(ProvisionScripts.runner.contains("file=$dir/provision.status"))
        XCTAssertTrue(ProvisionScripts.runner.contains("dir=/var/lib/zguest\n"))
        XCTAssertFalse(yaml.contains("\t"))
        XCTAssertFalse(yaml.contains("power_state"))
    }

    func testUbuntuDesktopSeed() throws {
        let config = try CloudInitConfig.forImage(image("ubuntu-24.04-server-x86_64"), hostname: "u", user: "z",
                                                  password: "pw", desktop: .xfceX11)
        XCTAssertEqual(config.family, .ubuntu)
        XCTAssertEqual(config.provisionSteps.map(\.stage), ["agent", "desktop-packages", "desktop-config"])
        XCTAssertTrue(config.userData().contains(ProvisionScripts.mozillaKeySHA256))
    }

    func testTerminalAndSmallSeeds() throws {
        let dev = try CloudInitConfig.forImage(image("ubuntu-24.04-server-arm64"), hostname: "d", user: "z", password: "pw",
                                               desktop: .none, dev: .standard)
        XCTAssertEqual(dev.provisionSteps.map(\.stage), ["agent", "dev-tools"])
        let tools = try XCTUnwrap(ProvisionScripts.devTools(.ubuntu))
        XCTAssertTrue(tools.contains("git curl ca-certificates build-essential"))
        XCTAssertTrue(tools.contains("python3 python3-pip python3-venv nodejs npm"))
        XCTAssertTrue(tools.contains("tmux ripgrep"))
        XCTAssertTrue(tools.contains("--no-install-recommends"))

        let small = try CloudInitConfig.forImage(image("ubuntu-24.04-minimal-arm64"), hostname: "s", user: "z",
                                                 password: "pw", desktop: .none)
        XCTAssertEqual(small.runcmdCommands.suffix(2), ["/usr/local/sbin/zc-provision 1 1 'agent' 'Guest agent installed'",
                                                        "/usr/local/sbin/zc-provision 1 1 'done' 'Ready'"])
        // Without presets or the progress marker nothing extra is written (older callers).
        XCTAssertTrue(CloudInitConfig(password: "pw").provisionSteps.isEmpty)
    }

    func testDistroAwareRecipes() throws {
        XCTAssertThrowsError(try CloudInitConfig.forImage(image("rocky-10-genericcloud-arm64"), hostname: "r", user: "z",
                                                          password: "pw", desktop: .xfceX11))
        XCTAssertNoThrow(try CloudInitConfig.forImage(image("rocky-10-genericcloud-arm64"), hostname: "r", user: "z",
                                                      password: "pw", desktop: .none, dev: .standard))
        XCTAssertTrue(ProvisionScripts.desktopPackages(.fedora)?.contains("dnf -y install --setopt=install_weak_deps=False") == true)
        XCTAssertTrue(ProvisionScripts.desktopPackages(.enterprise9)?.contains("maim") == true)
        XCTAssertTrue(ProvisionScripts.desktopPackages(.opensuse)?.contains("zypper --non-interactive install --no-recommends kernel-default") == true)
        XCTAssertTrue(ProvisionScripts.desktopPackages(.arch)?.contains("pacman -Syu --noconfirm --needed") == true)
        XCTAssertTrue(ProvisionScripts.desktopPackages(.alpine)?.contains("setup-xorg-base") == true)
        XCTAssertTrue(ProvisionScripts.devTools(.fedora)?.contains("dnf -y install") == true)
        XCTAssertTrue(ProvisionScripts.devTools(.alpine)?.contains("apk add") == true)
        XCTAssertTrue(ProvisionScripts.devTools(.opensuse)?.contains("zypper") == true)
        XCTAssertTrue(ProvisionScripts.devTools(.arch)?.contains("pacman") == true)

        let suse = try CloudInitConfig.forImage(image("opensuse-leap-16.0-cloud-arm64"), hostname: "o", user: "z",
                                                password: "pw", desktop: .xfceX11)
        XCTAssertTrue(suse.userData().contains("power_state:\n  mode: reboot\n"))
    }

    func testAlpineSeed() throws {
        let config = try CloudInitConfig.forImage(image("alpine-3.22.7-uefi-cloudinit-arm64"), hostname: "a", user: "z",
                                                  password: "pw", desktop: .xfceX11)
        let yaml = config.userData()
        XCTAssertTrue(yaml.contains("    shell: /bin/sh\n"))
        XCTAssertTrue(yaml.contains("    groups: [wheel]\n"))
        XCTAssertTrue(yaml.contains("    version: \"v3.22\"\n    community_enabled: true\n"))
        XCTAssertTrue(yaml.contains("packages:\n  - \"bash\"\n  - \"sudo\"\n"))
        XCTAssertEqual(config.provisionSteps.first?.scriptPath, "/usr/local/lib/zcomputer/provision/10-agent-openrc.sh")
        XCTAssertTrue(ProvisionScripts.alpineAgent.contains("rc-update add zguest default"))
        let desktop = try XCTUnwrap(ProvisionScripts.desktopConfig(.alpine, user: "z"))
        XCTAssertTrue(desktop.contains("rc-service lightdm start"))
        XCTAssertFalse(desktop.contains("systemctl"))
    }

    func testUserNames() throws {
        XCTAssertTrue(CloudInitConfig.isValidUserName("z"))
        XCTAssertTrue(CloudInitConfig.isValidUserName("dev_user-2"))
        XCTAssertFalse(CloudInitConfig.isValidUserName("Z"))
        XCTAssertFalse(CloudInitConfig.isValidUserName("a b"))
        XCTAssertFalse(CloudInitConfig.isValidUserName("x;rm"))
        XCTAssertFalse(CloudInitConfig.isValidUserName(""))
        XCTAssertFalse(CloudInitConfig.isValidUserName("2fast"))
        XCTAssertThrowsError(try CloudInitConfig.forImage(image("debian-13-generic-arm64"), hostname: "h", user: "Bad User",
                                                          password: "pw", desktop: .none))
        XCTAssertThrowsError(try CloudInitConfig.forImage(image("kali-2026.3-installer-arm64-iso"), hostname: "h", user: "z",
                                                          password: "pw", desktop: .none))
    }

    func testProvisionStatusParsing() throws {
        let text = "version=1\nstep=2\ntotal=3\nstage=desktop-packages\nstate=running\n"
            + "label=Installing the Xfce desktop (X11)\nupdated=1800000000\n"
        let status = try XCTUnwrap(ProvisionStatus.parse(text))
        XCTAssertEqual(status.step, 2)
        XCTAssertEqual(status.total, 3)
        XCTAssertEqual(status.stage, "desktop-packages")
        XCTAssertEqual(status.state, .running)
        XCTAssertEqual(status.label, "Installing the Xfce desktop (X11)")
        XCTAssertEqual(status.updated, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertNil(status.detail)
        XCTAssertFalse(status.isDone)

        let failed = try XCTUnwrap(ProvisionStatus.parse("stage=desktop-config\nstate=failed\ndetail=E: x=y failed\n"))
        XCTAssertTrue(failed.isFailed)
        XCTAssertEqual(failed.detail, "E: x=y failed")
        XCTAssertEqual(failed.label, "desktop-config")
        XCTAssertTrue(try XCTUnwrap(ProvisionStatus.parse("step=3\ntotal=3\nstage=done\nstate=done\n")).isDone)
        XCTAssertNil(ProvisionStatus.parse("garbage"))
        XCTAssertNil(ProvisionStatus.parse("stage=x\nstate=weird\n"))
        XCTAssertEqual(ProvisionStatus.path, "/var/lib/zguest/provision.status")
    }
}

final class MachineTemplateTests: XCTestCase {
    private func host(_ arch: GuestArchitecture, memoryGB: UInt64 = 16, cpus: Int = 8,
                      os: HostProfile.Version = HostProfile.Version(15, 6), diskGB: Int64? = 500) -> HostProfile {
        HostProfile(architecture: arch, physicalMemoryBytes: memoryGB << 30, cpuCount: cpus, osVersion: os,
                    availableDiskBytes: diskGB.map { $0 << 30 })
    }

    private func template(_ id: String) throws -> MachineTemplate {
        try XCTUnwrap(MachineTemplate.template(id: id), id)
    }

    func testTheTemplateList() throws {
        XCTAssertEqual(MachineTemplate.all.map(\.name), [
            "Agent Desktop (Debian 13 + XFCE)", "Agent Desktop (Ubuntu 24.04 + XFCE)", "Terminal / Dev (Ubuntu 24.04 server)",
            "Smallest (Ubuntu 24.04 minimal)", "Kali Linux (installer ISO)", "Fedora Xfce spin (ISO)",
            "Ubuntu Desktop 24.04 (installer ISO)", "macOS (Apple silicon)",
        ])
        XCTAssertEqual(Set(MachineTemplate.all.map(\.id)).count, 8)
        XCTAssertEqual(MachineTemplate.all.filter(\.recommended).map(\.id), ["agent-desktop-debian"])
        for t in MachineTemplate.all {
            XCTAssertEqual(t.display.width, 1280, t.id)
            XCTAssertEqual(t.display.height, 800, t.id)
            XCTAssertGreaterThanOrEqual(t.memoryBytes, t.minimumMemoryBytes, t.id)
            guard t.kind != .macOS else { XCTAssertTrue(t.imageIDs.isEmpty); continue }
            for arch in GuestArchitecture.allCases {
                let image = try XCTUnwrap(t.image(for: arch), "\(t.id) \(arch)")
                XCTAssertEqual(image.arch, arch)
                XCTAssertEqual(image.isISO, t.kind == .installerISO, t.id)
                XCTAssertFalse(image.experimental, t.id)
                if t.kind == .cloudImage {
                    XCTAssertNoThrow(try t.cloudInit(for: image, hostname: "h", password: "pw"), t.id)
                }
            }
        }
        XCTAssertEqual(try template("agent-desktop-debian").image(for: .arm64)?.id, "debian-13-generic-arm64")
        XCTAssertEqual(try template("agent-desktop-debian").desktop, .xfceX11)
        XCTAssertEqual(try template("terminal-dev-ubuntu").dev, .standard)
        XCTAssertEqual(try template("smallest-ubuntu-minimal").image(for: .x86_64)?.id, "ubuntu-24.04-minimal-x86_64")
        // Desktop VMs get at least the 12 GB the research asks for.
        XCTAssertGreaterThanOrEqual(try template("agent-desktop-debian").diskBytes, 12 << 30)
    }

    func testFitsOnAppleSilicon() throws {
        let mac = host(.arm64)
        for t in MachineTemplate.all {
            let fit = t.fits(host: mac)
            XCTAssertTrue(fit.canCreate, "\(t.id): \(fit.blockers)")
            XCTAssertFalse(fit.needsNopku, t.id)
        }
        XCTAssertTrue(try template("agent-desktop-debian").fits(host: mac).warnings.isEmpty)
        // The Ubuntu Desktop ISO warns about Wayland.
        XCTAssertTrue(try template("ubuntu-desktop-iso").fits(host: mac).warnings.contains { $0.contains("X11") })
    }

    func testMemoryAndDiskChecks() throws {
        let desktop = try template("agent-desktop-debian")
        let small = host(.arm64, memoryGB: 4)
        XCTAssertTrue(desktop.fits(host: small).canCreate)
        XCTAssertEqual(desktop.memory(for: small), 2 << 30)
        XCTAssertTrue(desktop.fits(host: small).warnings.contains { $0.contains("Memory lowered") })
        XCTAssertEqual(desktop.memory(for: host(.arm64, memoryGB: 16)), 4 << 30)
        XCTAssertFalse(desktop.fits(host: host(.arm64, memoryGB: 3)).canCreate)
        XCTAssertFalse(try template("macos").fits(host: host(.arm64, memoryGB: 4)).canCreate)

        XCTAssertFalse(desktop.fits(host: host(.arm64, diskGB: 2)).canCreate)
        XCTAssertTrue(desktop.fits(host: host(.arm64, diskGB: 8)).canCreate)
        XCTAssertTrue(desktop.fits(host: host(.arm64, diskGB: 8)).warnings.contains { $0.contains("can grow") })
        XCTAssertTrue(desktop.fits(host: host(.arm64, diskGB: nil)).canCreate)
    }

    func testIntelHostsAndTheNopkuHint() throws {
        let oldIntel = host(.x86_64, os: HostProfile.Version(15, 4, 1))
        let debian = try template("agent-desktop-debian").fits(host: oldIntel)
        XCTAssertTrue(debian.canCreate)
        XCTAssertTrue(debian.needsNopku)
        XCTAssertTrue(debian.warnings.contains { $0.contains("nopku") && $0.contains("Ubuntu 24.04") })
        XCTAssertFalse(try template("agent-desktop-ubuntu").fits(host: oldIntel).needsNopku)
        XCTAssertFalse(try template("smallest-ubuntu-minimal").fits(host: oldIntel).needsNopku)
        XCTAssertTrue(try template("kali-iso").fits(host: oldIntel).warnings.contains { $0.contains("press e in GRUB") })
        XCTAssertFalse(try template("agent-desktop-debian").fits(host: host(.x86_64, os: HostProfile.Version(15, 5))).needsNopku)
        XCTAssertFalse(try template("macos").fits(host: oldIntel).canCreate)
        XCTAssertFalse(MachineTemplate.canSetKernelArguments)
    }

    func testMakeSpec() throws {
        let t = try template("agent-desktop-debian")
        let spec = t.makeSpec(host: host(.arm64, cpus: 2))
        XCTAssertEqual(spec.name, "Agent Desktop (Debian 13 + XFCE)")
        XCTAssertEqual(spec.guest, .linux)
        XCTAssertEqual(spec.cpuCount, 2)
        XCTAssertEqual(spec.memoryBytes, 4 << 30)
        XCTAssertEqual(spec.diskBytes, 16 << 30)
        XCTAssertEqual(spec.display.width, 1280)
        XCTAssertEqual(spec.display.height, 800)
        XCTAssertEqual(try template("macos").makeSpec(name: "Mac", host: host(.arm64)).guest, .macOS)
    }

    func testVersions() {
        XCTAssertEqual(HostProfile.Version(string: "15.5"), HostProfile.Version(15, 5))
        XCTAssertEqual(HostProfile.Version(string: "26"), HostProfile.Version(26))
        XCTAssertLessThan(HostProfile.Version(15, 4, 1), HostProfile.Version(15, 5))
        XCTAssertNil(HostProfile.Version(string: "fifteen"))
        XCTAssertNil(HostProfile.Version(string: ""))
        XCTAssertEqual(HostProfile.Version(15, 5).description, "15.5")
    }
}

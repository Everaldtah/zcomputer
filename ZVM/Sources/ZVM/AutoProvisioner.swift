import Foundation
import ZCore

/// Shell snippets that install `zguest` from the virtio-fs share (tag `zguest`, see `VMController`) into
/// `/usr/local/bin/zguest` with a systemd unit. Used by `AutoProvisioner` (serial console) and by the
/// cloud-init seed (`CloudInitConfig`), so both paths install the agent the same way.
public enum GuestAgentInstall {
    /// The virtio-fs tag the host shares the agent binaries under.
    public static let shareTag = "zguest"
    /// Where the share is mounted in the guest.
    public static let mountPoint = "/mnt/zguest"

    /// Kept in sync with guest-agent/systemd/zguest.service.
    public static let systemdUnit = """
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

        """

    /// A POSIX `sh` script (run as root) that mounts the share, installs the binary and enables the service.
    /// - Parameter binaryName: file name inside the share. When it is missing, `zguest-linux-<arch>` is tried
    ///   (arch from `uname -m`), so sharing a folder with both architectures works.
    public static func script(binaryName: String, shareTag: String = shareTag, mountPoint: String = mountPoint) -> String {
        let mp = shellQuote(mountPoint)
        let src = shellQuote(mountPoint + "/" + binaryName)
        return """
            set -e
            mkdir -p \(mp)
            if ! mountpoint -q \(mp); then mount -t virtiofs -o ro \(shellQuote(shareTag)) \(mp); fi
            case "$(uname -m)" in aarch64|arm64) Z_ARCH=arm64 ;; x86_64|amd64) Z_ARCH=amd64 ;; *) Z_ARCH=$(uname -m) ;; esac
            Z_SRC=\(src)
            [ -f "$Z_SRC" ] || Z_SRC=\(mp)/zguest-linux-$Z_ARCH
            [ -f "$Z_SRC" ] || { echo "zguest binary not found in the \(shareTag) share" >&2; exit 1; }
            if command -v systemctl >/dev/null 2>&1; then systemctl stop zguest.service 2>/dev/null || true; fi
            install -m 0755 "$Z_SRC" /usr/local/bin/zguest
            cat > /etc/systemd/system/zguest.service <<'ZGUEST_UNIT'
            \(systemdUnit)ZGUEST_UNIT
            grep -qs '^\(shareTag) ' /etc/fstab || echo '\(shareTag) \(mountPoint) virtiofs ro,nofail 0 0' >> /etc/fstab
            modprobe vmw_vsock_virtio_transport 2>/dev/null || true
            systemctl daemon-reload
            systemctl enable --now zguest.service
            systemctl is-active zguest.service

            """
    }
}

/// Installs `zguest` into a fresh Linux guest through the serial console: logs in, mounts the `zguest`
/// virtio-fs share, copies the binary to `/usr/local/bin`, installs the systemd unit and starts it.
/// The VM must have been started with `VMController(guestAgentBinary:)` so the share exists.
public struct AutoProvisioner: Sendable {
    public var user: String
    public var password: String?
    /// File name of the agent binary inside the share (e.g. "zguest-linux-arm64").
    public var binaryName: String
    public var shareTag: String

    public init(user: String, password: String?, binaryName: String, shareTag: String = GuestAgentInstall.shareTag) {
        self.user = user; self.password = password; self.binaryName = binaryName; self.shareTag = shareTag
    }

    /// The command typed into the logged-in console: root runs the script directly, other users go through
    /// `sudo` (with `-S` and the password when one is known, else `-n`).
    public func command() -> String {
        let script = GuestAgentInstall.script(binaryName: binaryName, shareTag: shareTag)
        if user == "root" { return script }
        let wrapped = "sh -c " + shellQuote(script)
        if let password, !password.isEmpty {
            return "printf '%s\\n' \(shellQuote(password)) | sudo -S -p '' " + wrapped
        }
        return "sudo -n " + wrapped
    }

    /// Logs in (if needed) and installs the agent. Returns the script's output; throws when it fails.
    /// Afterwards `GuestAgentClient.ping()` should answer within a few seconds.
    @discardableResult
    public func provision(shell: SerialShell, loginTimeout: TimeInterval = 300, timeout: TimeInterval = 180) async throws -> ShellResult {
        let alreadyInShell = await shell.probe(timeout: 3)
        if !alreadyInShell {
            try await shell.login(user: user, password: password, timeout: loginTimeout)
        }
        let result = try await shell.run(command(), timeout: timeout)
        guard result.exitCode == 0 else {
            throw ZError.guest("installing zguest failed (exit \(result.exitCode)): \(result.stdout.suffix(800))")
        }
        return result
    }
}

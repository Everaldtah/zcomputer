import Darwin
import Foundation
@preconcurrency import Virtualization
import ZCore

/// Adapters from Virtualization.framework completion handlers to continuations.
///
/// The overloads differ only in their return type, so the compiler picks whichever matches the framework's
/// handler type (`Result<Void, Error>` for start/pause/resume/install, `Error?` for stop/start(options:)).
/// The returned closures are `@Sendable` and touch nothing but the continuation, so they are safe on any queue.
enum VZCompletion {
    static func handler(_ cont: CheckedContinuation<Void, any Error>) -> @Sendable (Result<Void, any Error>) -> Void {
        { result in cont.resume(with: result) }
    }

    static func handler(_ cont: CheckedContinuation<Void, any Error>) -> @Sendable ((any Error)?) -> Void {
        { error in
            if let error { cont.resume(throwing: error) } else { cont.resume() }
        }
    }

    /// Records the outcome instead of resuming (for operations polled in a loop, e.g. the macOS installer).
    static func recorder(_ box: Locked<Result<Void, any Error>?>) -> @Sendable (Result<Void, any Error>) -> Void {
        { result in box.set(result) }
    }

    static func recorder(_ box: Locked<Result<Void, any Error>?>) -> @Sendable ((any Error)?) -> Void {
        { error in
            if let error {
                box.set(.failure(error))
            } else {
                box.set(.success(()))
            }
        }
    }
}

/// Keeps a `VZVirtioSocketConnection` alive while our duplicated descriptor is in use, and closes it on the
/// main queue (the VM's queue) afterwards.
final class VsockConnectionBox: @unchecked Sendable {
    private let connection: VZVirtioSocketConnection

    init(_ connection: VZVirtioSocketConnection) { self.connection = connection }

    func closeOnMain() {
        DispatchQueue.main.async { self.connection.close() }
    }
}

/// A connected vsock stream: our own dup of the descriptor plus the framework object it came from.
struct OpenedVsock: Sendable {
    let fileDescriptor: Int32
    let box: VsockConnectionBox
}

enum VsockCompletion {
    static func handler(_ cont: CheckedContinuation<OpenedVsock, any Error>, once: OneShot)
        -> @Sendable (Result<VZVirtioSocketConnection, any Error>) -> Void {
        { result in
            switch result {
            case .success(let connection):
                deliver(connection, cont, once)
            case .failure(let error):
                if once.fire() {
                    cont.resume(throwing: GuestAgentError(code: .transport, message: "vsock connect failed: \(error.localizedDescription)"))
                }
            }
        }
    }

    static func handler(_ cont: CheckedContinuation<OpenedVsock, any Error>, once: OneShot)
        -> @Sendable (VZVirtioSocketConnection?, (any Error)?) -> Void {
        { connection, error in
            if let connection {
                deliver(connection, cont, once)
            } else if once.fire() {
                let message = error?.localizedDescription ?? "no connection"
                cont.resume(throwing: GuestAgentError(code: .transport, message: "vsock connect failed: \(message)"))
            }
        }
    }

    private static func deliver(_ connection: VZVirtioSocketConnection, _ cont: CheckedContinuation<OpenedVsock, any Error>,
                                _ once: OneShot) {
        let box = VsockConnectionBox(connection)
        guard once.fire() else {
            box.closeOnMain()   // the caller already timed out
            return
        }
        // Defensive dup: the descriptor's lifetime is tied to the connection object (UNVERIFIED), ours is not.
        let fd = dup(connection.fileDescriptor)
        guard fd >= 0 else {
            box.closeOnMain()
            cont.resume(throwing: GuestAgentError(code: .transport, message: "dup failed (errno \(errno))"))
            return
        }
        cont.resume(returning: OpenedVsock(fileDescriptor: fd, box: box))
    }
}

extension VZVirtualMachine.State {
    /// A readable name for logs and errors.
    var name: String {
        switch self {
        case .stopped: return "stopped"
        case .running: return "running"
        case .paused: return "paused"
        case .error: return "error"
        case .starting: return "starting"
        case .pausing: return "pausing"
        case .resuming: return "resuming"
        case .stopping: return "stopping"
        case .saving: return "saving"
        case .restoring: return "restoring"
        @unknown default: return "unknown"
        }
    }
}

import SwiftTerm
import SwiftUI
import UIKit
import ZCore

// Only this file imports SwiftTerm (it defines its own `Color`, which would shadow SwiftUI's elsewhere).

/// Where a terminal's bytes come from and go to.
@MainActor
protocol ConsoleEndpoint: AnyObject {
    /// Output to show (replaying recent output first).
    func output() -> AsyncStream<Data>
    func send(_ bytes: [UInt8])
}

/// An emulated machine's serial console (ttyS0) from its runtime.
@MainActor
final class MachineConsoleEndpoint: ConsoleEndpoint {
    let runtime: any MachineRuntime

    init(runtime: any MachineRuntime) {
        self.runtime = runtime
    }

    func output() -> AsyncStream<Data> { runtime.consoleOutput() }

    func send(_ bytes: [UInt8]) { runtime.writeConsole(Data(bytes)) }
}

/// The Demo machine's simulated shell as a line-based console: echoes typing, runs a line on Return.
@MainActor
final class DemoConsoleEndpoint: ConsoleEndpoint {
    let surface: MockComputerSurface
    private var line: [UInt8] = []
    private var continuation: AsyncStream<Data>.Continuation?

    init(surface: MockComputerSurface) {
        self.surface = surface
    }

    func output() -> AsyncStream<Data> {
        continuation?.finish()
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        self.continuation = continuation
        continuation.yield(Data("Z Computer demo machine (simulated shell). Try `help`.\r\n\(DemoScreenState.prompt)".utf8))
        return stream
    }

    func send(_ bytes: [UInt8]) {
        for byte in bytes {
            switch byte {
            case 13, 10:
                let command = String(decoding: line, as: UTF8.self)
                line.removeAll()
                emit("\r\n")
                run(command)
            case 127, 8:
                if !line.isEmpty {
                    line.removeLast()
                    emit("\u{8} \u{8}")
                }
            case 3:
                line.removeAll()
                emit("^C\r\n\(DemoScreenState.prompt)")
            default:
                if byte >= 32 {
                    line.append(byte)
                    continuation?.yield(Data([byte]))
                }
            }
        }
    }

    private func run(_ command: String) {
        let surface = self.surface
        Task {
            let text: String
            if command.trimmingCharacters(in: .whitespaces).isEmpty {
                text = ""
            } else if let result = try? await surface.shell(command, timeout: 10) {
                text = result.stdout + result.stderr
            } else {
                text = "error\n"
            }
            let body = text.isEmpty ? "" : text.replacingOccurrences(of: "\n", with: "\r\n") + (text.hasSuffix("\n") ? "" : "\r\n")
            emit(body + DemoScreenState.prompt)
        }
    }

    private func emit(_ text: String) {
        continuation?.yield(Data(text.utf8))
    }
}

/// Owns one SwiftTerm view per endpoint for the session, so switching tabs re-attaches the same screen and
/// scrollback instead of rebuilding them (pattern from TermForge).
@MainActor
final class ConsoleTerminalController: NSObject, TerminalViewDelegate {
    let view: TerminalView
    let endpoint: any ConsoleEndpoint
    private var pump: Task<Void, Never>?

    init(endpoint: any ConsoleEndpoint) {
        self.endpoint = endpoint
        let font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        view = TerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 480), font: font)
        super.init()
        view.terminalDelegate = self
        view.nativeBackgroundColor = UIColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 1)
        view.nativeForegroundColor = UIColor(white: 0.92, alpha: 1)
        view.accessibilityIdentifier = "terminal"
        let stream = endpoint.output()
        let target = view
        pump = Task { @MainActor in
            for await data in stream {
                target.feed(byteArray: [UInt8](data)[...])
            }
        }
    }

    func stop() {
        pump?.cancel()
        pump = nil
    }

    @discardableResult
    func focus() -> Bool { view.becomeFirstResponder() }

    // MARK: TerminalViewDelegate

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: TerminalView, title: String) {}

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        endpoint.send(Array(data))
    }

    func scrolled(source: TerminalView, position: Double) {}

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return
        }
        UIApplication.shared.open(url)
    }

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    func clipboardCopy(source: TerminalView, content: Data) {
        if let text = String(data: content, encoding: .utf8) { UIPasteboard.general.string = text }
    }
}

/// Hosts a controller's terminal view in SwiftUI; the view is moved, not recreated, when SwiftUI rebuilds this.
struct ConsoleTerminalView: UIViewRepresentable {
    let controller: ConsoleTerminalController

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = controller.view.nativeBackgroundColor
        attach(to: container)
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        if controller.view.superview !== container { attach(to: container) }
    }

    private func attach(to container: UIView) {
        let terminal = controller.view
        terminal.removeFromSuperview()
        terminal.frame = container.bounds
        terminal.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(terminal)
    }
}

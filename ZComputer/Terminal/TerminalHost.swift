import AppKit
import SwiftTerm
import SwiftUI
import ZVM

// Only this file imports SwiftTerm (it defines its own `Color`, which would shadow SwiftUI's elsewhere).

/// Where a terminal's bytes come from and go to.
@MainActor
protocol TerminalEndpoint: AnyObject {
    /// Starts delivering output (replaying recent output first). `receiver` may be called on any thread.
    func attach(_ receiver: @escaping @Sendable ([UInt8]) -> Void)
    func detach()
    func send(_ bytes: [UInt8])
    func resize(cols: Int, rows: Int)
}

extension HostShellSession: TerminalEndpoint {
    func attach(_ receiver: @escaping @Sendable ([UInt8]) -> Void) {
        start()
        output.attach(receiver)
    }

    func detach() { output.detach() }

    func send(_ bytes: [UInt8]) { write(bytes) }
}

/// A VM's serial console (hvc0) from ZVM's `SerialConsole`.
@MainActor
final class SerialConsoleEndpoint: TerminalEndpoint {
    let console: SerialConsole
    private var pump: Task<Void, Never>?

    init(console: SerialConsole) {
        self.console = console
    }

    func attach(_ receiver: @escaping @Sendable ([UInt8]) -> Void) {
        pump?.cancel()
        let stream = console.output(replay: true)
        pump = Task.detached {
            for await data in stream { receiver([UInt8](data)) }
        }
    }

    func detach() {
        pump?.cancel()
        pump = nil
    }

    func send(_ bytes: [UInt8]) { console.write(Data(bytes)) }

    func resize(cols: Int, rows: Int) {}
}

/// SwiftTerm's AppKit `TerminalView` bound to a `TerminalEndpoint`.
struct TerminalHostView: NSViewRepresentable {
    let endpoint: any TerminalEndpoint

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> TerminalView {
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        view.terminalDelegate = context.coordinator
        context.coordinator.bind(view: view, endpoint: endpoint)
        return view
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {
        context.coordinator.bind(view: nsView, endpoint: endpoint)
    }

    static func dismantleNSView(_ nsView: TerminalView, coordinator: Coordinator) {
        coordinator.unbind()
    }

    @MainActor
    final class Coordinator: NSObject, TerminalViewDelegate {
        private weak var view: TerminalView?
        private var endpoint: (any TerminalEndpoint)?

        func bind(view: TerminalView, endpoint: any TerminalEndpoint) {
            if let current = self.endpoint, current === endpoint, self.view === view { return }
            self.endpoint?.detach()
            self.view = view
            self.endpoint = endpoint
            endpoint.attach { [weak view] bytes in
                view?.feed(byteArray: bytes[...])
            }
        }

        func unbind() {
            endpoint?.detach()
            endpoint = nil
        }

        // MARK: TerminalViewDelegate

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            endpoint?.resize(cols: newCols, rows: newRows)
        }

        func setTerminalTitle(source: TerminalView, title: String) {}

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            endpoint?.send(Array(data))
        }

        func scrolled(source: TerminalView, position: Double) {}

        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

        func clipboardCopy(source: TerminalView, content: Data) {
            guard let text = String(data: content, encoding: .utf8) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }
}

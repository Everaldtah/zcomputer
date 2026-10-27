import AppKit
import SwiftUI
@preconcurrency import Virtualization
import ZCore
import ZVM

/// The VM's screen for the user: a `VZVirtualMachineView` from `VMDisplayHost.makeUserView()` (the hidden agent view
/// stays untouched, so agent coordinates keep matching the guest display).
struct VMDisplayView: NSViewRepresentable {
    let controller: VMController

    func makeNSView(context: Context) -> VZVirtualMachineView {
        controller.displayHost.makeUserView(reconfiguresDisplay: false, capturesSystemKeys: true)
    }

    func updateNSView(_ nsView: VZVirtualMachineView, context: Context) {}
}

/// The Demo machine's screen, refreshed while visible.
struct DemoMachineDisplay: View {
    @Environment(AppModel.self) private var model
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Color.black
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                ProgressView()
            }
        }
        .task {
            let demo = model.machines.demo
            while !Task.isCancelled {
                if let shot = try? await demo.screenshot() {
                    image = NSImage(data: shot.data)
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }
}

/// A screen area with the "Agent is controlling" overlay when the agent drives this machine.
struct ControlledScreen<Content: View>: View {
    @Environment(AppModel.self) private var model
    let machineName: String
    let content: Content

    init(machineName: String, @ViewBuilder content: () -> Content) {
        self.machineName = machineName
        self.content = content()
    }

    var body: some View {
        let controlled = model.agent.isControllingMachine && model.agent.controlledMachineName == machineName
        content
            .overlay {
                if controlled {
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.red.opacity(0.85), lineWidth: 3)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .top) {
                if controlled {
                    AgentControllingBanner().padding(.top, 10)
                }
            }
    }
}

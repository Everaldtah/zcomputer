import SwiftUI
import ZCore

/// The visible "Agent is controlling" indicator with a recording dot and a Stop button (App Review 2.5.14: the user
/// must see when an agent watches and drives a machine).
struct AgentControllingBanner: View {
    @Environment(AppModel.self) private var model
    @State private var pulse = false

    var body: some View {
        let session = model.agent
        HStack(spacing: 10) {
            Circle()
                .fill(Color.red)
                .frame(width: 10, height: 10)
                .opacity(pulse ? 0.35 : 1)
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
            Text("Agent is controlling \(session.controlledMachineName ?? "the machine")")
                .font(.callout.weight(.semibold))
            Text(session.mainStatus.label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                session.stop()
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Capsule().fill(.regularMaterial))
        .overlay(Capsule().strokeBorder(Color.red.opacity(0.5)))
        .shadow(radius: 6, y: 2)
        .onAppear { pulse = true }
    }
}

/// Asks before screenshots and files go to a cloud provider (App Review 5.1.2(i)). Local models need no consent.
struct CloudConsentSheet: View {
    @Environment(AppModel.self) private var model
    var request: ConsentRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "eye.trianglebadge.exclamationmark")
                    .font(.largeTitle)
                    .foregroundStyle(.orange)
                Text("Send screenshots to \(request.providerName)?")
                    .font(.title2.weight(.semibold))
            }
            Text("To work on \(request.machineName), the agent takes screenshots of it and may read files and command "
                 + "output there. Those screenshots and texts are sent to \(request.providerName), a third-party AI "
                 + "service, together with your task, so the model can decide the next step.")
            Text("Nothing is sent until you allow it. You can withdraw this permission in Settings ▸ Agent. "
                 + "Models that run on this Mac (MLX, Ollama, LM Studio, Apple on-device) never need this permission.")
                .foregroundStyle(.secondary)
            GroupBox {
                Text(request.task)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            } label: {
                Text("Task")
            }
            HStack {
                Spacer()
                Button("Don't Allow") { model.agent.resolveConsent(request, allow: false) }
                    .keyboardShortcut(.cancelAction)
                Button("Allow for \(request.providerName)") { model.agent.resolveConsent(request, allow: true) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 520)
    }
}

import SwiftUI
import ZCore
import ZVM

/// Progress of a machine made by the Image Library: download → disk → boot → agent online → desktop (n/total) →
/// ready for agents. The steps after "boot" come from the guest agent (`/var/lib/zguest/provision.status`).
struct ProvisioningPanel: View {
    @Environment(AppModel.self) private var model
    var id: UUID
    var progress: ProvisionProgress

    var body: some View {
        let library = model.imageLibrary
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.callout.weight(.semibold))
                Spacer()
                actions
            }
            switch progress.stage {
            case .manual(let text):
                Label(text, systemImage: "hand.point.up.left").font(.callout)
            case .failed(let text):
                Label(text, systemImage: "xmark.octagon.fill").font(.callout).foregroundStyle(.red).textSelection(.enabled)
            default:
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    StepRow(title: step, phase: phase(of: index))
                }
            }
            if progress.stage == .waitingForImage, let imageID = progress.imageID, let image = library.image(id: imageID) {
                ImageDownloadStatus(image: image)
            }
            if let hint = progress.hint {
                Label(hint, systemImage: "info.circle").font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(tint.opacity(0.08)))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private var title: String {
        switch progress.stage {
        case .ready: return "Ready for agents"
        case .failed: return "\(progress.templateName): setup stopped"
        case .manual: return progress.templateName
        default: return "Setting up \(progress.templateName)"
        }
    }

    private var tint: Color {
        switch progress.stage {
        case .ready: return .green
        case .failed: return .red
        default: return .accentColor
        }
    }

    @ViewBuilder
    private var actions: some View {
        let library = model.imageLibrary
        let running = model.machines.state(id).isActive
        switch progress.stage {
        case .ready:
            Text("This is now the Agent's machine.").font(.caption).foregroundStyle(.secondary)
            Button("Open Agent") { model.selection = .agent }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            Button("Done") { library.dismissProvisioning(id) }.controlSize(.small)
        case .failed:
            if running {
                Button("Check again") { library.watchProvisioning(id) }.controlSize(.small)
            }
            Button("Dismiss") { library.dismissProvisioning(id) }.controlSize(.small)
        case .manual:
            if model.machines.agentChoice != .vm(id) {
                Button("Use for the agent") { model.machines.setAgentChoice(.vm(id)) }.controlSize(.small)
            }
            Button("Dismiss") { library.dismissProvisioning(id) }.controlSize(.small)
        default:
            Text(elapsed).font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    private var elapsed: String {
        "started " + progress.startedAt.formatted(date: .omitted, time: .shortened)
    }

    private var steps: [String] {
        var out = ["Download and verify the image", "Prepare the disk", "Boot", "Guest agent online"]
        if case .installing(let step, let total, let label) = progress.stage {
            out.append("\(label) (\(step)/\(total))")
        } else {
            out.append(progress.hasDesktop ? "Install the desktop" : "First-boot setup")
        }
        out.append("Ready for agents")
        return out
    }

    private func phase(of index: Int) -> StepRow.Phase {
        let current = progress.stage.order
        if progress.stage == .ready || index < current { return .done }
        return index == current ? .running : .pending
    }
}

private struct StepRow: View {
    enum Phase { case done, running, pending }

    var title: String
    var phase: Phase

    var body: some View {
        HStack(spacing: 8) {
            Group {
                switch phase {
                case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .running: ProgressView().controlSize(.small)
                case .pending: Image(systemName: "circle").foregroundStyle(.tertiary)
                }
            }
            .frame(width: 18, height: 18)
            Text(title)
                .font(.callout)
                .foregroundStyle(phase == .pending ? Color.secondary : Color.primary)
        }
    }
}

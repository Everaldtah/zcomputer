import SwiftUI
import UIKit
import ZCore
import ZProviders

/// A small coloured status dot.
struct StatusDot: View {
    var color: Color

    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8)
    }
}

/// A grey capsule label ("vision", "tools").
struct Badge: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.secondary.opacity(0.15)))
    }
}

/// Free / Free tier / Paid / Local.
struct KindBadge: View {
    var kind: ProviderKind

    var body: some View {
        let (text, color): (String, Color) = {
            switch kind {
            case .free: return ("Free", .green)
            case .freemium: return ("Free tier", .teal)
            case .paid: return ("Paid", .secondary)
            case .local: return ("Local", .blue)
            }
        }()
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundStyle(color)
    }
}

/// An inline notice (errors, questions).
struct MessageBanner: View {
    var text: String
    var systemImage: String
    var tint: Color
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage).foregroundStyle(tint)
            Text(text).font(.callout).textSelection(.enabled)
            Spacer(minLength: 0)
            if let onDismiss {
                Button(action: onDismiss) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss")
            }
        }
        .padding(10)
        .background(tint.opacity(0.1))
    }
}

/// The agent's status as a coloured capsule.
struct StatusPill: View {
    var status: AgentStatus
    var running: Bool

    var body: some View {
        Text(running || status != .idle ? status.label : "Ready")
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundStyle(color)
    }

    private var color: Color {
        switch status {
        case .thinking, .acting: return .green
        case .waitingForApproval, .paused: return .orange
        case .failed: return .red
        case .finished: return .blue
        case .idle, .stopped: return .secondary
        }
    }
}

/// A full-screen image viewer with pinch to zoom (screenshots the agent looked at).
struct ImageViewer: View {
    @Environment(\.dismiss) private var dismiss
    var image: UIImage
    var caption: String
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollView([.horizontal, .vertical]) {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: geometry.size.width * scale)
                        .gesture(MagnifyGesture()
                            .onChanged { value in scale = min(5, max(1, lastScale * value.magnification)) }
                            .onEnded { _ in lastScale = scale })
                }
            }
            .background(Color.black)
            .navigationTitle(caption)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .bottomBar) {
                    Button { UIPasteboard.general.image = image } label: { Label("Copy", systemImage: "doc.on.doc") }
                }
            }
        }
    }
}

extension MemoryKind {
    var title: String {
        switch self {
        case .profile: return "Profile"
        case .fact: return "Facts"
        case .episode: return "Episodes"
        case .document: return "Documents"
        case .chunk: return "Chunks"
        case .preference: return "Preferences"
        }
    }

    var systemImage: String {
        switch self {
        case .profile: return "person.crop.circle"
        case .fact: return "lightbulb"
        case .episode: return "clock.arrow.circlepath"
        case .document: return "doc.text"
        case .chunk: return "text.alignleft"
        case .preference: return "slider.horizontal.3"
        }
    }
}

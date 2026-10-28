import SwiftUI
import ZCore
import ZVM

/// One one-click machine in the Image Library: what it is, what it costs, whether it fits this Mac, and Get & Boot.
struct TemplateCard: View {
    @Environment(AppModel.self) private var model
    var template: MachineTemplate

    var body: some View {
        let library = model.imageLibrary
        let image = library.image(for: template)
        let fit = library.fit(template)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: Self.symbol(for: template.role))
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 36, height: 36)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.12)))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(template.name).font(.headline)
                        if template.recommended { ImageBadge(text: "Recommended", tint: .green) }
                    }
                    Text(image?.name ?? (template.kind == .macOS ? "Apple restore image" : "No image for this Mac"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text(template.summary)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                ImageFact(symbol: "arrow.down.circle", text: downloadText(image))
                ImageFact(symbol: "macwindow", text: desktopText(image))
                ImageFact(symbol: "clock", text: template.firstBoot)
                ImageFact(symbol: "cpu", text: resourcesText(library.host))
            }

            ForEach(fit.blockers, id: \.self) { text in
                Label(text, systemImage: "xmark.octagon.fill").font(.caption).foregroundStyle(.red)
            }
            ForEach(fit.warnings, id: \.self) { text in
                Label(text, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
            }

            if let image {
                ImageDownloadStatus(image: image)
            }

            HStack {
                if let image, !library.isVerified(image), library.downloads[image.id] == nil,
                   library.partialBytes(image) == nil, fit.canCreate {
                    Button("Download only") { library.startDownload(image) }
                        .help("Download and verify the image now; create the machine later")
                }
                Spacer()
                Button {
                    library.getAndBoot(template)
                } label: {
                    Label(template.kind == .macOS ? "Get & Install" : "Get & Boot", systemImage: "bolt.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!fit.canCreate)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(template.recommended ? Color.green.opacity(0.55) : Color.secondary.opacity(0.2),
                              lineWidth: template.recommended ? 1.5 : 1)
        )
    }

    private func downloadText(_ image: CatalogImage?) -> String {
        guard let image else {
            return template.kind == .macOS ? "Download: macOS restore image from Apple (several GB)" : "Download: none for this Mac"
        }
        var text = "Download: \(Format.bytes(image.sizeBytes)) · \(image.arch.rawValue)"
        if let extra = template.firstBootDownloadBytes[image.arch] {
            text += " (+ about \(Format.bytes(extra)) of packages on first boot)"
        }
        return text
    }

    private func desktopText(_ image: CatalogImage?) -> String {
        switch template.kind {
        case .cloudImage:
            if template.desktop != .none { return "Desktop: \(template.desktop.displayName), auto-login, set up on first boot" }
            return template.dev != .none ? "Terminal only, with \(template.dev.displayName)" : "Terminal only (no desktop)"
        case .installerISO:
            return "Desktop: " + (image?.desktop?.displayName ?? "none (console installer)") + ", installed by hand"
        case .macOS:
            return "Desktop: macOS"
        }
    }

    private func resourcesText(_ host: HostProfile) -> String {
        let spec = template.makeSpec(host: host)
        return "VM: \(spec.cpuCount) CPUs · \(spec.memoryBytes >> 30) GB memory · \(spec.diskBytes >> 30) GB disk (sparse) · "
            + "\(spec.display.width)×\(spec.display.height)"
    }

    static func symbol(for role: MachineTemplate.Role) -> String {
        switch role {
        case .desktop: return "macwindow.on.rectangle"
        case .terminal: return "terminal"
        case .small: return "shippingbox"
        case .installer: return "opticaldisc"
        case .macOS: return "apple.logo"
        }
    }
}

/// Download progress, pause/resume and checksum status of one catalogue image.
struct ImageDownloadStatus: View {
    @Environment(AppModel.self) private var model
    var image: CatalogImage

    var body: some View {
        let library = model.imageLibrary
        if let state = library.downloads[image.id] {
            switch state.phase {
            case .downloading:
                progress(state, title: "Downloading") {
                    Button("Pause") { library.pauseDownload(image.id) }.controlSize(.small)
                }
            case .paused:
                progress(state, title: "Paused") {
                    Button("Resume") { library.resumeDownload(image.id) }.controlSize(.small)
                }
            case .verifying:
                VStack(alignment: .leading, spacing: 3) {
                    ProgressView().progressViewStyle(.linear)
                    Text("Verifying the \(image.checksum.algo.displayName) checksum…").font(.caption).foregroundStyle(.secondary)
                }
            case .verified:
                verified(state.checksumNote)
            case .failed(let message):
                HStack(alignment: .top) {
                    Label(message, systemImage: "xmark.octagon.fill").font(.caption).foregroundStyle(.red)
                    Spacer()
                    Button("Retry") { library.startDownload(image) }.controlSize(.small)
                }
            }
        } else if library.isVerified(image) {
            verified(nil)
        } else if let partial = library.partialBytes(image) {
            HStack {
                Text("Partly downloaded: \(Format.bytes(partial)) of \(Format.bytes(image.sizeBytes))")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Resume") { library.startDownload(image) }.controlSize(.small)
            }
        }
    }

    private func verified(_ note: String?) -> some View {
        Label("Downloaded and verified" + (note.map { " (\($0))" } ?? ""), systemImage: "checkmark.seal.fill")
            .font(.caption)
            .foregroundStyle(.green)
    }

    private func progress<Actions: View>(_ state: ImageDownloadState, title: String,
                                         @ViewBuilder actions: () -> Actions) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let fraction = state.fraction {
                ProgressView(value: fraction)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            HStack {
                Text("\(title): \(model.imageLibrary.progressText(state))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                actions()
            }
        }
    }
}

/// A small coloured capsule ("Recommended", "Experimental", ...).
struct ImageBadge: View {
    var text: String
    var tint: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.15)))
            .foregroundStyle(tint)
    }
}

/// One line of facts on a card.
struct ImageFact: View {
    var symbol: String
    var text: String

    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).frame(width: 16)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

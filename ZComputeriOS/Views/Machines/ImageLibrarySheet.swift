import SwiftUI
import UIKit
import UniformTypeIdentifiers
import ZCore

/// The image catalogue: the recommended instant-start "Z Alpine Desktop", installer ISOs (downloads with progress and
/// resume), and ISOs the user put into the app's folder in Files (or imports here).
struct ImageLibrarySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var importing = false
    @State private var creating: MachineCreateSource?

    var body: some View {
        let machines = model.machines
        let catalogue = machines.catalogue
        NavigationStack {
            List {
                if let reason = machines.engine.unavailableReason {
                    Section { Label(reason, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary) }
                }
                Section {
                    ForEach(catalogue.filter(\.recommended)) { image in
                        ImageRow(image: image) { creating = .image(image) }
                    }
                } header: {
                    Text("Recommended")
                } footer: {
                    Text("Ready to use: resumes straight at an XFCE desktop from a saved state, with the tools agents "
                         + "need (xdotool, scrot, zguest). User z, password z.")
                }
                Section("Installers and live systems") {
                    ForEach(catalogue.filter { !$0.recommended }) { image in
                        ImageRow(image: image) { creating = .image(image) }
                    }
                }
                Section {
                    ForEach(machines.userISOs, id: \.self) { url in
                        Button {
                            creating = .iso(url)
                        } label: {
                            HStack {
                                Image(systemName: "opticaldisc").foregroundStyle(.secondary)
                                VStack(alignment: .leading) {
                                    Text(url.lastPathComponent).lineLimit(1)
                                    Text(sizeText(url)).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("Create").font(.callout)
                            }
                        }
                        .disabled(!machines.isEngineAvailable)
                        .swipeActions {
                            Button(role: .destructive) { machines.deleteISO(url) } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                    Button {
                        importing = true
                    } label: {
                        if machines.isImportingISO {
                            HStack { ProgressView(); Text("Copying…") }
                        } else {
                            Label("Import an ISO from Files", systemImage: "square.and.arrow.down")
                        }
                    }
                    .disabled(machines.isImportingISO)
                } header: {
                    Text("Your ISO files")
                } footer: {
                    Text("Files ▸ On My iPhone ▸ Z Computer: drop .iso files there (or into its ISOs folder) and they "
                         + "appear here. The emulator runs 32-bit x86 (i386 / i686) systems.")
                }
            }
            .navigationTitle("Image library")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .refreshable { machines.refreshCatalogue() }
            .onAppear {
                machines.reload()
                machines.refreshCatalogue()
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: Self.isoTypes, allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls): if let url = urls.first { machines.importISO(url) }
                case .failure(let error): machines.message = Format.describe(error)
                }
            }
            .sheet(item: $creating) { source in
                CreateMachineSheet(source: source) {
                    creating = nil
                    dismiss()
                }
            }
        }
    }

    private static var isoTypes: [UTType] {
        var types: [UTType] = [.diskImage]
        if let iso = UTType(filenameExtension: "iso") { types.append(iso) }
        types.append(.data)
        return types
    }

    private func sizeText(_ url: URL) -> String {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return size > 0 ? Format.bytes(Int64(size)) : "ISO image"
    }
}

/// One catalogue image: availability (manifest), download / progress / cancel, create, delete.
private struct ImageRow: View {
    @Environment(AppModel.self) private var model
    let image: MachineImage
    var create: () -> Void
    @State private var confirmingDelete = false

    var body: some View {
        let machines = model.machines
        let state = machines.imageState(image)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(image.name).font(.body.weight(.semibold))
                if image.kind == .instantStart { Badge(text: "instant start") }
                Spacer()
                if let bytes = image.downloadBytes { Text(Format.bytes(bytes)).font(.caption).foregroundStyle(.secondary) }
            }
            Text(image.summary).font(.caption).foregroundStyle(.secondary)
            if let version = image.version {
                Text("Build \(version)").font(.caption2).foregroundStyle(.tertiary)
            }
            switch state {
            case .notDownloaded:
                availabilityControls(machines)
            case .downloading(let progress):
                ProgressLine(progress: progress)
                Button("Cancel", role: .cancel) { machines.cancelDownload(image) }
            case .ready:
                HStack {
                    Button(action: create) { Label("Create machine", systemImage: "plus.circle.fill") }
                        .buttonStyle(.borderedProminent)
                    Spacer()
                    Button(role: .destructive) { confirmingDelete = true } label: { Image(systemName: "trash") }
                        .accessibilityLabel("Delete the downloaded image")
                }
            case .failed(let message):
                Text(message).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                HStack {
                    Button("Retry") { machines.clearFailure(image); machines.download(image) }
                    Button("Dismiss") { machines.clearFailure(image) }
                }
            }
        }
        .buttonStyle(.borderless)
        .padding(.vertical, 4)
        .confirmationDialog("Delete \(image.name)?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete the downloaded files", role: .destructive) { machines.deleteImage(image) }
        } message: {
            Text("Machines made from it cannot start until you download it again.")
        }
    }

    /// Download, or why it cannot be downloaded yet.
    @ViewBuilder
    private func availabilityControls(_ machines: MachinesModel) -> some View {
        switch image.availability {
        case .available:
            Button { machines.download(image) } label: { Label("Download", systemImage: "arrow.down.circle") }
                .disabled(!machines.isEngineAvailable)
        case .resolving:
            HStack(spacing: 8) {
                ProgressView()
                Text("Checking the latest build…").font(.caption).foregroundStyle(.secondary)
            }
        case .unavailable(let reason):
            Label(reason, systemImage: "icloud.slash").font(.caption).foregroundStyle(.orange)
            Button { machines.refreshCatalogue() } label: { Label("Try again", systemImage: "arrow.clockwise") }
                .disabled(machines.isRefreshingCatalogue)
        }
    }
}

/// "Step 2 of 3 · Checking" with a bar when the fraction is known.
private struct ProgressLine: View {
    let progress: ImageProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let fraction = progress.fraction {
                ProgressView(value: min(max(fraction, 0), 1)) { label }
            } else {
                ProgressView { label }
            }
            Text(progress.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private var label: some View {
        Text(step.map { "Step \($0) of 3 · \(progress.phase.title)" } ?? progress.phase.title).font(.caption)
    }

    private var step: Int? {
        switch progress.phase {
        case .download: return 1
        case .verify: return 2
        case .unpack: return 3
        case .manifest, .ready: return nil
        }
    }
}

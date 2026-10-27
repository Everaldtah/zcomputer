import SwiftUI
import UniformTypeIdentifiers
import ZCore

/// What a new machine boots.
private enum CreateSource: Identifiable {
    case image(MachineImage)
    case iso(URL)

    var id: String {
        switch self {
        case .image(let image): return "image:\(image.id)"
        case .iso(let url): return "iso:\(url.path)"
        }
    }

    var title: String {
        switch self {
        case .image(let image): return image.name
        case .iso(let url): return url.deletingPathExtension().lastPathComponent
        }
    }

    var defaultMemoryMB: Int {
        switch self {
        case .image(let image): return image.defaultMemoryMB
        case .iso: return 512
        }
    }
}

/// The image catalogue: the recommended instant-start "Z Alpine Desktop", installer ISOs (downloads with progress and
/// resume), and ISOs the user put into the app's folder in Files (or imports here).
struct ImageLibrarySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var importing = false
    @State private var creating: CreateSource?

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
                    Text("Ready to use: boots straight to a desktop from a saved state, with the tools agents need.")
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
            .onAppear { machines.reload() }
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

/// One catalogue image: download / progress / cancel / create.
private struct ImageRow: View {
    @Environment(AppModel.self) private var model
    let image: MachineImage
    var create: () -> Void

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
            switch state {
            case .notDownloaded:
                Button { machines.download(image) } label: { Label("Download", systemImage: "arrow.down.circle") }
                    .disabled(!machines.isEngineAvailable)
            case .downloading(let progress):
                if let fraction = progress.fraction {
                    ProgressView(value: fraction) { Text(progress.detail).font(.caption) }
                } else {
                    ProgressView { Text(progress.detail).font(.caption) }
                }
                Button("Cancel", role: .cancel) { machines.cancelDownload(image) }
            case .ready:
                HStack {
                    Button(action: create) { Label("Create machine", systemImage: "plus.circle.fill") }
                        .buttonStyle(.borderedProminent)
                    Spacer()
                    Button(role: .destructive) { machines.deleteImage(image) } label: { Image(systemName: "trash") }
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
    }
}

/// Name and memory for a new machine.
private struct CreateMachineSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let source: CreateSource
    var onCreated: () -> Void
    @State private var name = ""
    @State private var memoryMB = 512

    var body: some View {
        NavigationStack {
            Form {
                TextField(source.title, text: $name)
                Stepper("Memory: \(memoryMB) MB", value: $memoryMB, in: 128...2048, step: 128)
                Section {
                    Text("The emulated PC's RAM comes out of the app's memory. 512 MB suits a light desktop; larger "
                         + "values can make iOS close the app on phones with less memory.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("New machine")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        switch source {
                        case .image(let image): model.machines.create(from: image, name: name, memoryMB: memoryMB)
                        case .iso(let url): model.machines.create(fromISO: url, name: name, memoryMB: memoryMB)
                        }
                        onCreated()
                    }
                }
            }
            .onAppear { memoryMB = source.defaultMemoryMB }
        }
        .presentationDetents([.medium])
    }
}

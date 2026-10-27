import SwiftUI
import ZCore
import ZVM

/// Machines ▸ Library: one-click machines for the agents, every catalogue image for this Mac, and the image cache.
struct ImageLibraryView: View {
    @Environment(AppModel.self) private var model

    private let columns = [GridItem(.adaptive(minimum: 320, maximum: 460), spacing: 14, alignment: .top)]

    var body: some View {
        let library = model.imageLibrary
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                LibraryHeader()
                if let error = library.lastError {
                    HStack {
                        MessageBanner(text: error, systemImage: "exclamationmark.triangle.fill", tint: .red)
                        Button { library.lastError = nil } label: { Image(systemName: "xmark") }
                            .buttonStyle(.borderless)
                    }
                }
                if let problem = library.catalogError ?? library.cacheError {
                    MessageBanner(text: problem, systemImage: "exclamationmark.triangle.fill", tint: .orange)
                }

                sectionTitle("Ready for agents",
                             "Cloud images with no installer: cloud-init creates the user z, installs the guest agent "
                                + "first and then the desktop, so the agent can watch the setup.")
                LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                    ForEach(library.cloudTemplates) { TemplateCard(template: $0) }
                }

                sectionTitle("Installers and macOS",
                             "Full distributions you install by hand in the VM window, and macOS on Apple silicon.")
                LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                    ForEach(library.otherTemplates) { TemplateCard(template: $0) }
                }

                AllImagesSection()
                CachedImagesSection()

                Label(ImageCatalog.windowsNote, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .onAppear {
            library.refreshCache()
            library.refreshHost()
        }
    }

    private func sectionTitle(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.title3.weight(.semibold))
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
        }
    }
}

private struct LibraryHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let host = model.imageLibrary.host
        VStack(alignment: .leading, spacing: 6) {
            Text("Image Library").font(.largeTitle.weight(.semibold))
            Text("Curated Linux images, checked against each distribution's own checksums. One click downloads, "
                 + "verifies, creates and boots a machine with the guest agent pre-installed.")
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ImageBadge(text: host.architecture == .arm64 ? "Apple silicon · arm64 guests" : "Intel · x86_64 guests",
                           tint: .accentColor)
                ImageBadge(text: "\(host.physicalMemoryBytes >> 30) GB memory", tint: .secondary)
                ImageBadge(text: "macOS \(host.osVersion.description)", tint: .secondary)
                if let free = host.availableDiskBytes {
                    ImageBadge(text: "\(Format.bytes(free)) free", tint: .secondary)
                }
            }
        }
    }
}

/// Every catalogue entry for this Mac's architecture: cloud images open "Ready-to-run Linux", ISOs the ISO flow.
private struct AllImagesSection: View {
    @Environment(AppModel.self) private var model
    @State private var expanded = false

    var body: some View {
        let library = model.imageLibrary
        let cloud = library.hostImages(.cloud)
        let isos = library.hostImages(.iso)
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Cloud images").font(.headline).padding(.vertical, 8)
                ForEach(cloud) { CatalogImageRow(image: $0) }
                Text("Installer ISOs").font(.headline).padding(.top, 16).padding(.bottom, 8)
                ForEach(isos) { CatalogImageRow(image: $0) }
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("All images for this Mac (\(cloud.count + isos.count))").font(.title3.weight(.semibold))
                Text("URLs, sizes and checksums verified 2026-10-27; booting under Virtualization.framework is "
                     + "unverified unless the notes cite lima or UTM.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct CatalogImageRow: View {
    @Environment(AppModel.self) private var model
    var image: CatalogImage

    var body: some View {
        let library = model.imageLibrary
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(image.name).font(.callout.weight(.medium))
                if let role = image.recommended { ImageBadge(text: "Recommended: \(role.rawValue)", tint: .green) }
                if image.experimental { ImageBadge(text: "Experimental", tint: .orange) }
                if image.isAdvanced { ImageBadge(text: "Advanced", tint: .purple) }
                if image.needsNopku(on: library.host) { ImageBadge(text: "Needs macOS \(image.intelMinMacOS ?? "15.5")", tint: .red) }
                Spacer()
                Text(Format.bytes(image.sizeBytes)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                Button(image.isCloudImage ? "New Machine…" : "New Machine from ISO…") {
                    model.machines.createRequest = CreateMachineRequest(start: image.isCloudImage ? .cloudImage(image.id)
                                                                                                : .catalogISO(image.id))
                }
                .controlSize(.small)
                .disabled(!model.machines.isSupported || model.machines.store == nil)
            }
            Text(desktopLine).font(.caption).foregroundStyle(.secondary)
            ForEach(image.notes.prefix(2), id: \.self) { note in
                Text("• " + note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ImageDownloadStatus(image: image)
            Divider().padding(.top, 6)
        }
        .padding(.vertical, 4)
    }

    private var desktopLine: String {
        let desktop: String
        if let kind = image.desktop {
            desktop = image.isCloudImage ? "\(kind.displayName) can be installed on first boot" : kind.displayName
        } else {
            desktop = image.isCloudImage ? "Terminal only" : "No desktop (console)"
        }
        var parts = [image.distro, image.version, image.format.rawValue, desktop,
                     "\(image.checksum.algo.displayName) (\(image.checksum.style.rawValue))"]
        if let user = image.cloudUser { parts.append("default user \(user)") }
        return parts.joined(separator: " · ")
    }
}

/// The image cache: what is downloaded, partial downloads to resume, and delete.
private struct CachedImagesSection: View {
    @Environment(AppModel.self) private var model
    @State private var pendingDelete: CachedImageFile?

    var body: some View {
        let library = model.imageLibrary
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Downloaded images").font(.title3.weight(.semibold))
                Text(Format.bytes(library.cachedBytes)).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Button("Refresh") { library.refreshCache() }.controlSize(.small)
            }
            Text("Kept in Application Support/ZComputer/Images so new machines start without downloading again. "
                 + "Machines already created keep working when you delete an image.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if library.cachedFiles.isEmpty {
                Text("Nothing downloaded yet.").foregroundStyle(.secondary)
            }
            ForEach(library.cachedFiles) { file in
                HStack(spacing: 8) {
                    Image(systemName: file.partial ? "arrow.down.circle.dotted" : (file.verified ? "checkmark.seal.fill" : "doc"))
                        .foregroundStyle(file.verified ? Color.green : Color.secondary)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(file.imageID.flatMap { library.image(id: $0)?.name } ?? file.fileName).lineLimit(1)
                        Text(statusText(file)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Spacer()
                    if file.partial, let id = file.imageID, library.downloads[id]?.isActive != true {
                        Button("Resume") { library.resumeDownload(id) }.controlSize(.small)
                    }
                    Button(role: .destructive) { pendingDelete = file } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .help("Delete this file")
                        .disabled(file.imageID.map { library.downloads[$0]?.isActive == true } ?? false)
                }
                .padding(.vertical, 2)
            }
        }
        .confirmationDialog("Delete \(pendingDelete?.fileName ?? "")?", isPresented: deleteBinding) {
            Button("Delete", role: .destructive) {
                if let file = pendingDelete { library.deleteCachedFile(file) }
                pendingDelete = nil
            }
        } message: {
            Text("The file is removed from the image cache. Machines created from it are not affected.")
        }
    }

    private var deleteBinding: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    private func statusText(_ file: CachedImageFile) -> String {
        if file.partial {
            return "Partial: \(Format.bytes(file.bytes))" + (file.expectedBytes.map { " of \(Format.bytes($0))" } ?? "")
        }
        return Format.bytes(file.bytes) + (file.verified ? " · checksum verified" : " · not verified") + " · \(file.fileName)"
    }
}

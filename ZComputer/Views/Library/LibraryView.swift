import SwiftUI
import ZCore

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

/// The personal library: search, kind filter, list + editor, import, profile / preferences.
struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var importing = false
    @State private var showProfile = false

    var body: some View {
        @Bindable var library = model.library
        HSplitView {
            VStack(spacing: 0) {
                LibraryToolbar(importing: $importing, showProfile: $showProfile)
                Divider()
                if !library.isAvailable {
                    ContentUnavailableView("Library unavailable", systemImage: "externaldrive.badge.xmark",
                                           description: Text(model.memoryStatus))
                } else {
                    List(selection: $library.selection) {
                        ForEach(library.items) { item in
                            LibraryRow(item: item, score: library.scores[item.id])
                                .tag(item.id)
                                .contextMenu {
                                    Button("Edit") { library.edit(item) }
                                    Button("Delete", role: .destructive) { Task { await model.library.delete(item.id) } }
                                }
                        }
                    }
                    .overlay {
                        if library.items.isEmpty && !library.isBusy {
                            ContentUnavailableView(library.query.isEmpty ? "Nothing here yet" : "No matches",
                                                   systemImage: "books.vertical",
                                                   description: Text(library.query.isEmpty
                                                        ? "Import notes or PDFs, add facts about yourself, or let agents save what they learn."
                                                        : "Try other words; search covers meaning and keywords."))
                        }
                    }
                }
                if let status = library.importStatus {
                    Text(status).font(.caption).foregroundStyle(.secondary).padding(6)
                }
            }
            .frame(minWidth: 320, idealWidth: 380)

            LibraryDetail()
                .frame(minWidth: 380)
        }
        .navigationTitle("Library")
        .searchable(text: $library.query, placement: .toolbar, prompt: "Search the library")
        .onSubmit(of: .search) { Task { await model.library.reload() } }
        .onChange(of: library.query) {
            if library.query.isEmpty { Task { await model.library.reload() } }
        }
        .onChange(of: library.kindFilter) { Task { await model.library.reload() } }
        .task { await model.library.reload() }
        .fileImporter(isPresented: $importing, allowedContentTypes: DocumentTextExtractor.importableTypes,
                      allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): Task { await model.library.importFiles(urls) }
            case .failure(let error): model.library.errorMessage = Format.describe(error)
            }
        }
        .sheet(isPresented: $showProfile) {
            ProfileEditor()
        }
        .alert("Library", isPresented: Binding(get: { model.library.errorMessage != nil },
                                               set: { if !$0 { model.library.errorMessage = nil } })) {
            Button("OK") { model.library.errorMessage = nil }
        } message: {
            Text(model.library.errorMessage ?? "")
        }
    }
}

private struct LibraryToolbar: View {
    @Environment(AppModel.self) private var model
    @Binding var importing: Bool
    @Binding var showProfile: Bool

    var body: some View {
        @Bindable var library = model.library
        HStack(spacing: 8) {
            Picker("Kind", selection: $library.kindFilter) {
                Text("All kinds").tag(MemoryKind?.none)
                ForEach(LibraryModel.listedKinds + [.chunk], id: \.self) { kind in
                    Label("\(kind.title) (\(library.counts[kind] ?? 0))", systemImage: kind.systemImage)
                        .tag(MemoryKind?.some(kind))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 190)
            Spacer()
            if library.isBusy { ProgressView().controlSize(.small) }
            Menu {
                ForEach(LibraryModel.listedKinds, id: \.self) { kind in
                    Button(kind.title) { library.newItem(kind: kind) }
                }
            } label: {
                Label("New", systemImage: "plus")
            }
            .fixedSize()
            Button { importing = true } label: { Label("Import", systemImage: "square.and.arrow.down") }
                .help("Import .txt, .md or .pdf files")
            Button { showProfile = true } label: { Label("Profile", systemImage: "person.crop.circle") }
                .help("What agents know about you and how they should behave")
        }
        .labelStyle(.titleAndIcon)
        .padding(8)
        .disabled(!library.isAvailable)
    }
}

private struct LibraryRow: View {
    var item: MemoryItem
    var score: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Image(systemName: item.kind.systemImage).foregroundStyle(.secondary)
                Text(item.title.isEmpty ? Format.clip(item.text, 50) : item.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Spacer()
                if let score { Text(String(format: "%.2f", score)).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary) }
            }
            Text(Format.clip(item.text.replacingOccurrences(of: "\n", with: " "), 140))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            HStack(spacing: 6) {
                Text(item.kind.title).font(.caption2).foregroundStyle(.tertiary)
                ForEach(item.tags.prefix(4), id: \.self) { tag in
                    Text(tag).font(.caption2).padding(.horizontal, 5).background(Capsule().fill(Color.secondary.opacity(0.12)))
                }
                Spacer()
                Text(item.updatedAt.formatted(date: .abbreviated, time: .omitted)).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 3)
    }
}

private struct LibraryDetail: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let library = model.library
        if let draft = library.draft {
            MemoryEditor(draft: draft)
                .id(draft.id)
        } else if let item = library.item(library.selection) {
            MemoryReader(item: item)
        } else {
            ContentUnavailableView("Select an item", systemImage: "doc.text.magnifyingglass",
                                   description: Text(model.memoryStatus))
        }
    }
}

import SwiftUI
import ZCore

/// The personal library: search (meaning + keywords), kind filter, import (txt / md / pdf), edit, delete, profile.
struct LibraryScreen: View {
    @Environment(AppModel.self) private var model
    @State private var importing = false
    @State private var showProfile = false

    var body: some View {
        @Bindable var library = model.library
        NavigationStack {
            Group {
                if !library.isAvailable {
                    ContentUnavailableView("Library unavailable", systemImage: "externaldrive.badge.xmark",
                                           description: Text(model.memoryStatus))
                } else {
                    List {
                        if let status = library.importStatus {
                            Text(status).font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(library.items) { item in
                            NavigationLink {
                                MemoryReader(item: item)
                            } label: {
                                LibraryRow(item: item, score: library.scores[item.id])
                            }
                            .swipeActions {
                                Button(role: .destructive) {
                                    Task { await model.library.delete(item.id) }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                Button {
                                    library.edit(item)
                                } label: {
                                    Label("Edit", systemImage: "pencil")
                                }
                                .tint(.blue)
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
                    .refreshable { await model.library.reload() }
                }
            }
            .navigationTitle("Library")
            .searchable(text: $library.query, prompt: "Search the library")
            .onSubmit(of: .search) { Task { await model.library.reload() } }
            .onChange(of: library.query) {
                if library.query.isEmpty { Task { await model.library.reload() } }
            }
            .onChange(of: library.kindFilter) { Task { await model.library.reload() } }
            .task { await model.library.reload() }
            .toolbar { toolbar(library) }
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
            .sheet(item: $library.draft) { draft in
                MemoryEditor(draft: draft)
            }
            .alert("Library", isPresented: Binding(get: { model.library.errorMessage != nil },
                                                   set: { if !$0 { model.library.errorMessage = nil } })) {
                Button("OK") { model.library.errorMessage = nil }
            } message: {
                Text(model.library.errorMessage ?? "")
            }
        }
    }

    @ToolbarContentBuilder
    private func toolbar(_ library: LibraryModel) -> some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                Picker("Kind", selection: Binding(get: { library.kindFilter }, set: { library.kindFilter = $0 })) {
                    Text("All kinds").tag(MemoryKind?.none)
                    ForEach(LibraryModel.listedKinds + [.chunk], id: \.self) { kind in
                        Label("\(kind.title) (\(library.counts[kind] ?? 0))", systemImage: kind.systemImage)
                            .tag(MemoryKind?.some(kind))
                    }
                }
            } label: {
                Label(library.kindFilter?.title ?? "All kinds", systemImage: "line.3.horizontal.decrease.circle")
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            if library.isBusy { ProgressView() }
            Button { showProfile = true } label: { Label("Profile", systemImage: "person.crop.circle") }
            Menu {
                ForEach(LibraryModel.listedKinds, id: \.self) { kind in
                    Button { library.newItem(kind: kind) } label: { Label(kind.title, systemImage: kind.systemImage) }
                }
                Divider()
                Button { importing = true } label: { Label("Import files (txt, md, pdf)", systemImage: "square.and.arrow.down") }
            } label: {
                Label("Add", systemImage: "plus")
            }
            .disabled(!library.isAvailable)
        }
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
                ForEach(item.tags.prefix(3), id: \.self) { tag in
                    Text(tag).font(.caption2).padding(.horizontal, 5).background(Capsule().fill(Color.secondary.opacity(0.12)))
                }
                Spacer()
                Text(item.updatedAt.formatted(date: .abbreviated, time: .omitted)).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}

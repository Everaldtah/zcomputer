import SwiftUI
import ZCore

/// Read-only view of a library item with Edit / Delete.
struct MemoryReader: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var item: MemoryItem

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Label(item.kind.title, systemImage: item.kind.systemImage).foregroundStyle(.secondary)
                Text(item.title.isEmpty ? "Untitled" : item.title).font(.title2.weight(.semibold))
                    .textSelection(.enabled)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Source: \(item.source)")
                    Text("Updated \(item.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                    if !item.tags.isEmpty { Text("Tags: \(item.tags.joined(separator: ", "))") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Text(item.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Edit") { model.library.edit(item) }
                Button(role: .destructive) {
                    let id = item.id
                    Task {
                        await model.library.delete(id)
                        dismiss()
                    }
                } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel("Delete")
            }
        }
    }
}

/// Editor for a new or existing item (a sheet).
struct MemoryEditor: View {
    @Environment(AppModel.self) private var model
    @State private var draft: MemoryDraft

    init(draft: MemoryDraft) {
        _draft = State(initialValue: draft)
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Kind", selection: $draft.kind) {
                    ForEach(LibraryModel.listedKinds, id: \.self) { kind in
                        Label(kind.title, systemImage: kind.systemImage).tag(kind)
                    }
                }
                TextField("Title", text: $draft.title)
                TextField("Tags (comma separated)", text: $draft.tags)
                    .textInputAutocapitalization(.never)
                Section("Text") {
                    TextEditor(text: $draft.text)
                        .frame(minHeight: 260)
                }
            }
            .navigationTitle(draft.isNew ? "New item" : "Edit item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { model.library.draft = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let current = draft
                        Task { await model.library.save(current) }
                    }
                }
            }
        }
    }
}

/// Profile facts and agent preferences: what every agent's system prompt starts from.
struct ProfileEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var newText = ""
    @State private var newKind: MemoryKind = .profile

    var body: some View {
        let library = model.library
        NavigationStack {
            List {
                Section {
                    Text("Short facts about you (“My name is Everald”, “I use Debian”) and how agents should behave "
                         + "(“Ask before installing packages”). Agents read these before every task.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Section("Saved") {
                    if library.profile.isEmpty {
                        Text("Nothing yet.").foregroundStyle(.secondary)
                    }
                    ForEach(library.profile) { item in
                        Label(item.text.isEmpty ? item.title : item.text, systemImage: item.kind.systemImage)
                            .textSelection(.enabled)
                    }
                    .onDelete { offsets in
                        let ids = offsets.map { library.profile[$0].id }
                        Task { for id in ids { await model.library.delete(id) } }
                    }
                }
                Section("Add") {
                    Picker("Kind", selection: $newKind) {
                        Text("Profile").tag(MemoryKind.profile)
                        Text("Preference").tag(MemoryKind.preference)
                    }
                    .pickerStyle(.segmented)
                    TextField("A fact or preference", text: $newText, axis: .vertical)
                        .onSubmit(add)
                    Button("Add", action: add)
                        .disabled(newText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationTitle("Profile and preferences")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task { await model.library.reload() }
        }
    }

    private func add() {
        let text = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        var draft = MemoryDraft(kind: newKind)
        draft.title = Format.clip(text, 60)
        draft.text = text
        newText = ""
        let library = model.library
        let item = draft
        Task {
            await library.save(item)
            library.draft = nil
        }
    }
}

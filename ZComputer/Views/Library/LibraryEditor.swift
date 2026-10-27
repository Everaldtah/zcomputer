import SwiftUI
import ZCore

/// Read-only view of a library item with Edit / Delete.
struct MemoryReader: View {
    @Environment(AppModel.self) private var model
    var item: MemoryItem

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label(item.kind.title, systemImage: item.kind.systemImage).foregroundStyle(.secondary)
                Spacer()
                Button("Edit") { model.library.edit(item) }
                Button("Delete", role: .destructive) { Task { await model.library.delete(item.id) } }
            }
            .padding(12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(item.title.isEmpty ? "Untitled" : item.title).font(.title2.weight(.semibold))
                        .textSelection(.enabled)
                    HStack(spacing: 12) {
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
        }
    }
}

/// Editor for a new or existing item.
struct MemoryEditor: View {
    @Environment(AppModel.self) private var model
    @State private var draft: MemoryDraft

    init(draft: MemoryDraft) {
        _draft = State(initialValue: draft)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(draft.isNew ? "New item" : "Edit item").font(.headline)
                Spacer()
                Button("Cancel") { model.library.draft = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    let current = draft
                    Task { await model.library.save(current) }
                }
                .keyboardShortcut("s", modifiers: .command)
            }
            .padding(12)
            Divider()
            Form {
                Picker("Kind", selection: $draft.kind) {
                    ForEach(LibraryModel.listedKinds, id: \.self) { kind in
                        Label(kind.title, systemImage: kind.systemImage).tag(kind)
                    }
                }
                TextField("Title", text: $draft.title)
                TextField("Tags (comma separated)", text: $draft.tags)
                Section("Text") {
                    TextEditor(text: $draft.text)
                        .font(.body)
                        .frame(minHeight: 260)
                }
            }
            .formStyle(.grouped)
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
        VStack(alignment: .leading, spacing: 12) {
            Text("Profile and preferences").font(.title2.weight(.semibold))
            Text("Short facts about you (“My name is Everald”, “I use Debian”) and how agents should behave "
                 + "(“Ask before installing packages”). Agents read these before every task.")
                .foregroundStyle(.secondary)
            List {
                ForEach(library.profile) { item in
                    HStack(alignment: .top) {
                        Image(systemName: item.kind.systemImage).foregroundStyle(.secondary)
                        Text(item.text.isEmpty ? item.title : item.text).textSelection(.enabled)
                        Spacer()
                        Button(role: .destructive) {
                            Task { await model.library.delete(item.id) }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            .frame(minHeight: 220)
            HStack {
                Picker("", selection: $newKind) {
                    Text("Profile").tag(MemoryKind.profile)
                    Text("Preference").tag(MemoryKind.preference)
                }
                .labelsHidden()
                .frame(width: 120)
                TextField("Add a fact or preference", text: $newText)
                    .onSubmit(add)
                Button("Add", action: add)
                    .disabled(newText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 480)
        .task { await model.library.reload() }
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

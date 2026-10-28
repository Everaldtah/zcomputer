import SwiftUI
import UIKit

/// What a new machine boots.
enum MachineCreateSource: Identifiable {
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
        case .image(let image): return image.fixedMemoryMB ?? image.defaultMemoryMB
        case .iso: return 512
        }
    }

    /// Instant-start images restore a saved state taken with exactly this much RAM.
    var fixedMemoryMB: Int? {
        if case .image(let image) = self { return image.fixedMemoryMB }
        return nil
    }
}

/// Name and memory for a new machine, with the engine's limits (ZEmu: `EmuSpec.recommendedMaxMemoryMBOnPhone`,
/// `maxMemoryMBOnPhone`) and its `EmuSpec.validate(isPhone:)` messages.
struct CreateMachineSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let source: MachineCreateSource
    var onCreated: () -> Void
    @State private var name = ""
    @State private var memoryMB = 512

    private var isPhone: Bool { UIDevice.current.userInterfaceIdiom == .phone }

    var body: some View {
        let engine = model.machines.engine
        let limits = engine.memoryLimits
        let ceiling = isPhone ? limits.maxOnPhoneMB : limits.maxMB
        let problems = engine.validate(memoryMB: memoryMB, isPhone: isPhone)
        NavigationStack {
            Form {
                TextField(source.title, text: $name)
                if let fixed = source.fixedMemoryMB {
                    LabeledContent("Memory", value: "\(fixed) MB")
                    Text("Fixed: the saved state this machine starts from was taken with \(fixed) MB.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Stepper("Memory: \(memoryMB) MB", value: $memoryMB, in: 128...max(128, ceiling), step: 128)
                    if isPhone && memoryMB > limits.recommendedOnPhoneMB {
                        Label("More than \(limits.recommendedOnPhoneMB) MB can make iOS end the emulator on an "
                              + "iPhone (saving a state briefly needs a second copy).", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                ForEach(problems, id: \.self) { problem in
                    Label(problem, systemImage: "xmark.octagon").font(.caption).foregroundStyle(.red)
                }
                Section {
                    Text("The emulated PC's RAM lives in WebKit's memory, which iOS caps at about 1–1.5 GB on "
                         + "iPhones. \(limits.recommendedOnPhoneMB) MB suits a light desktop; the most an iPhone "
                         + "allows here is \(limits.maxOnPhoneMB) MB.")
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
                    .disabled(!problems.isEmpty)
                }
            }
            .onAppear { memoryMB = min(source.defaultMemoryMB, ceiling) }
        }
        .presentationDetents([.medium, .large])
    }
}

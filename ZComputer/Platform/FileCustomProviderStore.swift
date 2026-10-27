import Foundation
import ZCore
import ZProviders

/// User-added (OpenAI-compatible) providers, kept as JSON in Application Support/ZComputer/custom-providers.json.
/// Their API keys live in the Keychain like every other provider's.
actor FileCustomProviderStore: CustomProviderStore {
    let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    static func standard() -> FileCustomProviderStore {
        FileCustomProviderStore(fileURL: AppPaths.supportDirectory.appendingPathComponent("custom-providers.json"))
    }

    func customProviders() async throws -> [ProviderDescriptor] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode([ProviderDescriptor].self, from: data)
    }

    func save(_ provider: ProviderDescriptor) async throws {
        var all = try await customProviders()
        if let index = all.firstIndex(where: { $0.id == provider.id }) {
            all[index] = provider
        } else {
            all.append(provider)
        }
        try write(all)
    }

    func remove(_ id: ProviderID) async throws {
        var all = try await customProviders()
        all.removeAll { $0.id == id }
        try write(all)
    }

    private func write(_ providers: [ProviderDescriptor]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(providers).write(to: fileURL, options: .atomic)
    }
}

/// Where the app keeps its files (inside the sandbox container).
enum AppPaths {
    /// `~/Library/Application Support/ZComputer` (created on first use).
    static var supportDirectory: URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("ZComputer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The personal library database.
    static var libraryDatabase: URL {
        supportDirectory.appendingPathComponent("Library", isDirectory: true).appendingPathComponent("library.sqlite")
    }

    /// Scratch space for agent runs.
    static var agentScratch: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("zcomputer-agent", isDirectory: true)
    }

    /// The bundled guest-agent binaries (`Contents/Resources/zguest`), when the build has them.
    static var guestAgentDirectory: URL? {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("zguest", isDirectory: true) else { return nil }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.contains(where: { $0.hasPrefix("zguest-linux-") }) ? dir : nil
    }
}

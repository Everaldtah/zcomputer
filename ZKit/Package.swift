// swift-tools-version: 6.0
// ZKit: the platform-independent core of Z Computer. Every target here must build and test on Linux
// (swift:6.x container in CI) as well as macOS; Apple-only code goes behind `#if canImport(...)`.
import PackageDescription

// SQLite comes from the SDK on Apple platforms (link "sqlite3" in the module map). pkg-config / Homebrew
// are only consulted on Linux: with `.brew` on macOS, SwiftPM links Homebrew's libsqlite3.dylib, which
// breaks the x86_64 link in CI and would not exist on users' Macs.
#if os(Linux)
let csqlite: Target = .systemLibrary(name: "CSQLite", path: "Sources/CSQLite", pkgConfig: "sqlite3",
                                     providers: [.apt(["libsqlite3-dev"])])
#else
let csqlite: Target = .systemLibrary(name: "CSQLite", path: "Sources/CSQLite")
#endif

let package = Package(
    name: "ZKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ZCore", targets: ["ZCore"]),
        .library(name: "ZProviders", targets: ["ZProviders"]),
        .library(name: "ZAgent", targets: ["ZAgent"]),
        .library(name: "ZMemory", targets: ["ZMemory"]),
        .library(name: "ZTeam", targets: ["ZTeam"]),
        .library(name: "ZLocal", targets: ["ZLocal"]),
    ],
    targets: [
        .target(name: "ZCore"),
        .target(name: "ZProviders", dependencies: ["ZCore"], resources: [.copy("Resources/providers.json")]),
        .target(name: "ZAgent", dependencies: ["ZCore", "ZProviders", "ZMemory"]),
        csqlite,
        .target(name: "ZMemory", dependencies: ["ZCore", "CSQLite"]),
        .target(name: "ZTeam", dependencies: ["ZCore", "ZAgent", "ZMemory", "ZProviders"]),
        .target(name: "ZLocal", dependencies: ["ZCore", "ZProviders"]),
        .testTarget(name: "ZCoreTests", dependencies: ["ZCore"]),
        .testTarget(name: "ZProvidersTests", dependencies: ["ZProviders"]),
        .testTarget(name: "ZAgentTests", dependencies: ["ZAgent"]),
        .testTarget(name: "ZMemoryTests", dependencies: ["ZMemory"]),
        .testTarget(name: "ZTeamTests", dependencies: ["ZTeam"]),
        .testTarget(name: "ZLocalTests", dependencies: ["ZLocal"]),
    ],
    swiftLanguageModes: [.v6]
)

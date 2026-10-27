// swift-tools-version: 6.0
// ZVM: the macOS-only virtual machine layer of Z Computer (Apple Virtualization.framework).
// It builds and runs Linux / macOS guests, captures the guest display, injects input, talks to the
// in-guest agent (`zguest`, see guest-agent/PROTOCOL.md) and exposes all of it as a ZCore `ComputerSurface`.
// No third-party dependencies; public API only (Mac App Store).
import PackageDescription

let package = Package(
    name: "ZVM",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ZVM", targets: ["ZVM"]),
    ],
    dependencies: [
        .package(path: "../ZKit"),
    ],
    targets: [
        .target(
            name: "ZVM",
            dependencies: [.product(name: "ZCore", package: "ZKit")]
        ),
        .testTarget(
            name: "ZVMTests",
            dependencies: ["ZVM", .product(name: "ZCore", package: "ZKit")]
        ),
    ],
    swiftLanguageModes: [.v6]
)

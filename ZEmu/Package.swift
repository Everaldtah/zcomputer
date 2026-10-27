// swift-tools-version: 6.0
// ZEmu: runs real 32-bit x86 Linux ISOs / disk images inside a WKWebView with the v86 emulator
// (x86 -> WebAssembly JIT; WebKit JIT-compiles the WebAssembly, which is the App-Store-legal way to run a
// PC emulator at usable speed on iPhone). It exposes the machine as a ZCore `ComputerSurface`, like ZVM does
// for Apple's Virtualization.framework, so ZAgent drives both the same way. iOS 17+ and macOS 15+.
// No third-party Swift packages; public API only. v86 (BSD-2-Clause) and SeaBIOS/VGABIOS (LGPL-3.0) are
// vendored as resources, see Sources/ZEmu/Resources/v86/VERSION.
import PackageDescription

let package = Package(
    name: "ZEmu",
    platforms: [.iOS(.v17), .macOS(.v15)],
    products: [
        .library(name: "ZEmu", targets: ["ZEmu"]),
    ],
    dependencies: [
        .package(path: "../ZKit"),
    ],
    targets: [
        .target(
            name: "ZEmu",
            dependencies: [.product(name: "ZCore", package: "ZKit")],
            resources: [
                .copy("Resources/v86"),
                .copy("Resources/host"),
                .copy("Resources/images-x86.json"),
            ]
        ),
        .testTarget(
            name: "ZEmuTests",
            dependencies: ["ZEmu", .product(name: "ZCore", package: "ZKit")]
        ),
    ],
    swiftLanguageModes: [.v6]
)

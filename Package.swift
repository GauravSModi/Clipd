// swift-tools-version: 5.9
import PackageDescription
import Foundation

// The CMake-built static archives (libclipd_capi.a + libclipd_core.a) live in
// build/ next to this manifest. Resolve an absolute -L path from the manifest
// location so `swift test` links regardless of the invoking directory.
let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

let package = Package(
    name: "ClipdKit",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ClipdKit", targets: ["ClipdKit"]),
    ],
    targets: [
        // Clang module exposing the flat C API (include/clipd.h) to Swift.
        // Header-only: the symbols come from the static archives linked below.
        .systemLibrary(name: "CClipd", path: "shell/CClipd"),

        // The thin, UI-free bridge + shell logic. Links the C++ core via the
        // CMake archives; the C++ runtime is pulled in with -lc++.
        .target(
            name: "ClipdKit",
            dependencies: ["CClipd"],
            path: "shell/ClipdKit",
            linkerSettings: [
                .unsafeFlags([
                    "-L\(packageDir)/build",
                    "-lclipd_capi",
                    "-lclipd_core",
                    "-lc++",
                ]),
            ]
        ),

        .testTarget(
            name: "ClipdKitTests",
            dependencies: ["ClipdKit"],
            path: "shell/ClipdKitTests"
        ),
    ]
)

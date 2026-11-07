// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "MacPilot",
    platforms: [.macOS(.v14)],
    targets: [
        // The menu bar app (panel, settings, Claude session, voice, overlay).
        .executableTarget(
            name: "MacPilot",
            dependencies: ["CSherpaOnnx"],
            path: "Sources/MacPilot"
        ),
        // sherpa-onnx C API types for the Kokoro voice (library loaded at runtime).
        .target(
            name: "CSherpaOnnx",
            path: "Sources/CSherpaOnnx"
        ),
        // Command-line helper Claude calls to control the Mac (AX, input, screenshots).
        .executableTarget(
            name: "mpctl",
            path: "Sources/mpctl"
        ),
    ]
)

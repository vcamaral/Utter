// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Utter",
    platforms: [.macOS(.v14)],
    targets: [
        .systemLibrary(name: "CWhisper", path: "Sources/CWhisper"),
        .executableTarget(
            name: "Utter",
            dependencies: ["CWhisper"],
            path: "Sources/Utter",
            linkerSettings: [
                // Static libraries from scripts/build-whisper.sh, so the app doesn't need Homebrew.
                .unsafeFlags([
                    "-Lvendor/whisper/lib",
                    "-lwhisper", "-lggml", "-lggml-base", "-lggml-cpu", "-lggml-metal", "-lggml-blas",
                    "-lc++",
                ]),
                .linkedFramework("Accelerate"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("Foundation"),
            ]
        )
    ]
)

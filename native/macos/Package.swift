// swift-tools-version: 6.0
import PackageDescription
import Foundation
// The wrapper resolves Cargo metadata; direct SwiftPM builds keep the default.
let coreLibraryDirectory = ProcessInfo.processInfo.environment["SOUNDQ_CORE_LIBRARY_DIR"] ?? "../core/target/release"
let package = Package(
    name: "SoundQNative",
    platforms: [.macOS(.v14)],
    targets: [
        .systemLibrary(name: "SoundQCore", path: "CBridge"),
        .executableTarget(name: "SoundQNative", dependencies: ["SoundQCore"],
                          path: "Sources", resources: [.copy("Resources")], linkerSettings: [
                            .unsafeFlags(["-L", coreLibraryDirectory, "-lsoundq_core",
                                          "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
                          ])
    ]
)

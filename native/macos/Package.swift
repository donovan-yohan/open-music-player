// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "SoundQNative",
    platforms: [.macOS(.v14)],
    targets: [
        .systemLibrary(name: "SoundQCore", path: "CBridge"),
        .executableTarget(name: "SoundQNative", dependencies: ["SoundQCore"],
                          path: "Sources", linkerSettings: [
                            .unsafeFlags(["-L", "../core/target/release", "-lsoundq_core",
                                          "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
                          ])
    ]
)

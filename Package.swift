// swift-tools-version:5.9
import Foundation
import PackageDescription

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
// Generated paths are excluded only when they exist: SwiftPM warns about an
// exclude that names nothing, which a fresh clone would otherwise hit for
// `dist`. Note that SwiftPM caches the evaluated manifest, so this condition
// is frozen until something else invalidates it — removing `dist` after a
// build that saw it produces "Invalid Exclude: File not found" until the
// manifest is re-evaluated. verify.sh creates the directory before building
// for exactly that reason.
let optionalGeneratedExcludes = [".DS_Store", "dist"].filter {
    FileManager.default.fileExists(atPath: packageRoot.appendingPathComponent($0).path)
}

let package = Package(
    name: "Antarium",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "AntariumHarnessSDK", targets: ["AntariumHarnessSDK"]),
    ],
    targets: [
        .target(name: "AntariumHarnessSDK", path: "Sources/AntariumHarnessSDK"),
        .executableTarget(
            name: "Antarium",
            dependencies: ["AntariumHarnessSDK"],
            path: ".",
            exclude: [
                ".gitignore", ".github", "AGENTS.md", "CLAUDE.md",
                "CONTRIBUTING.md", "LICENSE", "Package.swift", "README.md", "Roadmap.md",
                "SECURITY.md", "build.sh", "test.sh", "verify.sh", "mutate.sh", "mutations.txt",
                "tools", "Tests", "docs",
                "Sources/AntariumHarnessSDK",
                "Resources/AppIcon.icns",
            ] + optionalGeneratedExcludes,
            sources: ["Sources/Antarium"],
            resources: [
                .copy("Resources/pricing.json"),
                .copy("Resources/harness.schema.json"),
                .copy("Resources/harnesses"),
                .copy("Resources/harness-fixtures"),
                .copy("Resources/quota-fixtures"),
                .copy("Resources/marks"),
                .copy("Resources/logo"),
            ]
        ),
        .testTarget(
            name: "AntariumTests",
            dependencies: ["Antarium", "AntariumHarnessSDK"],
            path: "Tests/AntariumTests"
        )
    ]
)

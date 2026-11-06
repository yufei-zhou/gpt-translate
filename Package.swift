// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "GPTTranslate",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "GPTTranslate", path: "Sources/GPTTranslate")
    ]
)

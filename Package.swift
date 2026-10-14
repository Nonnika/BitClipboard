// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BitClipboard",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "BitClipboard", targets: ["BitClipboard"])],
    targets: [
        .target(name: "BitClipboardCore"),
        .executableTarget(name: "BitClipboard", dependencies: ["BitClipboardCore"], resources: [.copy("SemanticRuntime")]),
        .testTarget(name: "BitClipboardCoreTests", dependencies: ["BitClipboardCore"])
    ]
)

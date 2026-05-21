// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "PromptKeyboard",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "PromptKeyboard",
            path: "Sources/PromptKeyboard",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)

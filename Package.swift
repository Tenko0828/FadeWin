// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FadeWin",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "FadeWin",
            path: "Sources/FadeWin"
        )
    ]
)

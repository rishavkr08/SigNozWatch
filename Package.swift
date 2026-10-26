// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SigNozWatch",
    platforms: [.macOS(.v14)],
    targets: [.executableTarget(name: "SigNozWatch", path: "Sources/SigNozWatch")]
)

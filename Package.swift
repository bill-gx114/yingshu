// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "YingShu",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "YingShu", targets: ["YingShu"])],
    targets: [.executableTarget(name: "YingShu", path: "Sources/YingShu")]
)

// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "PadBridge",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "PadBridge", targets: ["PadBridge"])],
    targets: [
        .target(name: "VirtualDisplayBridge", cSettings: [.unsafeFlags(["-fobjc-arc"])],
                linkerSettings: [.linkedFramework("CoreGraphics")]),
        .target(name: "PadBridgeNetwork"),
        .executableTarget(name: "PadBridge", dependencies: ["VirtualDisplayBridge", "PadBridgeNetwork"]),
        .testTarget(name: "PadBridgeTests", dependencies: ["PadBridge", "PadBridgeNetwork"])
    ]
)

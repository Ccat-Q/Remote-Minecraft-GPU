// swift-tools-version: 6.0
import PackageDescription

// The renderer implementation is added as source-compatible C/C++ targets
// after virglrenderer-ios and ANGLE are pinned. Keeping the envelope in a
// Swift package makes the wire contract compile in GitHub Actions now.
let package = Package(
    name: "RemoteGPU",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "RemoteGPUProtocol", targets: ["RemoteGPUProtocol"])
    ],
    targets: [
        .target(name: "RemoteGPUProtocol", path: "RemoteGPU", sources: ["Protocol.swift", "QUICRenderConnection.swift", "RenderCoordinator.swift"]),
        .testTarget(name: "RemoteGPUProtocolTests", dependencies: ["RemoteGPUProtocol"], path: "Tests", sources: ["RemoteGPUProtocolTests.swift"])
    ]
)

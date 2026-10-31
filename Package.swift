// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "PageKit",
    platforms: [.iOS(.v15), .macOS(.v12), .tvOS(.v15), .watchOS(.v8)],
    products: [
        .library(name: "PageKit", targets: ["PageKit"]),
    ],
    dependencies: [],   // zero third-party code, by design
    targets: [
        .target(name: "PageKit", resources: [.copy("PrivacyInfo.xcprivacy")]),
        .testTarget(name: "PageKitTests", dependencies: ["PageKit"]),
    ]
)

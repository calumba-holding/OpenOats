// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "OnTheSpot",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "OnTheSpot",
            path: "Sources/OnTheSpot",
            exclude: ["Info.plist", "OnTheSpot.entitlements", "Assets"]
        ),
    ]
)

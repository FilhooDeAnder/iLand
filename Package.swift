// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "iLand",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "iLand", targets: ["iLand"])
    ],
    targets: [
        .executableTarget(
            name: "iLand",
            path: "Sources"
        )
    ]
)

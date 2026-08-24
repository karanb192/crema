// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Crema",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "crema", targets: ["Crema"]),
        .library(name: "CremaCore", targets: ["CremaCore"]),
    ],
    targets: [
        // Pure engine: power assertions, process scanning, turn detection,
        // rules, and the power-decision function. No SwiftUI, fully testable.
        .target(name: "CremaCore"),
        // The menu bar app. Thin SwiftUI layer over CremaCore.
        .executableTarget(
            name: "Crema",
            dependencies: ["CremaCore"]
        ),
        .testTarget(
            name: "CremaCoreTests",
            dependencies: ["CremaCore"]
        ),
    ]
)

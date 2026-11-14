// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "OpenNTFS",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "OpenNTFS",
            path: "Sources/OpenNTFS",
            linkerSettings: [
                .linkedFramework("DiskArbitration"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ]
)

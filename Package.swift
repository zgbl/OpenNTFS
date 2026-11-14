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
                // FSKit 仅 macOS 15.4+ 才有：弱链接，老系统上也能启动（会自动改用内核扩展方式）
                .unsafeFlags(["-Xlinker", "-weak_framework", "-Xlinker", "FSKit"]),
            ]
        )
    ]
)

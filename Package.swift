// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FatCatPomodoro",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "FatCatPomodoro", targets: ["FatCatPomodoro"])
    ],
    dependencies: [
        .package(url: "https://github.com/GooseyGustav/asifthatworks-licensekit.git", branch: "main")
    ],
    targets: [
        .executableTarget(
            name: "FatCatPomodoro",
            dependencies: [
                .product(name: "LicenseKit", package: "asifthatworks-licensekit")
            ],
            path: "Sources/FatCatPomodoro",
            exclude: ["Info.plist"],
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/FatCatPomodoro/Info.plist"
                ])
            ]
        )
    ]
)

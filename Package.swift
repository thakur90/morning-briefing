// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Briefing",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "briefing", targets: ["briefing"]),
        .library(name: "BriefingCore", targets: ["BriefingCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .target(name: "BriefingCore"),
        .executableTarget(
            name: "briefing",
            dependencies: [
                "BriefingCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            linkerSettings: [
                // Embed Info.plist so macOS can show Calendar/Reminders/Location
                // permission prompts for this command-line binary (design §8).
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "\(Context.packageDirectory)/Support/Info.plist",
                ]),
            ]
        ),
    ]
)

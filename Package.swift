// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TravelMediaManager",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "TravelArchiveCore", targets: ["TravelArchiveCore"]),
        .executable(name: "TravelMediaManager", targets: ["TravelMediaManager"]),
        .executable(name: "TravelArchiveCheck", targets: ["TravelArchiveCheck"])
    ],
    targets: [
        .target(name: "TravelArchiveCore"),
        .executableTarget(name: "TravelMediaManager", dependencies: ["TravelArchiveCore"]),
        .executableTarget(name: "TravelArchiveCheck", dependencies: ["TravelArchiveCore"]),
        .testTarget(name: "TravelArchiveCoreTests", dependencies: ["TravelArchiveCore"])
    ]
)

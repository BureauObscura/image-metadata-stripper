// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "ImageMetadataStripper",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "MetadataStripperCore",
            targets: ["MetadataStripperCore"]
        ),
        .executable(
            name: "ImageMetadataStripper",
            targets: ["MetadataStripperApp"]
        )
    ],
    targets: [
        .target(
            name: "MetadataStripperCore",
            linkerSettings: [
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ImageIO")
            ]
        ),
        .executableTarget(
            name: "MetadataStripperApp",
            dependencies: ["MetadataStripperCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("UniformTypeIdentifiers")
            ]
        ),
        .testTarget(
            name: "MetadataStripperCoreTests",
            dependencies: ["MetadataStripperCore"],
            linkerSettings: [
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ImageIO")
            ]
        )
    ]
)

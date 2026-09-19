// swift-tools-version: 6.0
import PackageDescription

let root = Context.packageDirectory

let package = Package(
    name: "PoC",
    platforms: [
        .iOS(.v16),
    ],
    products: [
        // xtool picks the single automatic (static) library product as the app.
        .library(
            name: "PoC",
            targets: ["PoC"]
        ),
    ],
    dependencies: [
        .package(path: "Vendor"),
    ],
    targets: [
        .target(
            name: "PoC",
            dependencies: [
                .product(name: "Minimuxer", package: "Vendor"),
            ],
            path: ".",
            exclude: [
                "layout",
                "NativeLibs",
                "scripts",
                ".github",
                "Vendor",
            ],
            sources: [
                "Nugget/NuggetApp.swift",
                "Nugget/AppPackage.swift",
                "Nugget/Tunnel.swift",
                "Nugget/Views/PoCView.swift",
                "Nugget/Extensions/Alert++.swift",
                "Nugget/Extensions/Extensions.swift",

                // Engine core — see Nugget/Core/PoCEngine.swift for the layering.
                // Adding a file here also requires re-running
                // scripts/relink-core-sources.py for PoC.xcodeproj.
                "Nugget/Core/AppPaths.swift",
                "Nugget/Core/Logging.swift",
                "Nugget/Core/TransportFailure.swift",
                "Nugget/Core/AsyncRacing.swift",
                "Nugget/Core/RustLog.swift",
                "Nugget/Core/WireCensus.swift",
                "Nugget/Core/ProgressPulse.swift",
                "Nugget/Core/StallGuard.swift",
                "Nugget/Core/ChannelRecovery.swift",
                "Nugget/Core/ManifestStore.swift",
                "Nugget/Core/MBFileBlob.swift",
                "Nugget/Core/HostManifests.swift",
                "Nugget/Core/BackupInjector.swift",
                "Nugget/Core/ProtectiveBackup.swift",
                "Nugget/Core/RestoreRunner.swift",
                "Nugget/Core/Diagnostics.swift",
                "Nugget/Core/InstProxy.swift",
                "Nugget/Core/PoCEngine.swift",

                "Nugget/SwiftNIO/_NIOBase64/Base64.swift",
                "Nugget/SwiftNIO/NIOFoundationCompat/ByteBuffer-foundation.swift",
                "Nugget/SwiftNIO/NIOCore/ByteBuffer-aux.swift",
                "Nugget/SwiftNIO/NIOCore/ByteBuffer-conversions.swift",
                "Nugget/SwiftNIO/NIOCore/ByteBuffer-core.swift",
                "Nugget/SwiftNIO/NIOCore/ByteBuffer-hexdump.swift",
                "Nugget/SwiftNIO/NIOCore/ByteBuffer-int.swift",
                "Nugget/SwiftNIO/NIOCore/ByteBuffer-lengthPrefix.swift",
                "Nugget/SwiftNIO/NIOCore/ByteBuffer-multi-int.swift",
                "Nugget/SwiftNIO/NIOCore/ByteBuffer-views.swift",
                "Nugget/SwiftNIO/NIOCore/CircularBuffer.swift",
                "Nugget/SwiftNIO/NIOCore/IntegerBitPacking.swift",
                "Nugget/SwiftNIO/NIOCore/IntegerTypes.swift",
                "Nugget/SwiftNIO/NIOPosix/PointerHelpers.swift",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ],
            linkerSettings: [
                .linkedFramework("UIKit"),
                .linkedLibrary("sqlite3"),
            ]
        ),
    ]
)

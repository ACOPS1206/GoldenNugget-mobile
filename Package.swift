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
                "Nugget/Sparserestore/Backup.swift",
                "Nugget/Sparserestore/InstProxy.swift",
                "Nugget/Sparserestore/MBDB.swift",
                "Nugget/Sparserestore/PoCEngine.swift",
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
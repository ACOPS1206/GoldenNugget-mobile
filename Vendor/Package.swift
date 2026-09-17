// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Minimuxer",
    platforms: [
        .iOS(.v14),
        .macOS(.v11),
        .tvOS(.v14)
    ],
    products: [
        .library(
            name: "Minimuxer",
            targets: ["Minimuxer"]
        )
    ],
    dependencies: [
        .package(path: "MinimuxerCommon"),
        .package(path: "MinimuxerGateway")
    ],
    targets: [
        // Dynamic framework wrapping of em_proxy. Its Rust std copy of
        // `rust_eh_personality` would collide with libidevice_ffi's at final
        // link if both were static, so em_proxy ships as a dylib.
        .binaryTarget(
            name: "EMProxy",
            path: "EMProxy-dynamic.xcframework"
        ),

        // Local vendored copy of ZIPFoundation (its upstream manifest evaluates
        // `canImport(Compression)` on the build host, which would pull the
        // pkg-config CZLib/zlib path instead of Apple's Compression framework).
        .target(
            name: "ZIPFoundation",
            path: "ZIPFoundation",
            exclude: ["Sources/Resources"]
        ),

        // Main SPM target
        .target(
            name: "Minimuxer",
            dependencies: [
                .product(name: "MinimuxerCommon", package: "MinimuxerCommon"),
                .product(name: "DeviceGatewayAPI", package: "MinimuxerGateway"),
                .product(name: "IdeviceGateway", package: "MinimuxerGateway"),
                "EMProxy",
                "ZIPFoundation"
            ],
            path: "MinimuxerSources"
        )
    ],
    cLanguageStandard: .gnu11,
    cxxLanguageStandard: .gnucxx14
)
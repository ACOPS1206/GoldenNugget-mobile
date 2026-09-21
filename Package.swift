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
                "scripts",
                ".github",
                "Vendor",
            ],
            // One entry, not a hand-maintained list.  The list that used to live
            // here had already drifted — it was missing Nugget/Core/InFlightCall
            // .swift — and it had to be kept in step with project.pbxproj by
            // hand.  Naming the directory means SwiftPM picks up new files on
            // its own, and it is the same expression project.yml uses
            // (`- path: Nugget`).
            //
            // PoC.xcodeproj/project.pbxproj still enumerates files (Xcode has no
            // directory reference for sources), so it is reconciled from this
            // target's resolved source list by scripts/sync-pbxproj-sources.py.
            sources: ["Nugget"],
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

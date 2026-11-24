// swift-tools-version:6.1
// GRDB 7.11.1 (https://github.com/groue/GRDB.swift, tag v7.11.1) built against SQLCipher. Swift Package Manager
// can only build GRDB with SQLCipher from a modified copy, so `GRDB/` and `Sources/GRDBSQLCipher/` are the upstream
// files unchanged, without `GRDB/Documentation.docc`, and this manifest is upstream's with its "GRDB+SQLCipher" steps
// applied and its test target removed. To update, replace both folders with those of a newer tag and reapply the
// steps from that tag's Package.swift.

import PackageDescription

let package = Package(
    name: "GRDB",
    platforms: [
        .macOS(.v10_15),
    ],
    products: [
        .library(name: "GRDB", targets: ["GRDB"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sqlcipher/SQLCipher.swift.git", from: "4.20.0"),
    ],
    targets: [
        .target(
            name: "GRDBSQLCipher",
            dependencies: [.product(name: "SQLCipher", package: "SQLCipher.swift")]
        ),
        .target(
            name: "GRDB",
            dependencies: [
                .product(name: "SQLCipher", package: "SQLCipher.swift"),
                .target(name: "GRDBSQLCipher"),
            ],
            path: "GRDB",
            resources: [.copy("PrivacyInfo.xcprivacy")],
            cSettings: [.define("SQLITE_HAS_CODEC")],
            swiftSettings: [
                .define("SQLITE_ENABLE_FTS5"),
                .define("SQLITE_ENABLE_SNAPSHOT"),
                .define("SQLITE_HAS_CODEC"),
                .define("SQLCipher"),
                .enableUpcomingFeature("MemberImportVisibility"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)

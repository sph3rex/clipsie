// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Clipsie",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "CSQLCipher",
            path: "Sources/CSQLCipher",
            exclude: ["LICENSE.md", "VERSION"],
            cSettings: [
                .define("SQLITE_HAS_CODEC"),
                .define("SQLCIPHER_CRYPTO_CC"),
                .define("SQLITE_EXTRA_INIT", to: "sqlcipher_extra_init"),
                .define("SQLITE_EXTRA_SHUTDOWN", to: "sqlcipher_extra_shutdown"),
                .define("SQLITE_TEMP_STORE", to: "2"),
                .define("SQLITE_THREADSAFE", to: "1"),
                .define("SQLITE_ENABLE_FTS5"),
                .define("SQLITE_OMIT_LOAD_EXTENSION"),
                .define("NDEBUG"),
                .unsafeFlags(["-w"]),
            ],
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedFramework("CoreFoundation"),
            ]
        ),
        .executableTarget(
            name: "Clipsie",
            dependencies: ["CSQLCipher"],
            path: "Sources/Clipsie",
            linkerSettings: [.linkedFramework("Security")]
        ),
    ]
)

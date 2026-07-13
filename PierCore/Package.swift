// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "PierCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "PierDomain", targets: ["PierDomain"]),
        .library(name: "PierApplication", targets: ["PierApplication"]),
        .library(name: "PierAdapters", targets: ["CitadelAdapter", "KeychainAdapter", "PersistenceAdapter"])
    ],
    dependencies: [
        .package(url: "https://github.com/orlandos-nl/Citadel.git", exact: "0.12.1"),
        .package(url: "https://github.com/Wellz26/swift-nio-ssh.git", "0.3.4" ..< "0.4.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.12.3")
    ],
    targets: [
        .target(name: "PierSupport", path: "Sources/Support"),
        .target(name: "PierDomain", dependencies: ["PierSupport"], path: "Sources/Domain"),
        .target(name: "PierApplication", dependencies: ["PierDomain", "PierSupport"], path: "Sources/Application"),
        .target(
            name: "CitadelAdapter",
            dependencies: [
                "PierApplication",
                "PierDomain",
                "PierSupport",
                .product(name: "Citadel", package: "Citadel"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto")
            ],
            path: "Sources/CitadelAdapter"
        ),
        .target(
            name: "KeychainAdapter",
            dependencies: ["PierApplication", "PierDomain", "PierSupport"],
            path: "Sources/KeychainAdapter"
        ),
        .target(
            name: "PersistenceAdapter",
            dependencies: ["PierApplication", "PierDomain", "PierSupport"],
            path: "Sources/PersistenceAdapter"
        ),
        .testTarget(
            name: "DomainTests",
            dependencies: ["PierDomain"],
            path: "Tests/DomainTests",
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "ApplicationTests",
            dependencies: ["PierApplication", "PierDomain", "CitadelAdapter", "PersistenceAdapter"],
            path: "Tests/ApplicationTests"
        ),
        .testTarget(
            name: "CitadelAdapterTests",
            dependencies: [
                "CitadelAdapter",
                "PierSupport",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "Crypto", package: "swift-crypto")
            ],
            path: "Tests/CitadelAdapterTests"
        ),
        .testTarget(
            name: "KeychainAdapterTests",
            dependencies: ["KeychainAdapter", "PierDomain", "PierSupport"],
            path: "Tests/KeychainAdapterTests"
        )
    ]
)

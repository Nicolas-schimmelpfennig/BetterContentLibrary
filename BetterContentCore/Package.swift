// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BetterContentCore",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "BetterContentCore", targets: ["BetterContentCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/supabase/supabase-swift.git", from: "2.0.0"),
    ],
    targets: [
        .target(
            name: "BetterContentCore",
            dependencies: [
                .product(name: "Supabase", package: "supabase-swift"),
            ]
        ),
        .testTarget(
            name: "BetterContentCoreTests",
            dependencies: ["BetterContentCore"]
        ),
    ]
)

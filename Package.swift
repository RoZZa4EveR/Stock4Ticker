// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Stock4Ticker",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Stock4Ticker", targets: ["Stock4Ticker"])
    ],
    targets: [
        .executableTarget(
            name: "Stock4Ticker",
            path: "Sources/Stock4Ticker",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)

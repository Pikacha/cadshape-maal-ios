// swift-tools-version:5.9
// The measuring maths of CadSHAPE Mål, without any Apple UI frameworks, so it
// can be tested with `swift test` on a Mac (and in CI).
import PackageDescription

let package = Package(
    name: "HoleKit",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "HoleKit", targets: ["HoleKit"])],
    targets: [
        .target(name: "HoleKit"),
        .testTarget(name: "HoleKitTests", dependencies: ["HoleKit"]),
    ]
)

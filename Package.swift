// swift-tools-version: 6.0
import PackageDescription

/// Route geometry and pace physics for cycling, hiking and running.
///
/// Two libraries:
/// - `TrailPhysicsGeo`: distances, projection onto a line, slicing,
///   simplification, bearings, bounding boxes, sunrise and sunset. Needs
///   only CoreLocation.
/// - `TrailPhysics`: rider power-to-speed physics, hiking and running pace,
///   elevation figures, and the live-ride filters (rolling speed, off-route
///   hysteresis, barometric ascent). Re-exports `TrailPhysicsGeo`.
let package = Package(
    name: "TrailPhysics",
    platforms: [.iOS(.v18), .watchOS(.v11), .macOS(.v14)],
    products: [
        .library(name: "TrailPhysicsGeo", targets: ["TrailPhysicsGeo"]),
        .library(name: "TrailPhysics", targets: ["TrailPhysics"])
    ],
    targets: [
        .target(name: "TrailPhysicsGeo"),
        .target(name: "TrailPhysics", dependencies: ["TrailPhysicsGeo"]),
        .testTarget(name: "TrailPhysicsGeoTests", dependencies: ["TrailPhysicsGeo"]),
        .testTarget(
            name: "TrailPhysicsTests",
            dependencies: ["TrailPhysics"],
            resources: [.copy("Fixtures")]
        )
    ]
)

import CoreLocation
import Foundation
import Testing
@testable import TrailPhysics

/// The rider physics and elevation vectors the JavaScript port pins
/// (`Fixtures/rider-physics.json`, `Fixtures/elevation.json`, byte-identical
/// copies of the files its `test/build-shared-fixtures.mjs` writes). Both
/// ports read every vector, so a number that moves in one moves in neither.
enum SharedFixtures {
    struct Route: Decodable {
        var latlngs: [[Double]]
        var elevations: [Double]

        var coordinates: [CLLocationCoordinate2D] {
            latlngs.map { CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) }
        }
    }

    struct RiderSpec: Decodable {
        var riderKg: Double
        var bikeKg: Double?
        var watts: Double
        var heightCm: Double?
        var bikeType: String?
        var surface: String?
        var fatigue: Bool?
        var cda: Double?

        var model: RiderPhysics.Rider {
            RiderPhysics.Rider(
                riderKg: riderKg, bikeKg: bikeKg, watts: watts, heightCm: heightCm,
                bikeType: bikeType ?? RiderPhysics.defaultBikeType,
                surface: surface ?? RiderPhysics.defaultSurface,
                fatigue: fatigue ?? false, cda: cda
            )
        }
    }

    struct Physics: Decodable {
        struct AirDensity: Decodable { var elevation_m: Double?; var expected: Double }
        struct DefaultCdA: Decodable { var height_cm: Double?; var weight_kg: Double?; var bike_type: String; var expected: Double }
        struct FatigueFactor: Decodable { var hours: Double?; var expected: Double }
        struct FatigueHours: Decodable { var total_hours: Double; var day_hours: Double?; var expected: Double }
        struct Gradient: Decodable { var rider: String; var gradient: Double; var expected_kmh: Double }
        struct Estimate: Decodable {
            var rider: String; var distance_km: Double; var ascent_m: Double?; var day_hours: Double?
            var expected_kmh: Double?
        }
        struct Detailed: Decodable { var rider: String; var route: String; var expected_kmh: Double? }

        var version: Int
        var tolerance: Double
        var riders: [String: RiderSpec]
        var routes: [String: Route]
        var air_density: [AirDensity]
        var default_cda: [DefaultCdA]
        var fatigue_factor: [FatigueFactor]
        var fatigue_hours: [FatigueHours]
        var speed_for_gradient: [Gradient]
        var estimate: [Estimate]
        var detailed: [Detailed]
    }

    struct Elevation: Decodable {
        struct Constants: Decodable {
            var min_climb_m: Double
            var incline_window_m: Double
            var max_incline_spacing_m: Double
            var max_profile_points: Int
            var incline_band_thresholds: [Double]
            var foot_incline_band_thresholds: [Double]
        }
        struct Ascent: Decodable { var route: String?; var elevations: [Double]?; var expected: Double? }
        struct MaxIncline: Decodable { var route: String; var expected: Double? }
        struct Band: Decodable { var pct: Double; var sport: String; var expected: Int }
        struct Sample: Decodable { var length: Int; var max: Int; var expected: [Double] }

        var version: Int
        var tolerance: Double
        var constants: Constants
        var routes: [String: Route]
        var ascent: [Ascent]
        var max_incline: [MaxIncline]
        var incline_band: [Band]
        var sample: [Sample]
    }

    static func load<T: Decodable>(_ name: String, as type: T.Type) throws -> T {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    }
}

private func expectClose(_ got: Double?, _ want: Double?, _ tolerance: Double, _ label: String) {
    guard let want else {
        #expect(got == nil, "\(label): got \(String(describing: got)), want nil")
        return
    }
    guard let got else {
        Issue.record("\(label): got nil, want \(want)")
        return
    }
    #expect(abs(got - want) <= tolerance, "\(label): got \(got), want \(want)")
}

struct SharedPhysicsFixtureTests {
    @Test("Air density, drag area and fatigue match the JavaScript port")
    func figures() throws {
        let f = try SharedFixtures.load("rider-physics", as: SharedFixtures.Physics.self)
        #expect(f.version == 1)
        for v in f.air_density {
            expectClose(RiderPhysics.airDensity(atElevationM: v.elevation_m), v.expected, f.tolerance, "air \(String(describing: v.elevation_m))")
        }
        for v in f.default_cda {
            expectClose(
                RiderPhysics.defaultCdA(heightCm: v.height_cm, weightKg: v.weight_kg, bikeType: v.bike_type),
                v.expected, f.tolerance, "cda \(v.bike_type)"
            )
        }
        for v in f.fatigue_factor {
            expectClose(RiderPhysics.fatigueFactor(hours: v.hours), v.expected, f.tolerance, "fatigue \(String(describing: v.hours))")
        }
        for v in f.fatigue_hours {
            expectClose(
                RiderPhysics.fatigueHours(totalHours: v.total_hours, dayHours: v.day_hours),
                v.expected, f.tolerance, "fatigue hours \(v.total_hours)"
            )
        }
    }

    @Test("Speed on a gradient matches the JavaScript port")
    func speedForGradient() throws {
        let f = try SharedFixtures.load("rider-physics", as: SharedFixtures.Physics.self)
        for v in f.speed_for_gradient {
            let rider = try #require(f.riders[v.rider]).model
            let params = try #require(RiderPhysics.normalize(rider))
            expectClose(
                RiderPhysics.speedForGradientMs(v.gradient, params: params) * 3.6,
                v.expected_kmh, f.tolerance, "\(v.rider) at \(v.gradient)"
            )
        }
    }

    @Test("The quick estimate matches the JavaScript port")
    func estimate() throws {
        let f = try SharedFixtures.load("rider-physics", as: SharedFixtures.Physics.self)
        for v in f.estimate {
            let rider = try #require(f.riders[v.rider]).model
            expectClose(
                RiderPhysics.estimateSpeedKmh(rider: rider, distanceKm: v.distance_km, ascentM: v.ascent_m, dayHours: v.day_hours),
                v.expected_kmh, f.tolerance, "\(v.rider) \(v.distance_km) km"
            )
        }
    }

    @Test("The detailed solve matches the JavaScript port")
    func detailed() throws {
        let f = try SharedFixtures.load("rider-physics", as: SharedFixtures.Physics.self)
        for v in f.detailed {
            let rider = try #require(f.riders[v.rider]).model
            let route = try #require(f.routes[v.route])
            expectClose(
                RiderPhysics.detailedSpeedKmh(rider: rider, latlngs: route.coordinates, elevations: route.elevations),
                v.expected_kmh, f.tolerance, "\(v.rider) on \(v.route)"
            )
        }
    }
}

struct SharedElevationFixtureTests {
    @Test("The constants match the JavaScript port")
    func constants() throws {
        let c = try SharedFixtures.load("elevation", as: SharedFixtures.Elevation.self).constants
        #expect(RouteElevation.minClimbM == c.min_climb_m)
        #expect(RouteElevation.inclineWindowM == c.incline_window_m)
        #expect(RouteElevation.maxInclineSpacingM == c.max_incline_spacing_m)
        #expect(RouteElevation.maxStoredPoints == c.max_profile_points)
        #expect(RouteElevation.inclineBandThresholds == c.incline_band_thresholds)
        #expect(RouteElevation.footInclineBandThresholds == c.foot_incline_band_thresholds)
    }

    @Test("Filtered ascent matches the JavaScript port")
    func ascent() throws {
        let f = try SharedFixtures.load("elevation", as: SharedFixtures.Elevation.self)
        for v in f.ascent {
            let elevations = try v.route.map { try #require(f.routes[$0]).elevations } ?? v.elevations
            expectClose(RouteElevation.ascent(elevations), v.expected, f.tolerance, v.route ?? "\(elevations ?? [])")
        }
    }

    @Test("Max incline matches the JavaScript port")
    func maxIncline() throws {
        let f = try SharedFixtures.load("elevation", as: SharedFixtures.Elevation.self)
        for v in f.max_incline {
            let route = try #require(f.routes[v.route])
            expectClose(
                RouteElevation.maxInclinePct(latlngs: route.coordinates, elevations: route.elevations),
                v.expected, f.tolerance, v.route
            )
        }
    }

    @Test("Incline bands match the JavaScript port")
    func bands() throws {
        let f = try SharedFixtures.load("elevation", as: SharedFixtures.Elevation.self)
        for v in f.incline_band {
            let thresholds = v.sport == "hike" || v.sport == "run"
                ? RouteElevation.footInclineBandThresholds : RouteElevation.inclineBandThresholds
            #expect(RouteElevation.inclineBand(v.pct, thresholds: thresholds).rawValue == v.expected, "\(v.pct)% \(v.sport)")
        }
    }

    @Test("Sampling matches the JavaScript port")
    func sampling() throws {
        let f = try SharedFixtures.load("elevation", as: SharedFixtures.Elevation.self)
        for v in f.sample {
            let values = (0..<v.length).map(Double.init)
            #expect(RouteElevation.sample(values, max: v.max) == v.expected, "\(v.length) to \(v.max)")
        }
    }
}

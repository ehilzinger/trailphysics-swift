import CoreLocation
import Foundation
import Testing
@testable import TrailPhysics

/// The shared vectors: `Fixtures/foot-pace.json`, a byte-identical copy of
/// the fixture file Hatchure's web implementation tests against. Both ports
/// read every vector, so they cannot drift apart. The `pace` vectors are
/// display strings; formatting is left to the caller, so they are decoded
/// here but not tested.
enum FootPaceFixtures {
    struct File: Decodable {
        var version: Int
        var tolerance_s: Double
        var sections: [SectionVector]
        var routes: [RouteVector]
        var pace: [PaceVector]
    }

    struct Settings: Decodable, Sendable {
        var hikeFactor: Double?
        var runPaceSecPerKm: Int?

        var model: FootPaceSettings {
            FootPaceSettings(hikeFactor: hikeFactor ?? 1.0, runPaceSecPerKm: runPaceSecPerKm)
        }
    }

    /// Numbers are optional here because the vectors include unreadable
    /// ones (`null`), which the model reads as 0.
    struct RawSection: Decodable, Sendable {
        var distanceM: Double?
        var ascentM: Double?
        var descentM: Double?
        var sacScale: Int?
        var surface: String?
        var roadClass: String?

        var model: FootPace.Section {
            FootPace.Section(
                distanceM: distanceM ?? 0, ascentM: ascentM ?? 0, descentM: descentM ?? 0,
                sacScale: sacScale, surface: surface, roadClass: roadClass
            )
        }
    }

    struct SectionVector: Decodable, Sendable, CustomTestStringConvertible {
        var name: String
        var profile: String
        var settings: Settings
        var section: RawSection
        var expected_s: Double
        var testDescription: String { name }
    }

    struct RawWay: Decodable, Sendable {
        var fromM: Double
        var toM: Double
        var sacScale: Int?
        var surface: String?
        var roadClass: String?

        var model: FootPace.Way {
            FootPace.Way(fromM: fromM, toM: toM, sacScale: sacScale, surface: surface, roadClass: roadClass)
        }
    }

    struct RouteVector: Decodable, Sendable, CustomTestStringConvertible {
        var name: String
        var profile: String
        var settings: Settings
        var distances_m: [Double]?
        var elevations: [Double?]?
        var ways: [RawWay]
        var total_m: Double
        var ascent_m: Double?
        var descent_m: Double?
        var expected_sections: Int
        var expected_s: Double
        var testDescription: String { name }
    }

    struct PaceVector: Decodable, Sendable, CustomTestStringConvertible {
        var sec_per_km: Double
        var units: String
        var expected: String?
        var testDescription: String { "\(sec_per_km) s/km \(units)" }
    }

    static let file: File? = {
        guard let url = Bundle.module.url(forResource: "foot-pace", withExtension: "json", subdirectory: "Fixtures"),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return try? JSONDecoder().decode(File.self, from: data)
    }()

    static var tolerance: Double { file?.tolerance_s ?? 0.01 }
    static var sections: [SectionVector] { file?.sections ?? [] }
    static var routes: [RouteVector] { file?.routes ?? [] }
    static var pace: [PaceVector] { file?.pace ?? [] }
}

struct FootPaceFixtureTests {
    @Test("The shared fixture file is bundled and decodes")
    func fixtureLoads() throws {
        let file = try #require(FootPaceFixtures.file)
        #expect(file.version == 1)
        #expect(!file.sections.isEmpty)
        #expect(!file.routes.isEmpty)
        #expect(!file.pace.isEmpty)
    }

    @Test("Section vectors", arguments: FootPaceFixtures.sections)
    func section(_ v: FootPaceFixtures.SectionVector) throws {
        let profile = try #require(RouteProfile(rawValue: v.profile))
        let got = FootPace.sectionSeconds(v.section.model, profile: profile, settings: v.settings.model)
        #expect(abs(got - v.expected_s) <= FootPaceFixtures.tolerance, "got \(got), want \(v.expected_s)")
    }

    @Test("Route vectors", arguments: FootPaceFixtures.routes)
    func route(_ v: FootPaceFixtures.RouteVector) throws {
        let profile = try #require(RouteProfile(rawValue: v.profile))
        let sections = FootPace.sections(
            distancesM: v.distances_m, elevations: v.elevations, ways: v.ways.map(\.model),
            totalM: v.total_m, ascentM: v.ascent_m, descentM: v.descent_m
        )
        #expect(sections.count == v.expected_sections)
        let got = sections.reduce(0) { $0 + FootPace.sectionSeconds($1, profile: profile, settings: v.settings.model) }
        #expect(abs(got - v.expected_s) <= FootPaceFixtures.tolerance, "got \(got), want \(v.expected_s)")
    }

}

struct FootPaceSettingsTests {
    @Test("Defaults: signpost factor, 6:00 road, 7:00 trail")
    func defaults() {
        let s = FootPaceSettings()
        #expect(s.effectiveHikeFactor == 1.0)
        #expect(s.runPace(for: .roadrun) == 360)
        #expect(s.runPace(for: .trailrun) == 420)
    }

    @Test("One user pace serves both run profiles, clamped to the accepted bounds")
    func userPace() {
        #expect(FootPaceSettings(runPaceSecPerKm: 330).runPace(for: .roadrun) == 330)
        #expect(FootPaceSettings(runPaceSecPerKm: 330).runPace(for: .trailrun) == 330)
        #expect(FootPaceSettings(runPaceSecPerKm: 60).runPace(for: .roadrun) == 150)
        #expect(FootPaceSettings(runPaceSecPerKm: 2000).runPace(for: .roadrun) == 900)
        #expect(FootPaceSettings(runPaceSecPerKm: 0).runPace(for: .roadrun) == 360)
    }

    @Test("Unreadable hike factors are the default; out of range is clamped")
    func hikeFactor() {
        #expect(FootPaceSettings(hikeFactor: .nan).effectiveHikeFactor == 1.0)
        #expect(FootPaceSettings(hikeFactor: -1).effectiveHikeFactor == 1.0)
        #expect(FootPaceSettings(hikeFactor: 0.2).effectiveHikeFactor == 0.5)
        #expect(FootPaceSettings(hikeFactor: 3).effectiveHikeFactor == 2.0)
    }

    @Test("Decodes with keys missing, and round-trips")
    func codable() throws {
        let empty = try JSONDecoder().decode(FootPaceSettings.self, from: Data("{}".utf8))
        #expect(empty == FootPaceSettings())
        let s = FootPaceSettings(hikeFactor: 1.2, runPaceSecPerKm: 315)
        let back = try JSONDecoder().decode(FootPaceSettings.self, from: JSONEncoder().encode(s))
        #expect(back == s)
    }

    @Test("Day hours: hike 6, run 3, riding none")
    func dayHours() {
        #expect(FootPace.defaultDayHours(for: .hiking) == 6)
        #expect(FootPace.defaultDayHours(for: .trailrun) == 3)
        #expect(FootPace.defaultDayHours(for: .roadrun) == 3)
        #expect(FootPace.defaultDayHours(for: .bike) == nil)
    }
}

struct FootPaceRouteTests {
    /// Vertices every 0.001° along the equator (~111.195 m apart).
    private func line(_ n: Int) -> [CLLocationCoordinate2D] {
        (0..<n).map { CLLocationCoordinate2D(latitude: 0, longitude: Double($0) * 0.001) }
    }

    @Test("Riding profiles get nothing from the foot model")
    func ridingProfiles() {
        let section = FootPace.Section(distanceM: 1000)
        for profile in [RouteProfile.bike, .gravel, .road, .roadfast] {
            #expect(FootPace.sectionSeconds(section, profile: profile) == 0)
            #expect(FootPace.routeSeconds(latlngs: line(3), elevations: nil, profile: profile) == nil)
        }
    }

    @Test("A flat route walks at 4 km/h")
    func flatWalk() throws {
        let seconds = try #require(FootPace.routeSeconds(
            latlngs: line(21), elevations: Array(repeating: 300, count: 21), profile: .hiking
        ))
        let km = 20 * 0.111195
        #expect(abs(seconds - km / 4 * 3600) < 1)
    }

    @Test("A thinned profile maps back onto the vertices it was sampled from")
    func thinnedProfile() throws {
        let elevations = (0...10).map { 1000 + Double($0) * 22.239 }
        let viaRoute = try #require(FootPace.routeSeconds(latlngs: line(21), elevations: elevations, profile: .hiking))
        let direct = try #require(FootPace.seconds(
            of: FootPace.sections(
                distancesM: (0...10).map { Double($0) * 2 * 111.195 }, elevations: elevations,
                totalM: 20 * 111.195
            ),
            profile: .hiking
        ))
        #expect(abs(viaRoute - direct) < 1)
    }

    @Test("Without a profile the route ascent is used, descent defaulting to it")
    func ascentFallback() throws {
        let seconds = try #require(FootPace.routeSeconds(
            latlngs: line(21), elevations: nil, ascentM: 300, profile: .hiking
        ))
        let h = 20 * 0.111195 / 4, v = 1.6
        #expect(abs(seconds - (max(h, v) + min(h, v) / 2) * 3600) < 1)
    }

    @Test("A T4 way slows the hike by 1.35")
    func sacWay() throws {
        let flat = Array(repeating: 300.0, count: 21)
        let plain = try #require(FootPace.routeSeconds(latlngs: line(21), elevations: flat, profile: .hiking))
        let t4 = [FootPace.Way(fromM: 0, toM: 20 * 111.2, sacScale: 4, surface: "rock", roadClass: "path")]
        let slow = try #require(FootPace.routeSeconds(latlngs: line(21), elevations: flat, ways: t4, profile: .hiking))
        #expect(abs(slow - plain * 1.35) < 0.01)
    }

    @Test("The timeline starts at zero, only grows, and ends at the route total")
    func timeline() throws {
        let elevations = (0..<41).map { 500 + 80 * sin(Double($0) / 5) }
        for profile in [RouteProfile.hiking, .trailrun, .roadrun] {
            let t = try #require(FootPace.timeline(latlngs: line(41), elevations: elevations, profile: profile))
            let total = try #require(FootPace.routeSeconds(latlngs: line(41), elevations: elevations, profile: profile))
            #expect(t.distancesM.first == 0)
            #expect(t.seconds.first == 0)
            #expect(abs((t.seconds.last ?? 0) - total) < 1e-6)
            #expect(zip(t.seconds, t.seconds.dropFirst()).allSatisfy { $0 < $1 })
        }
    }

    @Test("Time never falls as a climb steepens, through the power-hike switch")
    func monotoneClimb() {
        // A slow runner who hikes fast, the pairing where the hike branch wins.
        let settings = FootPaceSettings(hikeFactor: 2.0, runPaceSecPerKm: 900)
        var last = 0.0
        for up in stride(from: 0.0, through: 800, by: 10) {
            let t = FootPace.sectionSeconds(
                FootPace.Section(distanceM: 1000, ascentM: up, roadClass: "path"),
                profile: .trailrun, settings: settings
            )
            #expect(t >= last)
            last = t
        }
    }
}

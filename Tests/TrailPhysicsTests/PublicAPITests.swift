import CoreLocation
import Foundation
import Testing
import TrailPhysics

/// The README's example, compiled against the PUBLIC surface only — a plain
/// `import`, not `@testable` — so a declaration the example needs cannot
/// quietly stay internal.
struct PublicAPITests {
    @Test("The README example compiles and answers")
    func readmeExample() throws {
        let line: [CLLocationCoordinate2D] = [
            .init(latitude: 46.00, longitude: 7.00),
            .init(latitude: 46.01, longitude: 7.01),
            .init(latitude: 46.02, longitude: 7.02),
        ]
        let elevations: [Double] = [1_200, 1_350, 1_500]

        let rider = RiderPhysics.Rider(riderKg: 75, bikeKg: 18, watts: 180)
        let kmh = try #require(RiderPhysics.detailedSpeedKmh(rider: rider, latlngs: line, elevations: elevations))
        #expect(kmh > 0 && kmh < 40)

        let seconds = try #require(FootPace.routeSeconds(latlngs: line, elevations: elevations, profile: .hiking))
        #expect(seconds > 0)

        let climbed = try #require(RouteElevation.ascent(elevations))
        #expect(climbed == 300)

        let cumulative = RouteGeometry.cumulativeDistances(line)
        let fix = CLLocationCoordinate2D(latitude: 46.012, longitude: 7.011)
        let position = try #require(RouteGeometry.project(fix, along: line, cumulative: cumulative))
        #expect(position.fraction > 0 && position.fraction < 1)

        #expect(Sun.sunset(on: .now, lat: line[0].latitude, lng: line[0].longitude) != nil)
    }

    @Test("The live-ride filters can be built and fed from outside the module")
    func rideFilters() {
        var window = RideSpeedWindow()
        var ascent = RideAscent()
        window.reset()
        ascent.reset()
        #expect(ascent.climbedM == 0)
        #expect(RideBearing.direction(relative: 45) == .right)
        #expect(RouteProfile.trailrun.sport == .run)
    }
}

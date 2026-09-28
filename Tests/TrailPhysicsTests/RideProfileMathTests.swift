import CoreLocation
import Foundation
import Testing

@testable import TrailPhysics

/// Reading `WatchRidePlan.elevations` for "how much is left to climb" —
/// checked against `RouteElevation.ascent`'s own arithmetic over the same
/// indices, since this is deliberately not a second copy of it.
struct RideProfileMathTests {
    /// 21 evenly spaced points on a straight line, so `anchorDistances`
    /// takes the direct branch (`elevations.count == latlngs.count`) rather
    /// than inverting a stride, and a fraction of the route lines up with a
    /// whole index exactly — which is what makes the expected numbers in
    /// these tests round figures instead of approximations.
    private func line() -> [CLLocationCoordinate2D] {
        (0...20).map {
            CLLocationCoordinate2D(latitude: 48, longitude: 11 + Double($0) * 0.001)
        }
    }

    /// Climbs 100 m over the first half, then gives back half of it — a
    /// profile with one climb worth measuring and one place it could be
    /// double-counted if a slice leaked past its own end.
    private func elevations() -> [Double] {
        (0...20).map { index -> Double in
            if index <= 10 {
                return Double(index) * 10
            }
            return 100 - Double(index - 10) * 5
        }
    }

    @Test("The whole route's ascent matches RouteElevation's own sum")
    func wholeRouteAscent() throws {
        let elevations = elevations()
        let expected = RouteElevation.ascent(elevations, from: 0, through: elevations.count - 1)
        let result = try #require(RideProfileMath.ascent(
            elevations: elevations, line: line(), from: 0, to: 1
        ))
        #expect(abs(result - expected) < 0.01)
        #expect(abs(result - 100) < 0.01)
    }

    @Test("The half-route case sums only its own half")
    func halfRouteAscent() throws {
        let result = try #require(RideProfileMath.ascent(
            elevations: elevations(), line: line(), from: 0, to: 0.5
        ))
        // The whole 100 m climb sits in the first half; the second half is
        // the descent, which contributes nothing.
        #expect(abs(result - 100) < 0.01)

        let secondHalf = try #require(RideProfileMath.ascent(
            elevations: elevations(), line: line(), from: 0.5, to: 1
        ))
        #expect(secondHalf == 0)
    }

    @Test("A profile with nothing to read answers nil, not zero")
    func shortProfileIsNil() {
        #expect(RideProfileMath.ascent(elevations: [], line: nil, from: 0, to: 1) == nil)
        #expect(RideProfileMath.ascent(elevations: [50], line: nil, from: 0, to: 1) == nil)
        // An inverted range is refused the same way, whatever the profile.
        #expect(RideProfileMath.ascent(elevations: elevations(), line: line(), from: 0.6, to: 0.4) == nil)
        #expect(RideProfileMath.ascent(elevations: elevations(), line: line(), from: 0.5, to: 0.5) == nil)
    }

    @Test("With no line, the proportional fallback still answers")
    func proportionalFallback() throws {
        // No line at all: `anchorDistances` can't be asked, so this walks
        // the fallback branch outright.
        let result = try #require(RideProfileMath.ascent(
            elevations: elevations(), line: nil, from: 0, to: 0.5
        ))
        #expect(abs(result - 100) < 0.01)
    }

    @Test("Sample spacing widens with the route and is infinite for nothing")
    func sampleSpacing() {
        #expect(RideProfileMath.sampleSpacingKm(elevations: elevations(), routeKm: 40) == 2)
        #expect(RideProfileMath.sampleSpacingKm(elevations: [], routeKm: 40) == .infinity)
        #expect(RideProfileMath.sampleSpacingKm(elevations: [1, 2], routeKm: 0) == .infinity)
    }
}

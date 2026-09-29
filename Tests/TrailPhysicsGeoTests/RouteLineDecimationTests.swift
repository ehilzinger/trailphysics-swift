import CoreLocation
import Foundation
import Testing
@testable import TrailPhysicsGeo

/// What the map is allowed to leave out of a long route when it draws it.
///
/// The claim these make is the one the whole thing rests on: the thinned
/// line is the same picture as the real one at the zoom it is drawn for,
/// and nothing downstream of the drawing sees the thinned copy.
@Suite("Route line decimation")
struct RouteLineDecimationTests {
    /// A BRouter-shaped line: a vertex every ~12 m with the small wander a
    /// real road has, so thinning it has something to actually take out.
    private static func line(count: Int) -> [CLLocationCoordinate2D] {
        (0..<count).map { index in
            let t = Double(index)
            return CLLocationCoordinate2D(
                latitude: 48.137 + t * 0.0001 + sin(t / 40) * 0.0003,
                longitude: 11.575 + t * 0.00012 + cos(t / 55) * 0.0003
            )
        }
    }

    // MARK: - When it applies at all

    @Test("A short route is never thinned, however far out the map is")
    func shortRouteIsDrawnWhole() {
        #expect(RouteLineDecimation.toleranceM(pointCount: 800, metresPerPoint: 1_200) == 0)
        #expect(RouteLineDecimation.toleranceM(
            pointCount: RouteLineDecimation.floor, metresPerPoint: 1_200
        ) == 0)
    }

    @Test("Zoomed in far enough there is nothing left to take out")
    func closeZoomIsDrawnWhole() {
        // A metre per screen point is a city block filling the screen: half
        // a point is half a metre, under the tolerance floor.
        #expect(RouteLineDecimation.toleranceM(pointCount: 40_000, metresPerPoint: 1) == 0)
    }

    @Test("The tolerance is half a screen point, bucketed down to a power of two")
    func toleranceBuckets() {
        // 1 100 m per point → 550 m wanted → 512.
        #expect(RouteLineDecimation.toleranceM(pointCount: 14_000, metresPerPoint: 1_100) == 512)
        // A nudge either side of that lands in the same bucket, which is
        // what keeps a pinch from rebuilding the line on every frame.
        #expect(RouteLineDecimation.toleranceM(pointCount: 14_000, metresPerPoint: 1_050)
                == RouteLineDecimation.toleranceM(pointCount: 14_000, metresPerPoint: 1_150))
    }

    // MARK: - What it leaves

    @Test("Thinning keeps both ends exactly")
    func endpointsSurvive() {
        let full = Self.line(count: 5_000)
        let thin = RouteLineDecimation.thinned(full, toleranceM: 256)
        #expect(thin.count < full.count)
        #expect(thin.first?.latitude == full.first?.latitude)
        #expect(thin.first?.longitude == full.first?.longitude)
        #expect(thin.last?.latitude == full.last?.latitude)
        #expect(thin.last?.longitude == full.last?.longitude)
    }

    @Test("A zero tolerance returns the line untouched")
    func zeroToleranceIsIdentity() {
        let full = Self.line(count: 3_000)
        #expect(RouteLineDecimation.thinned(full, toleranceM: 0).count == full.count)
    }

    @Test("A framed long route thins to a small fraction of its vertices")
    func longRouteThinsHard() {
        // 14 000 points is roughly BRouter's answer for Munich to
        // Milan; ~1 100 m per screen point is that route framed on a phone.
        let full = Self.line(count: 14_000)
        let tolerance = RouteLineDecimation.toleranceM(
            pointCount: full.count, metresPerPoint: 1_100
        )
        let thin = RouteLineDecimation.thinned(full, toleranceM: tolerance)
        #expect(thin.count < full.count / 10)
        #expect(thin.count >= 2)
    }

    // MARK: - Day segments

    @Test("Joining tolerates an empty segment")
    func joiningSkipsEmptySegments() {
        let a = [CLLocationCoordinate2D(latitude: 1, longitude: 1),
                 CLLocationCoordinate2D(latitude: 2, longitude: 2)]
        let b = [CLLocationCoordinate2D(latitude: 2, longitude: 2),
                 CLLocationCoordinate2D(latitude: 3, longitude: 3)]
        #expect(RouteLineDecimation.joined([a, [], b]).count == 3)
    }
}

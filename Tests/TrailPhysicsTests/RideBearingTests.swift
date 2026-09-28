import CoreLocation
import Foundation
import Testing

@testable import TrailPhysics

/// Which way, and the honest substitute for a turn instruction this app does
/// not have: there is no router on watchOS, so the only source of direction
/// is the shape of the line already on the wrist.
struct RideBearingTests {
    private let baseLat = 48.0
    private var metresPerDegreeLon: Double { 111_320 * cos(baseLat * .pi / 180) }
    private let metresPerDegreeLat = 111_320.0

    private func point(east: Double, north: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: baseLat + north / metresPerDegreeLat,
            longitude: 11 + east / metresPerDegreeLon
        )
    }

    /// Walks forward from the origin, one segment per bearing (0 = north,
    /// 90 = east, clockwise), so a test can specify the exact heading
    /// changes it wants rather than fight real-world geometry for them.
    private func curveLine(bearings: [Double], segmentM: Double = 50) -> [CLLocationCoordinate2D] {
        var points = [point(east: 0, north: 0)]
        var east = 0.0, north = 0.0
        for bearing in bearings {
            let radians = bearing * .pi / 180
            east += segmentM * sin(radians)
            north += segmentM * cos(radians)
            points.append(point(east: east, north: north))
        }
        return points
    }

    // MARK: - relative

    @Test("relative wraps at 0/360 and refuses a negative course")
    func relativeWraps() {
        // A target at 350° is 20° LEFT of a rider heading 10° — the seam
        // the naive subtraction (350 − 10 = 340) gets wrong.
        #expect(RideBearing.relative(bearing: 350, course: 10) == -20)
        // And the mirror: 10° is 20° RIGHT of heading 350°.
        #expect(RideBearing.relative(bearing: 10, course: 350) == 20)
        // CoreLocation's "I don't know" and "standing still" both come back
        // as a negative course, and both mean the same thing here: no
        // answer, not a stale one.
        #expect(RideBearing.relative(bearing: 90, course: -1) == nil)
        #expect(RideBearing.relative(bearing: 90, course: nil) == nil)
    }

    // MARK: - direction

    @Test("direction covers the six sectors with no gap")
    func directionBands() {
        #expect(RideBearing.direction(relative: 0) == .ahead)
        #expect(RideBearing.direction(relative: 29.9) == .ahead)
        #expect(RideBearing.direction(relative: -30) == .ahead)
        #expect(RideBearing.direction(relative: 30) == .right)
        #expect(RideBearing.direction(relative: 60) == .right)
        #expect(RideBearing.direction(relative: 90) == .behindRight)
        #expect(RideBearing.direction(relative: 120) == .behindRight)
        #expect(RideBearing.direction(relative: 150) == .behind)
        #expect(RideBearing.direction(relative: 180) == .behind)
        #expect(RideBearing.direction(relative: -180) == .behind)
        #expect(RideBearing.direction(relative: -150) == .behindLeft)
        #expect(RideBearing.direction(relative: -120) == .behindLeft)
        #expect(RideBearing.direction(relative: -90) == .left)
        #expect(RideBearing.direction(relative: -60) == .left)
    }

    // MARK: - nextTurn

    @Test("A right-angle left turn ahead is found with the right sign and distance")
    func rightAngleLeftTurn() throws {
        // East for 300 m, then north — a rider heading east who turns to
        // head north has turned left.
        var points = (0...5).map { point(east: Double($0) * 60, north: 0) }
        points += (1...3).map { point(east: 300, north: Double($0) * 60) }
        let cumulative = RouteGeometry.cumulativeDistances(points)

        let turn = try #require(RideBearing.nextTurn(
            line: points, cumulative: cumulative,
            fromMetres: 0, within: 500, minDegrees: 45
        ))
        #expect(turn.isLeft)
        #expect(abs(turn.degrees - (-90)) < 5)
        #expect(abs(turn.metresAway - 300) < 10)
    }

    @Test("A straight line has no turn to find")
    func straightLineHasNoTurn() {
        let points = (0...10).map { point(east: Double($0) * 50, north: 0) }
        let cumulative = RouteGeometry.cumulativeDistances(points)
        #expect(RideBearing.nextTurn(
            line: points, cumulative: cumulative,
            fromMetres: 0, within: 500, minDegrees: 20
        ) == nil)
    }

    @Test("A gentle curve under the threshold answers nil")
    func gentleCurveIsNotATurn() {
        // Ten segments drifting 3° each, 27° in all — a sweeping bend, not
        // a corner, and well short of the 45° this asks for.
        let bearings = stride(from: 90.0, through: 117.0, by: 3.0).map { $0 }
        let points = curveLine(bearings: bearings)
        let cumulative = RouteGeometry.cumulativeDistances(points)
        #expect(RideBearing.nextTurn(
            line: points, cumulative: cumulative,
            fromMetres: 0, within: 500, minDegrees: 45
        ) == nil)
    }

    @Test("A bend split across several vertices is reported once, at its start")
    func splitBendReportedOnce() throws {
        // Straight, straight, straight, then three vertices each turning
        // 15° the same way — a corner Douglas-Peucker left as a few short
        // chords rather than one sharp vertex.
        let bearings: [Double] = [90, 90, 90, 90, 105, 120, 135]
        let points = curveLine(bearings: bearings)
        let cumulative = RouteGeometry.cumulativeDistances(points)

        let turn = try #require(RideBearing.nextTurn(
            line: points, cumulative: cumulative,
            fromMetres: 0, within: 500, minDegrees: 40
        ))
        // The heading has changed 45° by the third turning vertex, but the
        // bend itself — and the position reported — starts at the FIRST
        // one, 200 m in (four 50 m segments of straight running first).
        #expect(!turn.isLeft)
        #expect(abs(turn.degrees - 45) < 1)
        #expect(abs(turn.metresAway - 200) < 5)
    }
}

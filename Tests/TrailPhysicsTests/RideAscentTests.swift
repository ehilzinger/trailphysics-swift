import CoreLocation
import Foundation
import Testing

@testable import TrailPhysics

/// Metres climbed, banked the same way `RouteElevation.ascent` reads a
/// stored profile — a rise counts only once a fall confirms it was real —
/// but fed live, fix by fix, with a barometer that lies under trees and a
/// watch that sometimes misses a whole tunnel.
struct RideAscentTests {
    private func fix(
        _ metresEast: Double, altitude: Double, at seconds: TimeInterval,
        verticalAccuracy: Double = 5
    ) -> CLLocation {
        // 48°N — a degree of longitude there is
        // about 74.4 km, which keeps the arithmetic in this file in metres.
        let metresPerDegree = 111_320 * cos(48 * Double.pi / 180)
        return CLLocation(
            coordinate: CLLocationCoordinate2D(
                latitude: 48, longitude: 11 + metresEast / metresPerDegree
            ),
            altitude: altitude,
            horizontalAccuracy: 5,
            verticalAccuracy: verticalAccuracy,
            timestamp: Date(timeIntervalSince1970: 1_757_000_000 + seconds)
        )
    }

    @Test("A 100 m climb over 2 km reports about 100 m, not the sum of its noise")
    func climbIsCounted() {
        var ascent = RideAscent()
        var metres = 0.0, seconds = 0.0

        // 400 m of flat riding first, with ±1 m of barometric jitter — the
        // wobble a café stop or a change in the weather produces. Unfiltered
        // summation would bank every one of the twenty rises in here;
        // filtered, none of them ever reaches `RouteElevation.minClimbM`
        // before the next fix takes it back down.
        for step in 0..<40 {
            metres += 10; seconds += 2
            ascent.note(fix(metres, altitude: step.isMultiple(of: 2) ? 1 : 0, at: seconds))
        }

        // 1,600 m climbing 100 m, in 0.625 m steps — a real hill, not noise.
        for step in 1...160 {
            metres += 10; seconds += 2
            ascent.note(fix(metres, altitude: Double(step) * 0.625, at: seconds))
        }

        // The descent that confirms the climb was real and banks it.
        for _ in 0..<5 {
            metres += 10; seconds += 2
            ascent.note(fix(metres, altitude: 100 - 5, at: seconds))
        }

        #expect(abs(ascent.climbedM - 100) < 2)
    }

    @Test("Barometric jitter on a flat ride reports zero climbed")
    func flatJitterIsZero() {
        var ascent = RideAscent()
        var metres = 0.0, seconds = 0.0
        for step in 0..<60 {
            metres += 10; seconds += 2
            ascent.note(fix(metres, altitude: step.isMultiple(of: 2) ? 1 : 0, at: seconds))
        }
        #expect(ascent.climbedM == 0)
    }

    @Test("A descent counts nothing climbed and reports a negative grade")
    func descentIsNotAClimb() {
        var ascent = RideAscent()
        var metres = 0.0, seconds = 0.0
        for step in 0..<40 {
            metres += 20; seconds += 4
            ascent.note(fix(metres, altitude: 100 - Double(step) * 2.5, at: seconds))
        }
        #expect(ascent.climbedM == 0)
        #expect(ascent.gradePercent != nil)
        #expect((ascent.gradePercent ?? 0) < 0)
    }

    @Test("A fix the watch has no altitude opinion about changes nothing")
    func untrustedFixIsIgnored() throws {
        var ascent = RideAscent()
        var metres = 0.0, seconds = 0.0
        for step in 1...30 {
            metres += 10; seconds += 2
            ascent.note(fix(metres, altitude: Double(step) * 0.6, at: seconds))
        }
        let climbedBefore = ascent.climbedM
        let gradeBefore = ascent.gradePercent

        // A fix that would otherwise read as a cliff — if it were trusted.
        metres += 10; seconds += 2
        ascent.note(fix(metres, altitude: 500, at: seconds, verticalAccuracy: -1))
        #expect(ascent.climbedM == climbedBefore)
        #expect(ascent.gradePercent == gradeBefore)

        // The ride carries on as if the bad fix never happened: the next
        // trusted fix differences against the last GOOD altitude, not
        // 500 m. If the bad fix HAD become the base, this step would read
        // as a cliff-sized descent and the grade would show it.
        metres += 10; seconds += 2
        ascent.note(fix(metres, altitude: Double(31) * 0.6, at: seconds))
        #expect(ascent.climbedM == climbedBefore)
        let gradeAfter = try #require(ascent.gradePercent)
        let before = try #require(gradeBefore)
        #expect(abs(gradeAfter - before) < 5)
    }

    @Test("A ten-minute gap does not bank the step across it")
    func longGapDoesNotBank() {
        var ascent = RideAscent()
        // A little climbing, not yet enough to bank on its own.
        ascent.note(fix(0, altitude: 0, at: 0))
        ascent.note(fix(20, altitude: 2, at: 4))
        ascent.note(fix(40, altitude: 3, at: 8))
        #expect(ascent.climbedM == 0)

        // Ten minutes later, fifty metres higher — a lift, a tunnel, an app
        // the watch suspended. Rebased, not climbed.
        ascent.note(fix(60, altitude: 53, at: 608))
        #expect(ascent.climbedM == 0)

        // And the rebase actually happened: a further step banks only the
        // NEW rise, not the old pending one plus the jump.
        ascent.note(fix(80, altitude: 43, at: 612))
        #expect(ascent.climbedM == 0)
    }
}

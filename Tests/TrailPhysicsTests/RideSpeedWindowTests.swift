import Foundation
import Testing

@testable import TrailPhysics

/// The rolling speed, and the projection flip that made it lie.
///
/// The bug these exist for: a rider standing still, watching the wrist
/// report ten thousand kilometres an hour. The quantity fed in is a
/// position along the route, and where a route doubles back the nearest
/// point on the line can flip a hundred kilometres between two fixes taken
/// from the same spot on the ground.
struct RideSpeedWindowTests {
    private let ceiling = RideSpeedWindow.ceilingKmh(for: .bike)
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("Too short a base says nothing")
    func needsABase() {
        var window = RideSpeedWindow()
        #expect(window.note(metres: 0, at: start, ceilingKmh: ceiling) == nil)
        #expect(window.note(
            metres: 100, at: start.addingTimeInterval(10), ceilingKmh: ceiling
        ) == nil)
    }

    @Test("A steady 20 km/h reads as 20 km/h")
    func measuresSteadyRiding() throws {
        var window = RideSpeedWindow()
        var answer: Double?
        // 20 km/h is 5.556 m/s; a fix every ten seconds for two minutes.
        for step in 0...12 {
            answer = window.note(
                metres: Double(step) * 55.56,
                at: start.addingTimeInterval(Double(step) * 10),
                ceilingKmh: ceiling
            )
        }
        let speed = try #require(answer)
        #expect(abs(speed - 20) < 0.5)
    }

    /// Standing still is a speed, and it is zero — not "no answer". The
    /// figure only goes quiet when the position itself is untrustworthy.
    @Test("Standing still reads zero, not nothing")
    func stationary() throws {
        var window = RideSpeedWindow()
        var answer: Double?
        for step in 0...12 {
            answer = window.note(
                metres: 4_200, at: start.addingTimeInterval(Double(step) * 10),
                ceilingKmh: ceiling
            )
        }
        #expect(try #require(answer) == 0)
    }

    /// The reported bug, exactly: a stationary rider beside a route that
    /// doubles back, whose projection flips between the outbound and return
    /// legs 83 km apart along the line.
    @Test("A projection flip is refused, not published")
    func refusesTheFlip() {
        var window = RideSpeedWindow()
        _ = window.note(metres: 12_000, at: start, ceilingKmh: ceiling)
        let answer = window.note(
            metres: 95_000, at: start.addingTimeInterval(40), ceilingKmh: ceiling
        )
        #expect(answer == nil)
    }

    /// And the flip must not poison the next ten minutes. After a rebase
    /// the window measures from the newest sample, so ordinary riding
    /// re-establishes a figure within one base period.
    @Test("Riding on after a flip recovers")
    func recoversAfterAFlip() throws {
        var window = RideSpeedWindow()
        _ = window.note(metres: 12_000, at: start, ceilingKmh: ceiling)
        #expect(window.note(
            metres: 95_000, at: start.addingTimeInterval(40), ceilingKmh: ceiling
        ) == nil)

        var answer: Double?
        for step in 1...12 {
            answer = window.note(
                metres: 95_000 + Double(step) * 55.56,
                at: start.addingTimeInterval(40 + Double(step) * 10),
                ceilingKmh: ceiling
            )
        }
        let speed = try #require(answer)
        #expect(abs(speed - 20) < 1)
    }

    /// Turning round is not negative speed, and not a jump either.
    @Test("Going backwards along the line reads as zero")
    func backwards() throws {
        var window = RideSpeedWindow()
        _ = window.note(metres: 20_000, at: start, ceilingKmh: ceiling)
        let answer = window.note(
            metres: 19_000, at: start.addingTimeInterval(60), ceilingKmh: ceiling
        )
        #expect(try #require(answer) == 0)
    }

    /// A plan swapped mid-ride re-measures against a different route, so
    /// every sample in the window is now a measurement of something else.
    @Test("Resetting drops the old axis entirely")
    func resets() {
        var window = RideSpeedWindow()
        _ = window.note(metres: 250_000, at: start, ceilingKmh: ceiling)
        window.reset()
        // First sample on the new axis: no basis, and crucially no
        // 250 km difference against the old one.
        #expect(window.note(
            metres: 0, at: start.addingTimeInterval(40), ceilingKmh: ceiling
        ) == nil)
    }

    /// Old samples leave, so a ten-minute stop does not hold a stale figure
    /// in the window forever.
    @Test("The window is ten minutes long")
    func trims() throws {
        var window = RideSpeedWindow()
        _ = window.note(metres: 0, at: start, ceilingKmh: ceiling)
        // Well past the window, riding steadily since.
        var answer: Double?
        for step in 0...12 {
            let at = start.addingTimeInterval(RideSpeedWindow.windowSeconds + Double(step) * 10)
            answer = window.note(metres: 30_000 + Double(step) * 55.56, at: at, ceilingKmh: ceiling)
        }
        // If the first sample had survived, this would read as 30 km over
        // eleven minutes — about 164 km/h, and refused by the ceiling.
        let speed = try #require(answer)
        #expect(abs(speed - 20) < 1)
    }

    @Test("On foot the ceiling is lower")
    func footCeiling() {
        #expect(RideSpeedWindow.ceilingKmh(for: .hiking) < RideSpeedWindow.ceilingKmh(for: .bike))
        var window = RideSpeedWindow()
        _ = window.note(metres: 0, at: start, ceilingKmh: RideSpeedWindow.ceilingKmh(for: .hiking))
        // 60 km/h: ordinary on a descent, impossible on foot.
        #expect(window.note(
            metres: 1_000, at: start.addingTimeInterval(60),
            ceilingKmh: RideSpeedWindow.ceilingKmh(for: .hiking)
        ) == nil)
    }
}

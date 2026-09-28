import CoreLocation
import Foundation
import Testing

@testable import TrailPhysics

/// The rule that decides whether the rider has left the line.
///
/// Every test here is really about one thing: a false positive costs more
/// than a late true one. A rider whose phone announces a wrong turn at every
/// bridge, cycleway and café stops reading the thing, and then the one real
/// wrong turn goes unnoticed too.
struct RideOffRouteTests {
    private let thresholds = RideOffRoute.Thresholds.wheeled

    /// Rides a sequence of (metres off the line, metres ridden) through the
    /// machine and returns every event it produced.
    private func run(
        _ samples: [(off: Double?, odo: Double)],
        suppressed: Bool = false
    ) -> (events: [RideOffRoute.Event], state: RideOffRoute.State) {
        var state = RideOffRoute.State.onRoute
        var events: [RideOffRoute.Event] = []
        for sample in samples {
            let step = RideOffRoute.advance(
                state, offRouteM: sample.off, odometerM: sample.odo,
                suppressed: suppressed, thresholds: thresholds
            )
            state = step.state
            if step.event != .none { events.append(step.event) }
        }
        return (events, state)
    }

    @Test("Riding on the line says nothing")
    func quietOnRoute() {
        let (events, state) = run((0..<50).map { (off: Double($0 % 30), odo: Double($0) * 20) })
        #expect(events.isEmpty)
        #expect(state.standing == .onRoute)
    }

    /// The case that makes a naive threshold useless: one fix under a bridge
    /// throws the position 150 m sideways and the next one puts it back.
    @Test("A single bad fix is not a wrong turn")
    func toleratesAJump() {
        let (events, state) = run([
            (20, 0), (18, 40), (150, 80), (22, 120), (19, 160)
        ])
        #expect(events.isEmpty)
        #expect(state.standing == .onRoute)
    }

    /// A village one-way: off the line for a couple of hundred metres of
    /// entirely correct riding, then back on it.
    @Test("Straying and returning before it is confirmed is never announced")
    func oneWaySystem() {
        let (events, state) = run([
            (30, 0), (95, 100), (110, 200), (90, 280), (30, 340), (10, 400)
        ])
        #expect(events.isEmpty)
        #expect(state.standing == .onRoute)
    }

    @Test("Riding on past the confirmation distance is a wrong turn, once")
    func confirmsAWrongTurn() {
        let (events, state) = run([
            (30, 0), (120, 100), (200, 250), (400, 400), (900, 700), (1400, 1000)
        ])
        #expect(events == [.left])
        #expect(state.standing == .offRoute)
    }

    /// The whole reason confirmation is measured in ground covered rather
    /// than in seconds. A café 90 m off the line is a stop, not a mistake,
    /// and the rider is there for twenty minutes.
    @Test("Standing still off the line never confirms")
    func standingStill() {
        var samples: [(off: Double?, odo: Double)] = [(30, 0), (120, 100)]
        // Forty fixes at the same odometer reading — parked.
        samples += (0..<40).map { _ in (off: Double(120), odo: Double(100)) }
        let (events, state) = run(samples)
        #expect(events.isEmpty)
        #expect(state.standing == .straying)
    }

    @Test("Coming back to the line is announced once")
    func rejoins() {
        let (events, state) = run([
            (30, 0), (120, 100), (400, 400), (300, 600),
            (35, 800), (20, 850), (15, 900)
        ])
        #expect(events == [.left, .rejoined])
        #expect(state.standing == .onRoute)
    }

    /// The hysteresis itself. Sitting between the two thresholds — which is
    /// exactly where a parallel service road puts a rider — must not toggle.
    @Test("Between the thresholds, the standing does not flap")
    func hysteresis() {
        var samples: [(off: Double?, odo: Double)] = [(30, 0), (120, 100), (400, 400)]
        // Alternating either side of `leavingM` but never inside
        // `returningM`: still off route, and silent about it.
        for step in 0..<20 {
            samples.append((off: step.isMultiple(of: 2) ? 60 : 110, odo: 400 + Double(step) * 50))
        }
        let (events, state) = run(samples)
        #expect(events == [.left])
        #expect(state.standing == .offRoute)
    }

    /// A free ride, or a fix too far out to project. Not a wrong turn — and
    /// a rider who WAS off route gets the line back put away rather than
    /// left drawn to a route that no longer applies.
    @Test("No line to be off resets, and takes the way back down")
    func noProjection() {
        let (events, state) = run([
            (30, 0), (120, 100), (400, 400), (nil, 500), (nil, 600)
        ])
        #expect(events == [.left, .rejoined])
        #expect(state.standing == .onRoute)
    }

    /// Riding to a planned stop 400 m off the route is not a wrong turn,
    /// and the caller says so by suppressing.
    @Test("A deliberate detour is suppressed, not announced")
    func suppressed() {
        let (events, state) = run([
            (30, 0), (120, 100), (400, 400), (600, 700)
        ], suppressed: true)
        #expect(events.isEmpty)
        #expect(state.standing == .onRoute)
    }

    // MARK: - The way back

    private func straightLine() -> ([CLLocationCoordinate2D], [Double]) {
        let line = (0..<200).map {
            CLLocationCoordinate2D(latitude: 47.0, longitude: 11.0 + Double($0) * 0.001)
        }
        return (line, RouteGeometry.cumulativeDistances(line))
    }

    @Test("The way back aims ahead of the rider, never at the nearest point")
    func aimsAhead() throws {
        let (line, cumulative) = straightLine()
        let total = try #require(cumulative.last)
        let target = try #require(RideOffRoute.rejoinTarget(
            line: line, cumulative: cumulative, fraction: 0.5, dayTo: 1
        ))
        let here = try #require(RouteGeometry.point(
            on: line, cumulative: cumulative, atMetres: total * 0.5
        ))
        let ahead = RouteGeometry.distance(here, target)
        #expect(abs(ahead - RideOffRoute.rejoinLeadM) < 20)
        #expect(target.longitude > here.longitude)
    }

    /// A rider off the line on the last kilometre is sent to where the day
    /// stops, not to a point on tomorrow's stretch.
    @Test("The way back stops at the day's end")
    func clampsToTheDay() throws {
        let (line, cumulative) = straightLine()
        let total = try #require(cumulative.last)
        let dayTo = 0.5
        let target = try #require(RideOffRoute.rejoinTarget(
            line: line, cumulative: cumulative, fraction: 0.49, dayTo: dayTo
        ))
        let end = try #require(RouteGeometry.point(
            on: line, cumulative: cumulative, atMetres: total * dayTo
        ))
        #expect(RouteGeometry.distance(target, end) < 5)
    }

    @Test("At the day's end there is nothing to rejoin")
    func nothingLeft() {
        let (line, cumulative) = straightLine()
        #expect(RideOffRoute.rejoinTarget(
            line: line, cumulative: cumulative, fraction: 0.999, dayTo: 1
        ) == nil)
        #expect(RideOffRoute.rejoinTarget(
            line: [], cumulative: [], fraction: 0.1, dayTo: 1
        ) == nil)
    }
    // MARK: - On foot

    /// Rides a sequence through the machine on `thresholds`, like `run`.
    private func events(
        _ samples: [(off: Double?, odo: Double)], thresholds: RideOffRoute.Thresholds
    ) -> [RideOffRoute.Event] {
        var state = RideOffRoute.State.onRoute
        var events: [RideOffRoute.Event] = []
        for sample in samples {
            let step = RideOffRoute.advance(
                state, offRouteM: sample.off, odometerM: sample.odo,
                suppressed: false, thresholds: thresholds
            )
            state = step.state
            if step.event != .none { events.append(step.event) }
        }
        return events
    }

    /// A hiker 65 m off the path for 200 m has taken the wrong fork; a
    /// cyclist 65 m off the line is on the parallel cycleway. The foot
    /// column exists for exactly this, and it is what hiking and trail
    /// running are given.
    @Test("On foot a smaller, shorter stray is a wrong turn")
    func footConfirmsSooner() {
        let stray: [(off: Double?, odo: Double)] = [
            (10, 0), (65, 40), (65, 100), (65, 170), (65, 240)
        ]
        #expect(RideOffRoute.Thresholds.for(profile: .hiking) == .foot)
        #expect(RideOffRoute.Thresholds.for(profile: .trailrun) == .foot)
        #expect(events(stray, thresholds: .for(profile: .hiking)) == [.left])
        #expect(events(stray, thresholds: .for(profile: .bike)).isEmpty)
    }

    @Test("On foot, coming back to the path is announced once")
    func footRejoins() {
        let trip: [(off: Double?, odo: Double)] = [
            (10, 0), (65, 40), (65, 100), (65, 200), (20, 260), (10, 300)
        ]
        #expect(events(trip, thresholds: .foot) == [.left, .rejoined])
    }
}

import CoreLocation
import Foundation
import Testing

@testable import TrailPhysicsGeo

/// Following a rider along a line that passes itself.
///
/// The bug: standing at the start of a loop, the elevation profile's
/// marker jumped between the two ends of the day. Start and end are the
/// same ground, both projections are right to within float noise, and an
/// unaided nearest-point search picks a different one every fix.
struct RouteGeometryContinuityTests {
    /// An out-and-back: 10 km east, then back over the same ground. Every
    /// point on it has a twin the same distance away and 10 km apart along
    /// the line — the shape that breaks a memoryless projection.
    private func outAndBack() -> ([CLLocationCoordinate2D], [Double]) {
        var line: [CLLocationCoordinate2D] = []
        for step in 0...100 {
            line.append(CLLocationCoordinate2D(
                latitude: 47.0, longitude: 11.0 + Double(step) * 0.001
            ))
        }
        for step in stride(from: 99, through: 0, by: -1) {
            line.append(CLLocationCoordinate2D(
                latitude: 47.0, longitude: 11.0 + Double(step) * 0.001
            ))
        }
        return (line, RouteGeometry.cumulativeDistances(line))
    }

    private let start = CLLocationCoordinate2D(latitude: 47.0, longitude: 11.0)

    /// What the old behaviour did, kept as a statement of the problem: the
    /// free projection at the trailhead can answer either end, and which
    /// one is not something the caller can rely on.
    @Test("Unaided, the trailhead is ambiguous")
    func ambiguous() throws {
        let (line, cumulative) = outAndBack()
        let free = try #require(RouteGeometry.project(start, along: line, cumulative: cumulative))
        // Whichever it picked, the OTHER end is just as close — which is
        // the whole problem. Both are within a metre of the rider.
        #expect(try #require(free.distanceM) < 1)
        #expect(free.fraction < 0.01 || free.fraction > 0.99)
    }

    @Test("Told where the rider was, it keeps them there")
    func staysAtTheStart() throws {
        let (line, cumulative) = outAndBack()
        let projected = try #require(RouteGeometry.project(
            start, along: line, cumulative: cumulative,
            continuingFrom: 0, maxTravelM: 100
        ))
        #expect(projected.fraction < 0.01)
    }

    /// And the same rider standing at the same place on the way BACK is
    /// kept at the end, not dragged to the start.
    @Test("Continuity works in both directions")
    func staysAtTheEnd() throws {
        let (line, cumulative) = outAndBack()
        let total = try #require(cumulative.last)
        let projected = try #require(RouteGeometry.project(
            start, along: line, cumulative: cumulative,
            continuingFrom: total, maxTravelM: 100
        ))
        #expect(projected.fraction > 0.99)
    }

    /// Thirty fixes from the same spot must all answer the same thing.
    /// This is the reported symptom, stated directly: the marker must stop
    /// moving when the rider does.
    @Test("A stationary rider's position does not wander")
    func doesNotFlap() throws {
        let (line, cumulative) = outAndBack()
        var last: Double? = 0
        var fractions: [Double] = []
        for step in 0..<30 {
            // A couple of metres of GPS noise either way.
            let jitter = Double((step % 5) - 2) * 0.00002
            let fix = CLLocationCoordinate2D(
                latitude: 47.0 + jitter, longitude: 11.0 + jitter
            )
            let projected = try #require(RouteGeometry.project(
                fix, along: line, cumulative: cumulative,
                continuingFrom: last, maxTravelM: 100
            ))
            fractions.append(projected.fraction)
            last = projected.fraction * (cumulative.last ?? 0)
        }
        #expect(fractions.allSatisfy { $0 < 0.01 })
    }

    /// The fallback has to stay reachable: a rider put down somewhere else
    /// entirely must not be pinned to where they left off.
    @Test("A real relocation beats continuity")
    func relocationWins() throws {
        let (line, cumulative) = outAndBack()
        // Half way out, while the last known position was the trailhead.
        let elsewhere = CLLocationCoordinate2D(latitude: 47.0, longitude: 11.05)
        let projected = try #require(RouteGeometry.project(
            elsewhere, along: line, cumulative: cumulative,
            continuingFrom: 0, maxTravelM: 100
        ))
        #expect(projected.fraction > 0.1)
        #expect(try #require(projected.distanceM) < 50)
    }

    /// A long gap between fixes widens the window until it is the whole
    /// line, which is what makes a tunnel or a suspended app recover on
    /// its own rather than needing a special case.
    @Test("A wide enough window is the free projection again")
    func wideWindow() throws {
        let (line, cumulative) = outAndBack()
        let elsewhere = CLLocationCoordinate2D(latitude: 47.0, longitude: 11.05)
        let wide = try #require(RouteGeometry.project(
            elsewhere, along: line, cumulative: cumulative,
            continuingFrom: 0, maxTravelM: 1_000_000
        ))
        let free = try #require(RouteGeometry.project(
            elsewhere, along: line, cumulative: cumulative
        ))
        #expect(abs(wide.fraction - free.fraction) < 0.001)
    }

    /// No past — the first fix of a day — is the free projection, and must
    /// not crash or invent a position.
    @Test("With no previous position it is the plain projection")
    func noPast() throws {
        let (line, cumulative) = outAndBack()
        let projected = try #require(RouteGeometry.project(
            start, along: line, cumulative: cumulative,
            continuingFrom: nil, maxTravelM: 500
        ))
        let free = try #require(RouteGeometry.project(start, along: line, cumulative: cumulative))
        #expect(projected.fraction == free.fraction)
    }

    /// A window that falls entirely off the end of the line has nothing to
    /// answer with, and the free projection is used rather than a zero.
    @Test("A window past the end of the line falls back")
    func windowPastTheEnd() throws {
        let (line, cumulative) = outAndBack()
        let total = try #require(cumulative.last)
        let projected = try #require(RouteGeometry.project(
            start, along: line, cumulative: cumulative,
            continuingFrom: total * 10, maxTravelM: 100
        ))
        #expect(try #require(projected.distanceM) < 1)
    }

    /// The plain projection must be untouched — planning, the map's
    /// hit-test and stop placement all depend on it answering globally.
    @Test("The plain projection still searches the whole line")
    func plainIsUnchanged() throws {
        let (line, cumulative) = outAndBack()
        let far = CLLocationCoordinate2D(latitude: 47.0, longitude: 11.09)
        let projected = try #require(RouteGeometry.project(far, along: line, cumulative: cumulative))
        #expect(try #require(projected.distanceM) < 50)
    }
}

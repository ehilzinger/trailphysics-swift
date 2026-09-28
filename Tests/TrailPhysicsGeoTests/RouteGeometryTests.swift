import CoreLocation
import Foundation
import Testing
@testable import TrailPhysicsGeo

/// Route geometry. Everything here is distance-based rather than index-based,
/// which is load-bearing: BRouter emits vertices densely through bends and
/// sparsely along straights, so anything splitting on the index lands hundreds
/// of metres from where it was asked for.
struct RouteGeometryTests {
    private func c(_ lat: Double, _ lng: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }

    @Test("Distance is the spherical measure the web app uses")
    func sphericalDistance() {
        // Munich → Berlin on a 6371 km sphere, as Leaflet measures it.
        let km = RouteGeometry.distance(c(48.1374, 11.5755), c(52.5200, 13.4050)) / 1000
        #expect(abs(km - 504.29) < 0.05)
        // A short east–west hop at 48°N: one millidegree of longitude.
        let short = RouteGeometry.distance(c(48.0, 11.0), c(48.0, 11.001))
        #expect(abs(short - 74.40) < 0.05)
        #expect(RouteGeometry.distance(c(48.0, 11.0), c(48.0, 11.0)) == 0)
        // Symmetric, so a slice measured backwards agrees with one measured
        // forwards.
        #expect(RouteGeometry.distance(c(48.1, 11.2), c(48.3, 11.1))
            == RouteGeometry.distance(c(48.3, 11.1), c(48.1, 11.2)))
    }

    @Test("A fraction between two points follows the great circle")
    func interpolate() {
        let munich = c(48.1374, 11.5755)
        let berlin = c(52.5200, 13.4050)
        let half = RouteGeometry.interpolate(munich, berlin, fraction: 0.5)
        // Equidistant from both ends, which a linear blend of the
        // coordinates is not over 500 km.
        let toStart = RouteGeometry.distance(half, munich)
        let toEnd = RouteGeometry.distance(half, berlin)
        #expect(abs(toStart - toEnd) < 1)
        #expect(abs(toStart + toEnd - RouteGeometry.distance(munich, berlin)) < 1)
        // The great-circle midpoint sits north of the linear one at these
        // latitudes, so the two are genuinely different answers.
        #expect(half.latitude > (munich.latitude + berlin.latitude) / 2)

        // The ends, and a degenerate pair.
        #expect(abs(RouteGeometry.interpolate(munich, berlin, fraction: 0).latitude - munich.latitude) < 1e-9)
        #expect(abs(RouteGeometry.interpolate(munich, berlin, fraction: 1).longitude - berlin.longitude) < 1e-9)
        #expect(abs(RouteGeometry.interpolate(munich, munich, fraction: 0.5).latitude - munich.latitude) < 1e-9)
        // Out of range and non-finite fractions clamp rather than fly off.
        #expect(abs(RouteGeometry.interpolate(munich, berlin, fraction: -3).latitude - munich.latitude) < 1e-9)
        #expect(abs(RouteGeometry.interpolate(munich, berlin, fraction: .nan).latitude - munich.latitude) < 1e-9)
    }

    @Test("WKT is lng-first, and survives an SRID prefix")
    func wkt() {
        let line = [c(48.137, 11.575), c(48.16, 11.62)]
        let wkt = RouteGeometry.toWKT(line)
        #expect(wkt == "LINESTRING(11.575 48.137,11.62 48.16)")
        // Guard the swap specifically — it is silent and total.
        #expect(!wkt.contains("LINESTRING(48.137"))

        let back = RouteGeometry.fromWKT("SRID=4326;" + wkt)
        #expect(back.count == 2)
        #expect(abs(back[0].latitude - 48.137) < 1e-9)
        #expect(abs(back[0].longitude - 11.575) < 1e-9)
    }

    @Test("A straight line keeps its ends, samples between them, and bows the right way")
    func straightLineThroughPoints() throws {
        // Heidelberg to Munich by air: far enough that a straight line in
        // lat/lng and the great circle between the same two points part
        // company, which is the case the offline draft is drawn for.
        let start = c(49.41, 8.69)
        let end = c(48.14, 11.58)
        let line = RouteGeometry.straightLine(through: [start, end])

        #expect(line.count > 20)
        #expect(line.first?.latitude == start.latitude)
        // The last sample is the end point itself, to within the metre
        // the spherical interpolation rounds to.
        #expect(RouteGeometry.distance(try #require(line.last), end) < 1)
        // Every sample is on the way: the length of the drawn line matches
        // the distance between its ends, to a fraction of a percent.
        let direct = RouteGeometry.distance(start, end) / 1000
        #expect(abs(RouteGeometry.lengthKm(line) - direct) < direct * 0.005)
    }

    @Test("A straight line through three points passes through the middle one")
    func straightLineKeepsItsWaypoints() {
        let middle = c(49.0, 9.5)
        let line = RouteGeometry.straightLine(through: [c(49.41, 8.69), middle, c(48.14, 11.58)])
        // The rider's own point is on the line, not smoothed away — the
        // legs are what they placed, in the order they placed them.
        let nearest = line.map { RouteGeometry.distance($0, middle) }.min() ?? .infinity
        #expect(nearest < 1)
    }

    @Test("A leg long enough to need thousands of samples is capped")
    func straightLineCapsItsSamples() {
        // A quarter of the way round the world at one sample per km would
        // be ten thousand vertices for a line nobody can see the detail
        // of; the cap is what keeps a mis-tap from that.
        let line = RouteGeometry.straightLine(through: [c(49.41, 8.69), c(-33.87, 151.21)])
        #expect(line.count <= 401)
    }

    @Test("Simplify caps the count and keeps the true endpoints")
    func simplify() {
        let line = (0..<1000).map { c(48 + Double($0) * 0.001, 11) }
        let simplified = RouteGeometry.simplify(line)
        #expect(simplified.count == RouteGeometry.maxRoutePoints)
        // The corridor has to cover the real start and finish.
        #expect(simplified.first?.latitude == line.first?.latitude)
        #expect(simplified.last?.latitude == line.last?.latitude)
    }

    @Test("A short line is left alone")
    func simplifyShort() {
        let line = [c(48, 11), c(48.1, 11.1)]
        #expect(RouteGeometry.simplify(line).count == 2)
    }

    /// The import thinning: a recording's run of near-collinear fixes
    /// along a straight collapses to its ends, while a real bend keeps
    /// its vertex. Indices, so an elevation array can be thinned to match.
    @Test("Douglas–Peucker keeps bends and both ends, drops the straight's fixes")
    func douglasPeucker() {
        // A straight run east along 48°N, a fix every ~7 m, with one vertex
        // pushed ~30 m north halfway along.
        var line = (0...100).map { c(48.0, 11.0 + Double($0) * 0.0001) }
        line[50] = c(48.0 + 30 / 111_000, 11.005)
        let kept = RouteGeometry.simplifiedIndices(line, toleranceM: 3)
        #expect(kept.first == 0)
        #expect(kept.last == 100)
        #expect(kept.contains(50))
        // The bend and the ends stay, plus the vertex either side of the
        // bend — the flat run's last fix before a 30 m spike sits almost
        // the full 30 m off the chord that leads up to it — and the other
        // 96 fixes on the straight go.
        #expect(kept == [0, 49, 50, 51, 100])

        // Within tolerance, nothing moves enough to matter.
        line[50] = c(48.0 + 1 / 111_000, 11.005)
        #expect(RouteGeometry.simplifiedIndices(line, toleranceM: 3) == [0, 100])

        // Two points, or a zero tolerance: untouched.
        #expect(RouteGeometry.simplifiedIndices([c(48, 11), c(48.1, 11.1)], toleranceM: 3) == [0, 1])
        #expect(RouteGeometry.simplifiedIndices(line, toleranceM: 0).count == line.count)
    }

    /// Slicing must be distance-based. A line whose vertices bunch at one end
    /// would give a wildly wrong split on an index-based cut.
    @Test("Slicing at the halfway fraction cuts by distance, not by index")
    func sliceByDistance() {
        // Nine vertices packed into the first 10% of the line, then one long
        // straight — the shape BRouter actually produces around a bend.
        var line = (0..<9).map { c(48 + Double($0) * 0.001, 11) }
        line.append(c(48.1, 11))

        let half = RouteGeometry.slice(line, from: 0, to: 0.5)
        let halfKm = RouteGeometry.lengthKm(half)
        let fullKm = RouteGeometry.lengthKm(line)
        #expect(abs(halfKm - fullKm / 2) < 0.01)
        // An index-based cut would have taken 5 of 10 points, which is ~4% of
        // the distance — the failure this guards against.
        #expect(halfKm > fullKm * 0.4)
    }

    @Test("Two slices cover the line with no gap and no overlap")
    func sliceSeam() {
        let line = (0..<50).map { c(48 + Double($0) * 0.002, 11) }
        let first = RouteGeometry.slice(line, from: 0, to: 0.4)
        let second = RouteGeometry.slice(line, from: 0.4, to: 1)
        let seamGap = RouteGeometry.distance(first.last!, second.first!)
        #expect(seamGap < 1)  // metres — day 2 starts where day 1 ended
        let total = RouteGeometry.lengthKm(first) + RouteGeometry.lengthKm(second)
        #expect(abs(total - RouteGeometry.lengthKm(line)) < 0.01)
    }

    @Test("A fraction resolves to a point on the line")
    func pointAtFraction() {
        let line = [c(48, 11), c(48, 11.1)]
        let mid = RouteGeometry.point(on: line, atFraction: 0.5)
        #expect(abs((mid?.longitude ?? 0) - 11.05) < 1e-6)
        #expect(RouteGeometry.point(on: line, atFraction: 0)?.longitude == 11)
        // Out-of-range fractions clamp rather than run off the end.
        #expect(RouteGeometry.point(on: line, atFraction: 2)?.longitude == 11.1)
    }

    /// The reverse of `point(on:atFraction:)`: where along the line a
    /// coordinate sits. Projection onto SEGMENTS is the point of the
    /// function — a straight has no interior vertices, so nearest-vertex
    /// snaps a mid-straight grab to whichever end is closer.
    @Test("A coordinate projects onto the nearest segment, not the nearest vertex")
    func fractionAlongLine() {
        // One long straight with no interior vertices at all.
        let line = [c(48, 11), c(48, 12)]
        let cumulative = RouteGeometry.cumulativeDistances(line)
        // A grab beside the 30% mark must land near 0.3 — nearest-vertex
        // would have answered 0 (the start is closer than the finish).
        let grab = c(48.001, 11.3)
        let fraction = RouteGeometry.fraction(of: grab, along: line, cumulative: cumulative)
        #expect(abs(fraction - 0.3) < 0.01)

        // On a vertex, the answer is that vertex's own fraction.
        let bent = [c(48, 11), c(48, 11.1), c(48.1, 11.1)]
        let bentCumulative = RouteGeometry.cumulativeDistances(bent)
        let atCorner = RouteGeometry.fraction(of: c(48, 11.1), along: bent, cumulative: bentCumulative)
        #expect(abs(atCorner - bentCumulative[1] / bentCumulative[2]) < 0.001)

        // Endpoints clamp to 0 and 1 even for points off the line's ends.
        #expect(RouteGeometry.fraction(of: c(48, 10.5), along: line, cumulative: cumulative) == 0)
        #expect(RouteGeometry.fraction(of: c(48, 12.5), along: line, cumulative: cumulative) == 1)

        // Degenerate input answers rather than crashing.
        #expect(RouteGeometry.fraction(of: grab, along: [c(48, 11)], cumulative: [0]) == 1)
    }
}

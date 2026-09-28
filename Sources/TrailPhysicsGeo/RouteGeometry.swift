import CoreLocation
import Foundation

/// Geometry over a route line. The port of the measurement half of `gpx.js`.
///
/// Everything here is distance-based rather than index-based, and that is
/// load-bearing rather than stylistic: BRouter emits vertices densely through
/// bends and sparsely along straights, so anything that splits or interpolates
/// on the vertex index lands hundreds of metres from where it was asked for —
/// and considerably further on a winding route.
public enum RouteGeometry {
    /// The most points a corridor query's LINESTRING carries — **per chunk**,
    /// not per route.
    ///
    /// A planned route comes back from BRouter with thousands of vertices, and
    /// corridor search does not need metre-precision geometry. Only
    /// `stopsNearRoute` reads the simplified line; everything the rider sees or
    /// exports — the map line, the saved route, the GPX, the distance — reads
    /// the full one.
    ///
    /// Per chunk is what makes this a resolution rather than a budget. Spent
    /// over a whole route it degrades with length: 300 points across 400 km is
    /// a vertex every 1.3 km, and the server buffers the CHORDS between them,
    /// not the road. On a bend a chord can sit several hundred metres inside
    /// the real line, so a "2 km corridor" stops being 2 km from the road the
    /// rider will actually ride and stops on the outside of curves fall out of
    /// it. Against a 50 km chunk the same 300 points are a vertex every 170 m,
    /// which no corridor radius can notice.
    public static let maxRoutePoints = 300

    /// Earth's mean radius in metres — Leaflet's `L.CRS.Earth.R`, so a
    /// distance measured here matches what the web app shows for the same
    /// route.
    private static let earthRadiusM = 6_371_000.0

    /// Metres between two coordinates, on the same spherical measure the web
    /// app uses via Leaflet's `L.CRS.Earth` — a haversine on doubles.
    ///
    /// Not `CLLocation.distance(from:)`. That allocates two `CLLocation`
    /// objects and runs a geodesic per call, and this function is the inner
    /// loop of every length, slice, cumulative-distance and corridor
    /// deviation over routes of thousands of vertices — several of which ran
    /// per SwiftUI render. The pure form is ~20× cheaper, allocates nothing,
    /// and is actually the closer match to the web app's figures, which are
    /// spherical too.
    public static func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let dLat = lat2 - lat1
        let dLng = (b.longitude - a.longitude) * .pi / 180
        let sinLat = sin(dLat / 2)
        let sinLng = sin(dLng / 2)
        let h = sinLat * sinLat + cos(lat1) * cos(lat2) * sinLng * sinLng
        return 2 * earthRadiusM * asin(min(1, sqrt(h)))
    }

    /// The point a fraction of the way from `a` to `b` along the great
    /// circle between them.
    ///
    /// Spherical rather than a linear blend of the two coordinates, because
    /// the one caller — `Router`'s split coarse pass — uses it over hundreds
    /// of kilometres, where the linear midpoint sits tens of kilometres off
    /// the shortest path and would seed the corridor with a detour nobody
    /// asked for. Falls back to the linear blend for a pair too close
    /// together for the spherical form to be stable, where the two answers
    /// agree to well under a metre anyway.
    public static func interpolate(
        _ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D, fraction: Double
    ) -> CLLocationCoordinate2D {
        let t = min(1, max(0, fraction.isFinite ? fraction : 0))
        let lat1 = a.latitude * .pi / 180, lng1 = a.longitude * .pi / 180
        let lat2 = b.latitude * .pi / 180, lng2 = b.longitude * .pi / 180
        let angle = distance(a, b) / earthRadiusM
        guard angle > 1e-9 else {
            return CLLocationCoordinate2D(
                latitude: a.latitude + (b.latitude - a.latitude) * t,
                longitude: a.longitude + (b.longitude - a.longitude) * t
            )
        }
        let sinAngle = sin(angle)
        let from = sin((1 - t) * angle) / sinAngle
        let to = sin(t * angle) / sinAngle
        let x = from * cos(lat1) * cos(lng1) + to * cos(lat2) * cos(lng2)
        let y = from * cos(lat1) * sin(lng1) + to * cos(lat2) * sin(lng2)
        let z = from * sin(lat1) + to * sin(lat2)
        return CLLocationCoordinate2D(
            latitude: atan2(z, (x * x + y * y).squareRoot()) * 180 / .pi,
            longitude: atan2(y, x) * 180 / .pi
        )
    }

    /// The straight great-circle line through `points`, sampled about every
    /// `stepM` metres — the shape a route has when there is no connection
    /// to ask the router for roads (`RoutePlanModel.drawStraightLegs`).
    ///
    /// Sampled rather than left as one segment per pair, for two reasons:
    /// a two-point leg spanning a few hundred kilometres draws as a
    /// straight line on screen where the great circle it stands for bows
    /// noticeably, and every reader of a route here — the day splitter, the
    /// elevation scrub, the ride's progress — measures along the vertices
    /// it is given. `maxPoints` keeps a continental hop from producing tens
    /// of thousands of them.
    public static func straightLine(
        through points: [CLLocationCoordinate2D], stepM: Double = 1_000,
        maxPointsPerLeg: Int = 400
    ) -> [CLLocationCoordinate2D] {
        guard points.count >= 2 else { return points }
        var line: [CLLocationCoordinate2D] = [points[0]]
        for (start, end) in zip(points, points.dropFirst()) {
            let metres = distance(start, end)
            let steps = min(maxPointsPerLeg, max(1, Int((metres / max(stepM, 1)).rounded(.up))))
            for step in 1...steps {
                line.append(interpolate(start, end, fraction: Double(step) / Double(steps)))
            }
        }
        return line
    }

    public static func lengthKm(_ line: [CLLocationCoordinate2D]) -> Double {
        guard line.count > 1 else { return 0 }
        var total = 0.0
        for index in 1..<line.count {
            total += distance(line[index - 1], line[index])
        }
        return total / 1000
    }

    /// Cumulative distance to each vertex, in metres. The same measure
    /// `lengthKm` uses, so anything derived from it — a slice, a point at a
    /// fraction — cannot disagree with the total it is a fraction of.
    public static func cumulativeDistances(_ line: [CLLocationCoordinate2D]) -> [Double] {
        guard !line.isEmpty else { return [] }
        var cumulative = [0.0]
        cumulative.reserveCapacity(line.count)
        for index in 1..<line.count {
            cumulative.append(cumulative[index - 1] + distance(line[index - 1], line[index]))
        }
        return cumulative
    }

    /// The point `metres` along the line, interpolated between the vertices it
    /// falls between. Linear interpolation in lat/lng is accurate at the scale
    /// of a single route segment, which is all this ever spans.
    // MARK: - Thinning

    /// Douglas-Peucker: the same line with the vertices that say nothing
    /// removed, none of them moving further than `toleranceM` from where
    /// the line ran.
    ///
    /// BRouter emits a vertex wherever the underlying way has one, which
    /// on a straight of rural road is a dozen points that a ruler would
    /// have drawn with two. That is the right thing to route on and the
    /// wrong thing to KEEP: a stored recommendation is about 2,000
    /// vertices and 33 KB, and the cache holds one per loop per bucket
    /// per cell for a whole country.
    ///
    /// Measured over 18 stored loops (36,809 vertices) from the seeded
    /// cache: at 1 m 54 % of the vertices survive, at 2 m 39 %, at 3 m
    /// 32 %, at 5 m 24 %, at 10 m 17 %. What it costs is length, since
    /// every shortcut is a chord: −15 m at 1 m tolerance, −88 m at 3 m,
    /// −375 m at 10 m, on loops of about 70 km. Three metres is where
    /// this is used — a third of the storage for 0.13 % of the distance,
    /// and a line that never moves further than a good GPS fix wanders.
    /// The points `simplifiedIndices` keeps. A caller with a parallel
    /// array (elevations) must thin by the indices instead, or the two
    /// stop lining up.
    public static func simplified(
        _ line: [CLLocationCoordinate2D], toleranceM: Double
    ) -> [CLLocationCoordinate2D] {
        simplifiedIndices(line, toleranceM: toleranceM).map { line[$0] }
    }

    // MARK: - Bearings

    /// Initial great-circle bearing, degrees clockwise from north.
    ///
    /// Here rather than beside the ride-day code that first needed it
    /// (`RideStops`, which still forwards to this): the recommendation
    /// engine reads bearings to place a loop's stops around its start,
    /// and `RideStops` reaches for the map's stop repository, which is a
    /// dependency the engine cannot take — `tools/seeder` links these
    /// files outside the app. Geometry belongs with geometry.
    public static func bearing(
        from: CLLocationCoordinate2D, to: CLLocationCoordinate2D
    ) -> Double {
        let φ1 = from.latitude * .pi / 180
        let φ2 = to.latitude * .pi / 180
        let Δλ = (to.longitude - from.longitude) * .pi / 180
        let y = sin(Δλ) * cos(φ2)
        let x = cos(φ1) * sin(φ2) - sin(φ1) * cos(φ2) * cos(Δλ)
        return (atan2(y, x) * 180 / .pi).truncatingRemainder(dividingBy: 360)
    }

    /// The smaller of the two ways round between two bearings, 0…180.
    public static func bearingDelta(from course: Double, to target: Double) -> Double {
        let raw = abs((target - course).truncatingRemainder(dividingBy: 360))
        return raw > 180 ? 360 - raw : raw
    }

    public static func point(
        on line: [CLLocationCoordinate2D],
        cumulative: [Double],
        atMetres metres: Double
    ) -> CLLocationCoordinate2D? {
        guard let first = line.first, let last = line.last,
              let total = cumulative.last else { return nil }
        if metres <= 0 { return first }
        if metres >= total { return last }

        for index in 1..<cumulative.count where cumulative[index] >= metres {
            let segment = cumulative[index] - cumulative[index - 1]
            let t = segment > 0 ? (metres - cumulative[index - 1]) / segment : 0
            let a = line[index - 1], b = line[index]
            return CLLocationCoordinate2D(
                latitude: a.latitude + (b.latitude - a.latitude) * t,
                longitude: a.longitude + (b.longitude - a.longitude) * t
            )
        }
        return last
    }

    /// Where a 0..1 fraction along the route falls.
    ///
    /// `cumulative`, when the caller already has one (a per-frame scrub
    /// drag, or slicing several day spans off the same line), skips
    /// re-walking the whole line's haversine distances again — that walk is
    /// O(n) over what can be thousands of vertices, so recomputing it once
    /// per fraction queried is the difference between a smooth scrub
    /// gesture and a stuttering one. Defaults to computing it when the
    /// caller has nothing cached.
    public static func point(
        on line: [CLLocationCoordinate2D], atFraction fraction: Double,
        cumulative: [Double]? = nil
    ) -> CLLocationCoordinate2D? {
        guard !line.isEmpty else { return nil }
        guard line.count > 1 else { return line[0] }
        let clamped = min(1, max(0, fraction.isFinite ? fraction : 0))
        let cumulative = cumulative ?? cumulativeDistances(line)
        guard let total = cumulative.last, total > 0 else { return line[0] }
        return point(on: line, cumulative: cumulative, atMetres: total * clamped)
    }

    /// How far along the line a coordinate sits, 0..1, by projecting it onto
    /// the nearest SEGMENT — not the nearest vertex. The distinction matters
    /// for the same reason the map's screen-space hit-test measures to
    /// segments: BRouter emits no vertices at all along a straight, so the
    /// nearest-vertex answer in the middle of a long straight snaps to
    /// whichever end happens to be closer — sometimes kilometres from where
    /// the finger actually is.
    ///
    /// Projection is done in a local equirectangular frame centred on the
    /// query point (longitude scaled by cos of its latitude), which is exact
    /// at the scale of one route segment; `cumulative` is trusted rather
    /// than recomputed, for the callers that already cache it.
    public static func fraction(
        of coordinate: CLLocationCoordinate2D,
        along line: [CLLocationCoordinate2D],
        cumulative: [Double]
    ) -> Double {
        project(coordinate, along: line, cumulative: cumulative)?.fraction ?? 1
    }

    /// The same projection, returning the offset it already measured on the
    /// way to the answer.
    ///
    /// The walk below finds the nearest point on the line by keeping the
    /// smallest squared distance it has seen — so "how far along" and "how
    /// far off" fall out of one pass. Asking for them separately meant two
    /// passes over the same thousands of vertices, and the second one
    /// (`RouteCorridor.distanceToSegment`, a haversine with four trig calls
    /// and a `sqrt` per segment) measured **8.8×** the cost of this one on
    /// an 8 000-vertex line — for a number this pass was already holding.
    /// That ran per GPS fix for the whole length of a ride, screen off, on
    /// battery. See docs/performance-audit-2026-09-03.md, RIDE-1.
    ///
    /// `distanceM` is the planar length of the winning offset scaled back
    /// out of the local frame — the same equirectangular approximation the
    /// projection itself is built on, and accurate well inside the tolerance
    /// of every caller ("is this fix on the route", "how far off the line is
    /// this stop"). Nil when there is no line to measure against, which is
    /// the case `fraction` answers 1 for.
    public static func project(
        _ coordinate: CLLocationCoordinate2D,
        along line: [CLLocationCoordinate2D],
        cumulative: [Double]
    ) -> (fraction: Double, distanceM: Double?)? {
        project(coordinate, along: line, cumulative: cumulative, fromM: nil, toM: nil)
    }

    // MARK: - Projecting a rider, who has a past

    /// How much closer the free answer must be before continuity is given
    /// up.
    ///
    /// The ambiguity being resolved is two points on the line at almost the
    /// same distance from the rider, so the tolerance only has to exceed
    /// the noise that makes them almost-equal — which is GPS error, up to
    /// about fifty metres in a street of tall buildings. A hundred and
    /// fifty is comfortably past that and far short of a real relocation,
    /// where the free answer is closer by hundreds of metres or more.
    public static let continuityToleranceM: Double = 150

    /// The smallest window a rider is ever searched in.
    ///
    /// Two consecutive fixes a second apart could not put a rider more than
    /// a few tens of metres along the line, but the window also has to
    /// absorb GPS noise and a stationary rider drifting, so it never
    /// narrows below half a kilometre.
    public static let minimumContinuityWindowM: Double = 500

    /// Where a RIDER is along the line, given where they were.
    ///
    /// `project(_:along:cumulative:)` takes whichever point on the line is
    /// nearest and has no memory at all, which is right for placing a stop
    /// and wrong for following a rider. On a loop or an out-and-back the
    /// start and the end are the same ground: both answers are correct to
    /// within float noise, and an unaided projection picks a different one
    /// every fix. Standing at the trailhead, the elevation profile's marker
    /// jumps between the two ends of the day, the distance to go flickers
    /// between the whole day and none of it, and the speed window reads the
    /// gap as ground covered.
    ///
    /// So the rider is looked for near where they last were, and the free
    /// answer only wins when it is closer by more than
    /// `continuityToleranceM` — which a genuine relocation always is, and
    /// an ambiguous loop end never is.
    ///
    /// **The fallback has to stay reachable.** A rider who is put down
    /// somewhere else entirely — resumed forty kilometres along, carried
    /// through a long tunnel, restarted after a lift — must not be pinned
    /// to where they left off. That is what the tolerance comparison is
    /// for, and it is why this asks for the free answer on every fix
    /// rather than only when the window fails.
    ///
    /// - Parameters:
    ///   - lastMetres: where the rider was last found along the line. Nil
    ///     on the first fix of a day, which falls through to the free
    ///     projection — and is why a ride seeds this with the day's own
    ///     start rather than leaving it empty.
    ///   - maxTravelM: how far they could plausibly have moved since. The
    ///     caller owns this because it is a question about riding, not
    ///     about geometry: `RideSession` computes it from the gap between
    ///     fixes and the profile's speed ceiling, so a long gap widens the
    ///     window until it is effectively the whole line again.
    public static func project(
        _ coordinate: CLLocationCoordinate2D,
        along line: [CLLocationCoordinate2D],
        cumulative: [Double],
        continuingFrom lastMetres: Double?,
        maxTravelM: Double
    ) -> (fraction: Double, distanceM: Double?)? {
        let free = project(coordinate, along: line, cumulative: cumulative)
        guard let lastMetres, maxTravelM.isFinite else { return free }

        let window = max(minimumContinuityWindowM, maxTravelM)
        guard let near = project(
            coordinate, along: line, cumulative: cumulative,
            fromM: lastMetres - window, toM: lastMetres + window
        ) else { return free }

        // Either distance missing means one of the two could not be
        // measured, and an unmeasurable answer cannot win a comparison.
        guard let nearM = near.distanceM, let freeM = free?.distanceM else { return near }
        return nearM - freeM > continuityToleranceM ? free : near
    }

    /// The projection itself, over the whole line or a stretch of it.
    ///
    /// `fromM`/`toM` are metres along the line; nil is unbounded. A segment
    /// is considered when any part of it falls inside, so a window never
    /// excludes the ground its own endpoints stand on.
    private static func project(
        _ coordinate: CLLocationCoordinate2D,
        along line: [CLLocationCoordinate2D],
        cumulative: [Double],
        fromM: Double?,
        toM: Double?
    ) -> (fraction: Double, distanceM: Double?)? {
        guard line.count >= 2, cumulative.count == line.count,
              let total = cumulative.last, total > 0 else { return nil }

        let cosLat = cos(coordinate.latitude * .pi / 180)
        // The query point is the local origin, so a vertex's offset from it
        // IS the vector the projection needs.
        func offset(_ point: CLLocationCoordinate2D) -> (x: Double, y: Double) {
            (
                (point.longitude - coordinate.longitude) * cosLat,
                point.latitude - coordinate.latitude
            )
        }

        var bestDistanceSquared = Double.infinity
        var bestMetres = 0.0
        var found = false
        for index in 1..<line.count {
            if let toM, cumulative[index - 1] > toM { break }
            if let fromM, cumulative[index] < fromM { continue }
            found = true
            let a = offset(line[index - 1])
            let b = offset(line[index])
            let dx = b.x - a.x, dy = b.y - a.y
            let lengthSquared = dx * dx + dy * dy
            var t = 0.0
            if lengthSquared > 0 {
                // Vector a→origin dotted with a→b, clamped into the segment.
                t = max(0, min(1, (-a.x * dx - a.y * dy) / lengthSquared))
            }
            let px = a.x + t * dx, py = a.y + t * dy
            let distanceSquared = px * px + py * py
            if distanceSquared < bestDistanceSquared {
                bestDistanceSquared = distanceSquared
                bestMetres = cumulative[index - 1]
                    + t * (cumulative[index] - cumulative[index - 1])
            }
        }
        // Degrees back to metres: one degree of latitude on the same sphere
        // `distance(_:_:)` measures on, and the frame already carries the
        // longitude scaling. Nil rather than NaN when nothing was measurable
        // — a fix that arrives as NaN must read as "no answer", never as a
        // distance of zero.
        // A window that fell off the end of the line has no answer to
        // give, and must say so rather than report the zero it started at.
        guard found else { return nil }
        let metresPerDegree = earthRadiusM * .pi / 180
        return (
            fraction: min(1, max(0, bestMetres / total)),
            distanceM: bestDistanceSquared.isFinite
                ? sqrt(bestDistanceSquared) * metresPerDegree
                : nil
        )
    }

    /// The portion of a route between two 0..1 fractions — one day of a
    /// multi-day trip (Phase 5), or one leg for export.
    ///
    /// Both ends are interpolated onto the line rather than snapped to the
    /// nearest vertex, so day 2 starts exactly where day 1 ended and the two
    /// together cover the route with no gap and no overlap.
    ///
    /// `cumulative`, when passed, is trusted rather than recomputed — the
    /// caller slicing a route into several days would otherwise redo this
    /// same O(n) walk once per day for a value that doesn't change between
    /// them.
    public static func slice(
        _ line: [CLLocationCoordinate2D], from: Double, to: Double,
        cumulative: [Double]? = nil
    ) -> [CLLocationCoordinate2D] {
        guard line.count >= 2 else { return [] }
        let start = min(1, max(0, from))
        let end = min(1, max(0, to))
        guard end > start else { return [] }

        let cumulative = cumulative ?? cumulativeDistances(line)
        guard let total = cumulative.last, total > 0 else { return line }

        let fromM = total * start
        let toM = total * end

        var out: [CLLocationCoordinate2D] = []
        if let head = point(on: line, cumulative: cumulative, atMetres: fromM) {
            out.append(head)
        }
        for index in line.indices where cumulative[index] > fromM && cumulative[index] < toM {
            out.append(line[index])
        }
        if let tail = point(on: line, cumulative: cumulative, atMetres: toM) {
            out.append(tail)
        }
        return out
    }

    /// Evenly samples a long point list down to a manageable size, keeping the
    /// true endpoints so the corridor covers the real start and finish.
    public static func simplify(
        _ line: [CLLocationCoordinate2D], maxPoints: Int = maxRoutePoints
    ) -> [CLLocationCoordinate2D] {
        guard line.count > maxPoints, maxPoints >= 2 else { return line }
        let step = Double(line.count - 1) / Double(maxPoints - 1)
        var out = (0..<maxPoints).map { line[Int((Double($0) * step).rounded())] }
        out[0] = line[0]
        out[out.count - 1] = line[line.count - 1]
        return out
    }

    /// One stretch of a route, and where it sits in the whole.
    public struct Chunk: Sendable {
        public var line: [CLLocationCoordinate2D]
        /// Distance fractions of the FULL route, so a position measured
        /// within `line` maps back with
        /// `startFraction + position * (endFraction - startFraction)`.
        public var startFraction: Double
        public var endFraction: Double
    }

    /// Splits a route into contiguous stretches of about `targetKm` each.
    ///
    /// Contiguous is the load-bearing word. Neighbouring chunks share their
    /// boundary point exactly (`slice` interpolates both ends onto the line
    /// rather than snapping to a vertex), and the union of a fixed-radius
    /// buffer around each is exactly the buffer around the whole line. So a
    /// per-chunk corridor search covers the same ground as one search over
    /// the whole route — no seam, no gap, and duplicates near the joints,
    /// which is the direction it is safe to be wrong in.
    ///
    /// `maxChunks` bounds the fan-out rather than the route: past it the
    /// chunks simply grow again. What must not grow far is the chunk itself —
    /// the server's buffer cost is superlinear in the length of the line it is
    /// given, and a long enough line hits the statement timeout — so the
    /// ceiling is set to keep the chunks short rather than to keep the request
    /// count down. See `RouteRepository.maxCorridorChunks`.
    public static func chunks(
        _ line: [CLLocationCoordinate2D], targetKm: Double, maxChunks: Int
    ) -> [Chunk] {
        guard line.count >= 2, targetKm > 0, maxChunks >= 1 else {
            return line.isEmpty ? [] : [Chunk(line: line, startFraction: 0, endFraction: 1)]
        }
        let cumulative = cumulativeDistances(line)
        let totalKm = (cumulative.last ?? 0) / 1000
        let wanted = Int(ceil(totalKm / targetKm))
        let count = min(maxChunks, max(1, wanted))
        guard count > 1 else { return [Chunk(line: line, startFraction: 0, endFraction: 1)] }

        return (0..<count).compactMap { index in
            let start = Double(index) / Double(count)
            let end = Double(index + 1) / Double(count)
            let piece = slice(line, from: start, to: end, cumulative: cumulative)
            // A slice can come back with a single point where the route
            // doubles back on itself within one chunk's span; there is no
            // LINESTRING to buffer around it, and its neighbours' buffers
            // already cover the ground.
            guard piece.count >= 2 else { return nil }
            return Chunk(line: piece, startFraction: start, endFraction: end)
        }
    }

    /// Which vertices of a line survive a Douglas–Peucker pass at
    /// `toleranceM`: a vertex is kept only where dropping it would move the
    /// line more than that far. Returns INDICES rather than points so a
    /// parallel array (an imported track's elevations) can be thinned to
    /// match — the two have to stay aligned index-for-index, and that is
    /// only guaranteed if the same selection is applied to both.
    ///
    /// Distances are measured in a local equirectangular frame centred on
    /// the line's midpoint, exact at the scale of one route. Both ends are
    /// always kept. An explicit stack rather than recursion: a hundred-
    /// thousand-point recording would otherwise recurse to a depth the
    /// main thread's stack can't be trusted with.
    public static func simplifiedIndices(
        _ line: [CLLocationCoordinate2D], toleranceM: Double
    ) -> [Int] {
        guard line.count > 2, toleranceM > 0 else { return Array(line.indices) }
        let midLat = ((line.first?.latitude ?? 0) + (line.last?.latitude ?? 0)) / 2
        let metresPerDegLat = 2 * .pi * earthRadiusM / 360
        let metresPerDegLng = metresPerDegLat * cos(midLat * .pi / 180)
        let xs = line.map { $0.longitude * metresPerDegLng }
        let ys = line.map { $0.latitude * metresPerDegLat }

        var keep = [Bool](repeating: false, count: line.count)
        keep[0] = true
        keep[line.count - 1] = true
        var stack: [(Int, Int)] = [(0, line.count - 1)]
        while let (first, last) = stack.popLast() {
            guard last - first > 1 else { continue }
            let ax = xs[first], ay = ys[first]
            let dx = xs[last] - ax, dy = ys[last] - ay
            let lengthSquared = dx * dx + dy * dy
            var farthest = first
            var farthestSquared = 0.0
            for index in (first + 1)..<last {
                let px = xs[index] - ax, py = ys[index] - ay
                let distanceSquared: Double
                if lengthSquared > 0 {
                    // Perpendicular distance to the chord, via the cross
                    // product — a vertex past either end still measures to
                    // the chord's line, which is what the classic pass does.
                    let cross = px * dy - py * dx
                    distanceSquared = cross * cross / lengthSquared
                } else {
                    // The chord's ends coincide (a loop closed on itself):
                    // measure to the point instead.
                    distanceSquared = px * px + py * py
                }
                if distanceSquared > farthestSquared {
                    farthestSquared = distanceSquared
                    farthest = index
                }
            }
            if farthestSquared > toleranceM * toleranceM {
                keep[farthest] = true
                stack.append((first, farthest))
                stack.append((farthest, last))
            }
        }
        return keep.indices.filter { keep[$0] }
    }

    // MARK: - WKT

    /// `LINESTRING(lng lat, …)` — **longitude first**, as PostGIS expects.
    // MARK: - Waypoint slots

    /// Which waypoint slot a grab at `fraction` along the line falls into.
    ///
    /// Here rather than on `RoutePlanModel`, where it was written and where
    /// `insertIndex(for:)` still forwards to it from: the drag preview in
    /// `MapContainerView` needs it, and that view compiles into the App Clip
    /// (`genproj.py`'s `SHARED_WITH_CLIP`) where the plan model does not
    /// exist. Pure arithmetic over a fraction and a count, so this is where
    /// it belonged anyway.
    ///
    /// The measured form: `waypointFractions` is where each waypoint
    /// actually sits on the line, so the preview joins the same pair the
    /// reroute will run between.
    public static func insertIndex(
        for fraction: Double, waypointFractions: [Double], isRoundtrip: Bool = false
    ) -> Int {
        let count = waypointFractions.count
        guard count >= 2 else { return 1 }
        for index in 1..<count where fraction < waypointFractions[index] {
            return index
        }
        return isRoundtrip ? count : count - 1
    }

    /// The even-spread estimate, for when no line has been drawn yet — with
    /// geometry on screen the measured form above is used instead.
    public static func insertIndex(for fraction: Double, waypointCount: Int) -> Int {
        guard waypointCount >= 2 else { return 1 }
        let slot = Int((fraction * Double(waypointCount - 1)).rounded(.down)) + 1
        return min(max(slot, 1), waypointCount - 1)
    }

    public static func toWKT(_ line: [CLLocationCoordinate2D]) -> String {
        let points = line.map { "\($0.longitude) \($0.latitude)" }.joined(separator: ",")
        return "LINESTRING(\(points))"
    }

    /// `POLYGON((lng lat, …))` — closes the ring itself if the caller
    /// didn't, since `ST_GeomFromText` throws on an unclosed one and a
    /// tapped-out set of vertices has no reason to already repeat its
    /// first point.
    public static func toPolygonWKT(_ vertices: [CLLocationCoordinate2D]) -> String {
        var ring = vertices
        if let first = ring.first, let last = ring.last,
           first.latitude != last.latitude || first.longitude != last.longitude {
            ring.append(first)
        }
        let points = ring.map { "\($0.longitude) \($0.latitude)" }.joined(separator: ",")
        return "POLYGON((\(points)))"
    }

    /// Standard ray-casting point-in-polygon test — used client-side to
    /// filter a bbox-fetched batch of stops down to the ones actually
    /// inside a rider-drawn polygon (`RegionCache.download(polygon:...)`).
    /// The exact server-side check (`ST_Contains`) is what decides the
    /// live "N stops inside" count while drawing; this only needs to agree
    /// with it closely enough that a downloaded region matches what the
    /// rider saw, which a ray cast does for any simple polygon.
    public static func contains(_ point: CLLocationCoordinate2D, polygon: [CLLocationCoordinate2D]) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var j = polygon.count - 1
        for i in 0..<polygon.count {
            let vi = polygon[i], vj = polygon[j]
            if (vi.latitude > point.latitude) != (vj.latitude > point.latitude),
               point.longitude < (vj.longitude - vi.longitude) * (point.latitude - vi.latitude)
                   / (vj.latitude - vi.latitude) + vi.longitude {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    public static func fromWKT(_ wkt: String) -> [CLLocationCoordinate2D] {
        // Tolerates an SRID prefix, which is how `routes.path` comes back.
        var text = wkt
        if let semicolon = text.firstIndex(of: ";"), text.hasPrefix("SRID=") {
            text = String(text[text.index(after: semicolon)...])
        }
        guard let open = text.firstIndex(of: "("), let close = text.lastIndex(of: ")") else {
            return []
        }
        let inner = text[text.index(after: open)..<close]
        return inner.split(separator: ",").compactMap { pair in
            let parts = pair.trimmingCharacters(in: .whitespaces)
                .split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2,
                  let lng = Double(parts[0]), let lat = Double(parts[1]) else { return nil }
            return CLLocationCoordinate2D(latitude: lat, longitude: lng)
        }
    }
}

import CoreLocation
import Foundation

/// Reading a stored elevation profile — the whole route's climb, thinned to
/// about 48 points, the kind of array a watch's ride plan carries to the
/// wrist and a Live Activity's state carries to the lock screen.
///
/// Pure arithmetic over that one array so it can be tested without a plan, a
/// snapshot or a route — the watch asks it "how much is left to climb
/// between here and the next stop", nothing more.
public enum RideProfileMath {
    /// Metres still to climb between two fractions of the WHOLE route —
    /// the axis a ride's route position and its day bounds are measured on,
    /// not the day's.
    ///
    /// - Parameters:
    ///   - line: the route's coordinates, when the caller has them, so the
    ///     fractions can be placed on the profile by real distance rather
    ///     than assumed to be evenly spread. Nil takes the proportional
    ///     fallback below.
    /// - Returns: nil when the profile cannot answer at all — fewer than two
    ///   points, or `to` at or before `from`. Otherwise the summed ascent,
    ///   which is 0 for a flat or descending stretch.
    public static func ascent(
        elevations: [Double], line: [CLLocationCoordinate2D]?,
        from: Double, to: Double
    ) -> Double? {
        guard elevations.count > 1 else { return nil }
        let start = min(1, max(0, from))
        let end = min(1, max(0, to))
        guard end > start else { return nil }

        if let line,
           let cumulative = RouteElevation.anchorDistances(latlngs: line, elevations: elevations),
           let total = cumulative.last, total > 0 {
            // `anchorDistances` places each sample at the vertex it was
            // really taken from, honest about BRouter's uneven spacing
            // through bends and along straights — the same reason
            // `RouteElevation.selection` and `maxInclinePct` insist on it
            // rather than a fraction of the count.
            return ascent(elevations: elevations, anchors: cumulative, fromM: total * start, toM: total * end)
        }

        // The fallback, and it is one: `anchorDistances` answers nil
        // whenever the elevations outnumber the vertices, which thinning
        // the line to a 10 m tolerance for the wrist makes routine rather
        // than rare — a long route's ~48-point profile can easily end up
        // denser than the thinned line that crossed to the wrist. A
        // proportional split assumes those samples are spread evenly along
        // the route, which BRouter's own bunching at bends means they are
        // not, but the error is at most a few hundred metres of profile on
        // a figure that is already a forecast — "climbing to go" for a stop
        // still a day away — not a live reading measured off the ground.
        let fromIndex = Int((Double(elevations.count - 1) * start).rounded())
        let toIndex = Int((Double(elevations.count - 1) * end).rounded())
        return RouteElevation.ascent(elevations, from: fromIndex, through: toIndex)
    }

    /// Metres still to climb between two distances along the route, on a
    /// profile already placed along it — `anchors[i]` is how far along the
    /// route `elevations[i]` was taken (`RouteElevation.anchorDistances`).
    ///
    /// A live "climb to the next stop" can ask this once a fix: the anchors
    /// are worked out once per day, since walking a long route's cumulative
    /// distances on every fix is a cost a watch in particular cannot
    /// afford.
    ///
    /// - Returns: nil when the two arrays do not describe one profile, or
    ///   `toM` is not past `fromM`; otherwise the summed ascent, 0 when the
    ///   stretch between them has no sample going up.
    public static func ascent(elevations: [Double], anchors: [Double], fromM: Double, toM: Double) -> Double? {
        guard elevations.count > 1, anchors.count == elevations.count, toM > fromM else { return nil }
        let fromIndex = ceilIndex(anchors, atMetres: fromM)
        let toIndex = floorIndex(anchors, atMetres: toM)
        guard toIndex > fromIndex else { return 0 }
        return RouteElevation.ascent(elevations, from: fromIndex, through: toIndex)
    }

    /// How coarse this profile is, in kilometres per sample, so a caller can
    /// refuse to draw a figure the data cannot support — the same judgement
    /// `RouteElevation.maxInclineSpacingM` makes for a max-incline reading,
    /// because a stored profile is always about 48 points however long the
    /// route is: a few hundred metres apart on a day ride, kilometres apart
    /// on a multi-week tour, and a gradient or an ascent read across samples
    /// that far apart describes an average, not the climb a rider is
    /// actually looking at.
    ///
    /// `.infinity` for a profile with nothing to measure — the coarsest
    /// answer there is, so a threshold comparison refuses it the same way it
    /// refuses a real but very sparse profile, with no special case at the
    /// call site.
    public static func sampleSpacingKm(elevations: [Double], routeKm: Double) -> Double {
        guard elevations.count > 1, routeKm.isFinite, routeKm > 0 else { return .infinity }
        return routeKm / Double(elevations.count - 1)
    }

    /// A fraction exactly at a vertex (a day boundary sitting on the route's
    /// own halfway point, say) multiplies back out to `target` by a
    /// different arithmetic path than the one that built `cumulative`
    /// itself, and the two can differ by a few ULPs of floating rounding —
    /// enough to put `target` a hair on the wrong side of the vertex it was
    /// meant to land on. A millimetre of slack absorbs that without being
    /// able to move which REAL vertex either index picks.
    private static let boundaryEpsilonM: Double = 0.001

    /// The first index at or past `target` metres along `cumulative` — the
    /// vertex a "from" fraction lands on or just after, so the summed range
    /// starts no earlier than asked.
    private static func ceilIndex(_ cumulative: [Double], atMetres target: Double) -> Int {
        for index in cumulative.indices where cumulative[index] >= target - boundaryEpsilonM { return index }
        return cumulative.count - 1
    }

    /// The last index at or before `target` metres — the mirror of
    /// `ceilIndex`, so a "to" fraction never pulls in ground past what was
    /// asked for.
    private static func floorIndex(_ cumulative: [Double], atMetres target: Double) -> Int {
        var index = 0
        for candidate in cumulative.indices where cumulative[candidate] <= target + boundaryEpsilonM { index = candidate }
        return index
    }
}

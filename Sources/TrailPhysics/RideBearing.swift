import CoreLocation
import Foundation

/// Which way, in words a rider can act on without reading a compass — and
/// the nearest thing to a turn instruction a watch can honestly give when
/// it has no router of its own and the plan it carries has no manoeuvres.
///
/// `RouteGeometry` already carries the bearing arithmetic this needs:
/// `bearing(from:to:)` for the true bearing between two points, and
/// `bearingDelta(from:to:)` for how far apart two bearings are, 0…180,
/// UNSIGNED. That unsigned form is enough to say how far off course
/// something is but not which way to turn it — the entire point of a wrist
/// glance — so `relative` below is its signed twin rather than a rewrite of
/// it, and cannot simply call it for the same reason `bearingDelta` doesn't
/// return a sign in the first place: which side of a `Double` boundary the
/// wrap falls on is exactly the information `bearingDelta` throws away.
public enum RideBearing {
    /// Where a bearing lies relative to the way the rider is pointing,
    /// −180…180, negative left.
    ///
    /// `bearing` is normalised into 0…360 here rather than upstream —
    /// `RouteGeometry.bearing`'s own `truncatingRemainder` can come back
    /// negative, and every caller of it inherits that, so this is where the
    /// wrap gets handled rather than a second place doing it differently.
    ///
    /// Nil when `course` is nil or negative. CoreLocation reports a negative
    /// course whenever it does not have one — which includes a rider at a
    /// standstill, so the same guard covers both "no course yet" and "no
    /// course right now" without the caller having to tell them apart.
    public static func relative(bearing: Double, course: Double?) -> Double? {
        guard let course, course >= 0 else { return nil }
        let normalized = normalizeBearing(bearing)
        return signedAngleDelta(from: course, to: normalized)
    }

    /// Six directions a rider can act on, an even 60° each, because a rider
    /// glancing at a dimmed wrist needs a direction to act on, not a heading
    /// to the degree. The words are the caller's: this says which sector.
    public enum Direction: String, Sendable, CaseIterable {
        case ahead, right, behindRight, left, behindLeft, behind
    }

    /// The sector a signed relative bearing (−180…180, negative left) falls in.
    public static func direction(relative: Double) -> Direction {
        switch relative {
        case -30..<30: return .ahead
        case 30..<90: return .right
        case 90..<150: return .behindRight
        case -90..<(-30): return .left
        case -150..<(-90): return .behindLeft
        default: return .behind
        }
    }

    /// One bend on the line, found by `nextTurn`.
    public struct Turn: Equatable, Sendable {
        public var metresAway: Double
        /// Signed, negative left — the same convention `relative` uses.
        public var degrees: Double
        public var isLeft: Bool { degrees < 0 }
    }

    /// A stub of a segment below this length is decimation noise, not a
    /// direction. A route's line is thinned to a 10 m tolerance before it
    /// crosses to the wrist, and Douglas-Peucker
    /// can still leave a short chord right where two long, nearly-straight
    /// runs meet — its bearing describes that chord, not the road.
    private static let minSegmentM: Double = 3

    /// Below this, a run of turning is still zero as far as this function is
    /// concerned — floating-point wobble from the haversine bearing, not a
    /// direction change, and without a floor here a dead-straight road would
    /// spuriously "start a bend" at every single vertex.
    private static let noiseFloorDegrees: Double = 0.5

    /// The next bend on the line worth calling out, walking forward from
    /// `fromMetres`.
    ///
    /// **What this is not.** There is no router on the wrist and the
    /// watch's ride plan carries no manoeuvres, so the only source of
    /// direction is the shape of the line the wrist already holds. This
    /// cannot name a road, and it cannot tell a real junction from a bend
    /// the road simply takes — a sweeping motorway-style curve reads exactly
    /// like a corner, because to this function that is all a turn ever is.
    ///
    /// A bend spread across several kept vertices — an accumulation of small
    /// same-direction turns rather than one sharp one — is walked as a
    /// single run: the run's heading change is summed vertex to vertex, and
    /// reported once, positioned at the run's OWN start rather than at
    /// whichever vertex happened to push the total past `minDegrees`. A
    /// reversal partway through — the road briefly straightening or kinking
    /// the other way — starts a fresh run rather than letting two opposite
    /// bends cancel each other into nothing.
    ///
    /// - Parameters:
    ///   - cumulative: `RouteGeometry.cumulativeDistances(line)`, trusted
    ///     rather than recomputed — every caller here already has it for the
    ///     rider's own position.
    ///   - within: how far ahead to look before giving up.
    ///   - minDegrees: the smallest heading change worth calling a turn.
    /// - Returns: nil for a straight line, a gentle curve that never passes
    ///   `minDegrees` inside `within`, or nothing ahead to walk at all.
    public static func nextTurn(
        line: [CLLocationCoordinate2D], cumulative: [Double],
        fromMetres: Double, within: Double, minDegrees: Double
    ) -> Turn? {
        guard line.count == cumulative.count, line.count >= 3,
              let total = cumulative.last, total > fromMetres
        else { return nil }
        let limit = min(total, fromMetres + within)
        guard let startIndex = cumulative.firstIndex(where: { $0 >= fromMetres }) else { return nil }

        // Every segment long enough to have an opinion about direction,
        // in order, with where along the line each one starts.
        var segments: [(startM: Double, bearing: Double)] = []
        var index = startIndex
        while index < line.count - 1, cumulative[index] <= limit {
            let lengthM = cumulative[index + 1] - cumulative[index]
            if lengthM >= minSegmentM {
                segments.append((
                    startM: cumulative[index],
                    bearing: normalizeBearing(RouteGeometry.bearing(from: line[index], to: line[index + 1]))
                ))
            }
            index += 1
        }
        guard segments.count >= 2 else { return nil }

        // Overwritten on the loop's first pass regardless — `accumulated`
        // starts at zero, which is always below `noiseFloorDegrees` — so
        // this initial value never actually reaches a `return`.
        var runStartM = segments[0].startM
        var accumulated = 0.0
        for i in 1..<segments.count {
            let delta = signedAngleDelta(from: segments[i - 1].bearing, to: segments[i].bearing)
            let reversed = delta != 0 && (delta > 0) != (accumulated > 0)
            if abs(accumulated) < noiseFloorDegrees || reversed {
                // Nothing accumulating yet, or the road just turned back the
                // other way: `segments[i]` — not `i - 1` — is the vertex
                // where the CURRENT run starts, because that is the corner
                // itself: the point where the heading actually begins to
                // change, not the straight run leading up to it.
                runStartM = segments[i].startM
                accumulated = delta
            } else {
                accumulated += delta
            }
            if abs(accumulated) >= minDegrees {
                return Turn(metresAway: runStartM - fromMetres, degrees: accumulated)
            }
        }
        return nil
    }

    /// `RouteGeometry.bearing`'s own `truncatingRemainder` can come back
    /// negative; every reader of a bearing in this file goes through here so
    /// only one place does the wrap.
    private static func normalizeBearing(_ bearing: Double) -> Double {
        let wrapped = bearing.truncatingRemainder(dividingBy: 360)
        return wrapped < 0 ? wrapped + 360 : wrapped
    }

    /// The signed way round from one bearing to another, −180…180 — what
    /// `RouteGeometry.bearingDelta` deliberately doesn't answer, because it
    /// only ever needs "how far", never "which way".
    private static func signedAngleDelta(from: Double, to: Double) -> Double {
        var delta = (to - from).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        return delta
    }
}

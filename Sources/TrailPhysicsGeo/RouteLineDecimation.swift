import CoreLocation
import Foundation

/// How much of a long route's geometry is actually worth DRAWING at the
/// zoom it is being read at.
///
/// BRouter emits a vertex wherever the underlying way has one. Measured
/// against a live BRouter instance on 2026-09-17, a 537 km Munich–Milan
/// answer came back with 13,835 vertices — 25.8 per kilometre — so a
/// fortnight's tour is tens of thousands, and a map that draws a casing
/// under the line draws all of them TWICE, since the casing carries the
/// same geometry. MapKit walks every one of those points each time it
/// re-rasterises an overlay tile, which is what a pan is, and that is the
/// lag a long route acquires.
///
/// Framed to fit a phone, almost none of those vertices are separate
/// places. At the zoom that 537 km route fits a ~390 pt screen one screen
/// point is a little over a kilometre, so a half-point tolerance leaves 121
/// of the 13,835 — measured on the same answer, along with 602 at 100 m and
/// 1,699 at 25 m for the zooms in between. The line the rider sees is
/// unchanged, because everything taken out was inside a pixel of what is
/// left.
///
/// Only the DRAWN copy is thinned. The route itself stays at full
/// resolution and everything measured off it — length, ascent, day breaks,
/// the corridor query, the ride's own projection, what gets saved — still
/// reads the real geometry.
public enum RouteLineDecimation {
    /// Below this many vertices a route is drawn exactly as it came,
    /// whatever the zoom. A day ride is a few hundred points and MapKit
    /// draws it without noticing; the thinning is for the other end.
    public static let floor = 2_000

    /// How far a drawn vertex may stray from where the route really runs,
    /// as a fraction of one screen point. Half a point is under the
    /// smallest thing any display can show, so the thinned line and the
    /// real one are the same picture.
    public static let pointFraction = 0.5

    /// The tolerance to thin at, in metres, or zero for "draw everything".
    ///
    /// Bucketed to powers of two so an ordinary pinch crosses a handful of
    /// buckets rather than asking for a new line on every step of itself.
    ///
    /// Zero for a short line, and for any zoom close enough that the
    /// tolerance would be under a metre: there is nothing left to take out
    /// at that point, and the walk to find that out is not worth paying
    /// for.
    public static func toleranceM(pointCount: Int, metresPerPoint: Double) -> Double {
        guard pointCount > floor, metresPerPoint > 0 else { return 0 }
        let wanted = metresPerPoint * pointFraction
        guard wanted >= 1 else { return 0 }
        return exp2(log2(wanted).rounded(.down))
    }

    /// `line` thinned to `toleranceM`, or `line` itself at zero.
    ///
    /// Douglas–Peucker, which keeps both ends of every stretch it touches —
    /// so a day segment thinned on its own still starts and finishes
    /// exactly where its neighbours do.
    public static func thinned(
        _ line: [CLLocationCoordinate2D], toleranceM: Double
    ) -> [CLLocationCoordinate2D] {
        guard toleranceM > 0, line.count > 2 else { return line }
        return RouteGeometry.simplified(line, toleranceM: toleranceM)
    }

    /// The day segments end to end, dropping the vertex each one repeats
    /// from the tail of the one before it — the casing for a split route,
    /// built from the very segments drawn over it so it cannot peek out at
    /// a bend where two separate thinnings chose different vertices.
    public static func joined(
        _ segments: [[CLLocationCoordinate2D]]
    ) -> [CLLocationCoordinate2D] {
        var out: [CLLocationCoordinate2D] = []
        for segment in segments {
            guard let first = segment.first else { continue }
            if let last = out.last,
               last.latitude == first.latitude, last.longitude == first.longitude {
                out.append(contentsOf: segment.dropFirst())
            } else {
                out.append(contentsOf: segment)
            }
        }
        return out
    }
}

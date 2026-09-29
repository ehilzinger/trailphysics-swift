import Foundation
import CoreLocation

/// A lat/lng rectangle, plus the zoom conversion MapKit doesn't give us.
///
/// A Leaflet map reads `map.getZoom()` directly because Leaflet works in
/// integer Web Mercator zoom levels. MapKit works in coordinate *spans*, so
/// the threshold that decides between individual stops and server aggregates
/// has to be derived. Getting this wrong is not cosmetic — it either floods the
/// client with rows past the 1000 cap (showing a disc of stops with empty
/// corners) or renders count bubbles when real markers would fit.
public struct BoundingBox: Sendable, Hashable, Codable {
    public var minLat: Double
    public var minLng: Double
    public var maxLat: Double
    public var maxLng: Double

    public init(minLat: Double, minLng: Double, maxLat: Double, maxLng: Double) {
        self.minLat = minLat
        self.minLng = minLng
        self.maxLat = maxLat
        self.maxLng = maxLng
    }

    /// A square box circumscribing a circle of `radiusMeters` around `center`.
    /// Used to turn "warm a circle around the rider" into the rectangle a
    /// cache and a bounding-box query actually key on — the corners hold a
    /// little more than the circle asked for, which only means a prefetch
    /// warms slightly more ground than strictly requested, never less.
    public init(center: CLLocationCoordinate2D, radiusMeters: Double) {
        let metersPerDegreeLat = 111_320.0
        let metersPerDegreeLng = 111_320.0 * cos(center.latitude * .pi / 180)
        let dLat = radiusMeters / metersPerDegreeLat
        // Near the poles cos() approaches 0; falling back to the latitude
        // delta keeps the box square-ish instead of exploding to ±180°.
        let dLng = metersPerDegreeLng > 1 ? radiusMeters / metersPerDegreeLng : dLat
        minLat = max(center.latitude - dLat, -90)
        maxLat = min(center.latitude + dLat, 90)
        minLng = max(center.longitude - dLng, -180)
        maxLng = min(center.longitude + dLng, 180)
    }

    /// The envelope of a set of points — every one of `coordinates` falls
    /// on or inside the result. `nil` for an empty array, since there is
    /// no box to speak of. Used to turn a rider-drawn polygon into the
    /// bbox a quadrant-paged fetch already knows how to page over.
    public init?(coordinates: [CLLocationCoordinate2D]) {
        guard let first = coordinates.first else { return nil }
        var minLat = first.latitude, maxLat = first.latitude
        var minLng = first.longitude, maxLng = first.longitude
        for coordinate in coordinates.dropFirst() {
            minLat = min(minLat, coordinate.latitude)
            maxLat = max(maxLat, coordinate.latitude)
            minLng = min(minLng, coordinate.longitude)
            maxLng = max(maxLng, coordinate.longitude)
        }
        self.minLat = minLat
        self.maxLat = maxLat
        self.minLng = minLng
        self.maxLng = maxLng
    }

    public var latSpan: Double { maxLat - minLat }
    public var lngSpan: Double { maxLng - minLng }
    public var centerLat: Double { (minLat + maxLat) / 2 }
    public var centerLng: Double { (minLng + maxLng) / 2 }

    /// The middle of the box as a coordinate — for the callers that want a
    /// point rather than two numbers (framing a saved area, measuring which
    /// of several is nearest).
    public var center: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: centerLat, longitude: centerLng)
    }

    public func contains(lat: Double, lng: Double) -> Bool {
        lat >= minLat && lat <= maxLat && lng >= minLng && lng <= maxLng
    }

    /// Whether `other` lies entirely inside this box.
    public func contains(_ other: BoundingBox) -> Bool {
        other.minLat >= minLat && other.maxLat <= maxLat
            && other.minLng >= minLng && other.maxLng <= maxLng
    }

    /// Whether the two boxes share any ground, edges included.
    public func intersects(_ other: BoundingBox) -> Bool {
        other.minLat <= maxLat && other.maxLat >= minLat
            && other.minLng <= maxLng && other.maxLng >= minLng
    }

    /// The Web Mercator zoom level this span corresponds to, matching what
    /// Leaflet would report for the same view.
    ///
    /// Derived from longitude span alone, which is the axis Web Mercator zoom
    /// is actually defined on: the whole world (360°) is one 256px tile at
    /// zoom 0, so zoom = log2(360 / lngSpan) for a 256px-wide viewport, plus
    /// log2(width / 256) for a real one. Latitude span is not usable for this
    /// — Mercator stretches it with latitude, so the same physical zoom gives
    /// a different latitude span in Munich than in Oslo.
    /// - Parameter viewportWidthPoints: how wide the map drawing this box
    ///   actually is. See `defaultViewportWidthPoints` for what it means to
    ///   leave it out.
    public func approximateZoom(viewportWidthPoints: Double = Double(Self.defaultViewportWidthPoints)) -> Int {
        guard lngSpan > 0 else { return 20 }
        let tilesAcross = 360.0 / lngSpan
        let zoom = log2(tilesAcross * viewportWidthPoints / 256.0)
        return Int(zoom.rounded())
    }

    /// The viewport width assumed when nobody says — a prefetch around a
    /// coordinate, a seeded region, a test.
    ///
    /// It used to be the only answer, and the comment here argued for that:
    /// the threshold it feeds is a data decision (which query to run), so
    /// letting it vary by device would mean a tablet and a phone disagree
    /// about whether the same map view is clustered.
    ///
    /// That invariant was the wrong one, and a tablet showed it. Clustering
    /// exists so markers do not pile up ON SCREEN, which is a question about
    /// points per degree, not about degrees. Two devices showing the same
    /// longitude span are not showing the same view: the wider screen is
    /// spreading it over more points, so its markers are further apart and
    /// it needs clustering LESS. Holding the width at 390 made the
    /// comparison come out the other way round — a 1032 pt tablet
    /// under-reported its zoom by log2(1032/390), about 1.4 levels, so a map
    /// the rider had zoomed well past the threshold was still asking the
    /// server for grid cells and getting a lattice of bubbles back over
    /// stops that had drawn correctly a moment earlier.
    ///
    /// Now the caller says, and the two devices agree about the same VIEW,
    /// which is what the rider is comparing.
    public static let defaultViewportWidthPoints = 390

    /// Expands the box by `factor` times its own span on every side. Used to
    /// warm the cache around the visible area.
    public func padded(by factor: Double) -> BoundingBox {
        let dLat = latSpan * factor
        let dLng = lngSpan * factor
        return BoundingBox(
            minLat: max(minLat - dLat, -90),
            minLng: max(minLng - dLng, -180),
            maxLat: min(maxLat + dLat, 90),
            maxLng: min(maxLng + dLng, 180)
        )
    }
}

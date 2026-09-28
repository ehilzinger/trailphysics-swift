import Testing
@testable import TrailPhysicsGeo

/// Map views work in coordinate spans, tile servers and cluster grids in
/// integer Web Mercator zoom levels; `approximateZoom` is the conversion, and
/// everything downstream of it (which query runs, whether a row cap bites)
/// keys off it.
struct BoundingBoxTests {
    @Test("Whole-world span reads as zoom 0-ish")
    func worldSpan() {
        let box = BoundingBox(minLat: -85, minLng: -180, maxLat: 85, maxLng: 180)
        // 390pt viewport is ~1.5 tiles wide, so a full-world view sits just
        // above 0 rather than exactly at it.
        #expect(box.approximateZoom() <= 1)
    }

    @Test("A city-block span is a high zoom")
    func blockSpan() {
        let box = BoundingBox(
            minLat: 48.1370, minLng: 11.5750, maxLat: 48.1390, maxLng: 11.5780
        )
        #expect(box.approximateZoom() >= 15)
    }

    /// Latitude span is deliberately not used for the zoom derivation —
    /// Mercator stretches it with latitude, so the same physical zoom yields a
    /// different latitude span in Oslo than in Munich. Same longitude span
    /// must give the same zoom regardless of where it sits.
    @Test("Zoom depends on longitude span, not latitude")
    func latitudeIndependence() {
        let munich = BoundingBox(minLat: 48.10, minLng: 11.50, maxLat: 48.14, maxLng: 11.60)
        let oslo = BoundingBox(minLat: 59.90, minLng: 10.70, maxLat: 59.94, maxLng: 10.80)
        #expect(munich.approximateZoom() == oslo.approximateZoom())
    }

    /// The bug an iPad found: the same box on a wider map is a HIGHER zoom,
    /// because zoom is about how many points a degree is spread over.
    ///
    /// Held at a phone's 390 pt, a 1032 pt iPad under-reported by about 1.4
    /// levels, so a view the rider had zoomed past the threshold still asked
    /// for the server's cluster grid — and a lattice of bubbles replaced
    /// stops that had drawn correctly a moment before.
    @Test("A wider map reads the same box as a higher zoom")
    func widerViewportIsHigherZoom() {
        let box = BoundingBox(minLat: 48.10, minLng: 11.50, maxLat: 48.14, maxLng: 11.60)
        let phone = box.approximateZoom(viewportWidthPoints: 390)
        let tablet = box.approximateZoom(viewportWidthPoints: 1_032)
        #expect(tablet > phone)
        // log2(1032/390) is 1.4, so one or two levels once rounded.
        #expect(tablet - phone == 1 || tablet - phone == 2)
    }

    @Test("Omitting the width is the phone's answer")
    func defaultMatchesAPhone() {
        // Every caller with no map to ask — a prefetch, an intent, a seeded
        // region — keeps the behaviour it always had.
        let box = BoundingBox(minLat: 48.10, minLng: 11.50, maxLat: 48.14, maxLng: 11.60)
        #expect(
            box.approximateZoom()
                == box.approximateZoom(
                    viewportWidthPoints: Double(BoundingBox.defaultViewportWidthPoints)
                )
        )
    }

    @Test("Padding expands on every side")
    func padding() {
        let box = BoundingBox(minLat: 10, minLng: 10, maxLat: 11, maxLng: 11)
        let padded = box.padded(by: 2)
        #expect(padded.minLat == 8)
        #expect(padded.maxLat == 13)
        #expect(padded.lngSpan > box.lngSpan)
    }

    @Test("contains matches the rectangle")
    func contains() {
        let box = BoundingBox(minLat: 48, minLng: 11, maxLat: 49, maxLng: 12)
        #expect(box.contains(lat: 48.5, lng: 11.5))
        #expect(!box.contains(lat: 47.9, lng: 11.5))
        #expect(!box.contains(lat: 48.5, lng: 12.1))
    }
}

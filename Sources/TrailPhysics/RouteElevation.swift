import CoreLocation
import Foundation

/// Elevation figures for a route: the steepest sustained incline and a
/// resampled profile to draw. The arithmetic half of `route-stats.js` in
/// Hatchure's web implementation, kept pure so the tests can feed it a
/// synthetic climb.
public enum RouteElevation {
    /// A profile ready to draw: `points` are (distance fraction 0…1, metres).
    public struct Profile: Equatable {
        public var points: [(x: Double, y: Double)]
        public var minM: Double
        public var maxM: Double
        public var totalKm: Double

        public init(points: [(x: Double, y: Double)], minM: Double, maxM: Double, totalKm: Double) {
            self.points = points
            self.minM = minM
            self.maxM = maxM
            self.totalKm = totalKm
        }

        public static func == (lhs: Profile, rhs: Profile) -> Bool {
            lhs.minM == rhs.minM && lhs.maxM == rhs.maxM
                && lhs.totalKm == rhs.totalKm && lhs.points.count == rhs.points.count
        }
    }

    /// The smallest unbroken rise that counts as a climb, in metres. Below
    /// this a rise is the elevation model's own noise, not terrain.
    ///
    /// 5 m, and the web implementation's own figure — chosen there by
    /// measuring against BRouter's filtered ascent on four real routes
    /// rather than by picking a round number. Unfiltered summation over a
    /// full-resolution BRouter profile, which is what an earlier version
    /// did, banks every one of thousands of sub-metre wobbles: measured on
    /// a 546 km tour it reported 6280 m against a true 4200. A thinned
    /// 240-point profile has the opposite error and under-reports, which is
    /// why a route's ascent is best measured on the full profile and kept,
    /// not recomputed from the thinned one.
    public static let minClimbM: Double = 5

    /// Total metres climbed over a profile, with rises under `minClimbM`
    /// discarded as jitter — the web implementation's `ascentFrom`, walked
    /// the same way: a rise accumulates until the first descent, and is
    /// banked only if it amounted to a real climb.
    ///
    /// Meant to be the one implementation of this arithmetic. A route's
    /// total, a single day's figure and a suggested route's summary each
    /// once had their own copy, and all three summed every positive delta.
    public static func ascent(_ elevations: [Double]?) -> Double? {
        guard let elevations, elevations.count > 1 else { return nil }
        return ascent(elevations, from: 0, through: elevations.count - 1)
    }

    /// The same over one slice, `from` and `through` being inclusive
    /// indices — a single riding day, measured without carrying a rise in
    /// from the day before it.
    public static func ascent(_ elevations: [Double], from: Int, through: Int) -> Double {
        let first = max(1, from + 1)
        let last = min(through, elevations.count - 1)
        guard first <= last else { return 0 }
        var total = 0.0
        var rising = 0.0
        for index in first...last {
            let delta = elevations[index] - elevations[index - 1]
            if delta > 0 {
                rising += delta
            } else if delta < 0 {
                if rising >= minClimbM { total += rising }
                rising = 0
            }
        }
        if rising >= minClimbM { total += rising }
        return total
    }

    /// The window a gradient is measured over. Under this, vertex spacing and
    /// the elevation model's own resolution dominate and the number is noise.
    public static let inclineWindowM: Double = 100

    /// The most points a stored profile holds. The profile is thinned to the
    /// chart's resolution before writing, and anything longer is outside the
    /// accepted shape — a full BRouter track (thousands of vertices) is
    /// ~30 KB of JSON to reproduce sub-pixel detail, where this is a little
    /// over 1 KB.
    public static let maxStoredPoints = 240

    /// Thins an elevation array to what the profile chart actually draws and
    /// rounds to whole metres, for storing alongside a saved route — the web
    /// implementation's `profileForStorage`, so a profile stored from here
    /// has the same shape as one stored from the web and fits the same limit.
    ///
    /// Sub-metre precision goes too: BRouter's model is quantised to the
    /// metre anyway, so the decimals were never real. Nil for anything with
    /// no profile to store, which is what leaves the stored profile empty.
    public static func profileForStorage(_ elevations: [Double]?) -> [Double]? {
        guard let elevations, elevations.count >= 2 else { return nil }
        return sample(elevations, max: maxStoredPoints).map { $0.rounded() }
    }

    /// Every `max`-th-ish value, first and last always kept — the web
    /// implementation's `sample()`, index for index, because reading a stored profile back
    /// (`anchorDistances`) inverts exactly this stride.
    public static func sample(_ values: [Double], max: Int) -> [Double] {
        guard values.count > max, max >= 2 else { return values }
        let step = Double(values.count - 1) / Double(max - 1)
        return (0..<max).map { values[Int((Double($0) * step).rounded())] }
    }

    /// The distance along the line each elevation belongs to.
    ///
    /// The elevation array is walked, not the geometry, and the two are
    /// different lengths whenever the route came back from storage:
    /// `profileForStorage` thinned it. Each elevation index maps to the
    /// vertex it was sampled from by inverting `sample`'s stride —
    /// deliberately NOT a proportional split of the total distance, because
    /// BRouter emits vertices densely through bends and sparsely along
    /// straights, so assuming even spacing put samples hundreds of metres
    /// from their real position and inflated gradients by half again.
    ///
    /// Nil when the elevations can't be placed at all: none, fewer than two,
    /// or more of them than there are vertices.
    public static func anchorDistances(
        latlngs: [CLLocationCoordinate2D], elevations: [Double]?
    ) -> [Double]? {
        guard let elevations, elevations.count > 1, latlngs.count > 1,
              elevations.count <= latlngs.count
        else { return nil }
        let cumulative = RouteGeometry.cumulativeDistances(latlngs)
        if elevations.count == latlngs.count { return cumulative }
        let stride = Double(latlngs.count - 1) / Double(elevations.count - 1)
        return (0..<elevations.count).map {
            cumulative[min(latlngs.count - 1, Int((Double($0) * stride).rounded()))]
        }
    }

    // MARK: - Missing samples

    /// The most route a run of missing samples may span before a profile is
    /// given up on rather than interpolated.
    ///
    /// BRouter omits the third coordinate for any node it has no elevation
    /// for, and one such node used to discard the whole route's profile —
    /// which is why long routes were the ones that lost their ascent figure:
    /// the chance of meeting a single unmapped node grows with every
    /// kilometre, and the penalty was the same whether one sample was
    /// missing or a thousand.
    ///
    /// 2 km, because that is about the shortest gap over which a straight
    /// line between two known heights can still hide a real climb. Anything
    /// longer is terrain nobody measured, and drawing it would put invented
    /// metres into the ascent total.
    public static let maxGapM: Double = 2_000

    /// The share of samples that may be missing before the profile is
    /// refused outright, however short the individual gaps are. A route
    /// peppered with holes is one whose elevation model does not cover it,
    /// and a repaired profile there would be mostly this function's own
    /// arithmetic rather than the ground.
    public static let maxMissingShare = 0.2

    /// Fills the holes in a partial elevation array, or refuses.
    ///
    /// Interior gaps are interpolated **by distance** rather than by index,
    /// the same placement `anchorDistances` uses and for the same reason:
    /// BRouter's vertices bunch at bends, so an index-wise fill puts its
    /// invented heights in the wrong place. A gap at either end holds the
    /// nearest known height flat — there is nothing to interpolate towards,
    /// and a flat stretch adds no ascent.
    ///
    /// Nil when the array can't be trusted: nothing known, more than
    /// `maxMissingShare` missing, or any single gap longer than `maxGapM`.
    /// Nil is still the answer in those cases, and it means what it always
    /// meant — no profile, no ascent figure — rather than a drawn line that
    /// nobody measured.
    public static func repairing(
        _ values: [Double?], along latlngs: [CLLocationCoordinate2D]
    ) -> [Double]? {
        guard values.count == latlngs.count, values.count > 1 else { return nil }
        var filled = values
        guard let first = filled.firstIndex(where: { $0 != nil }),
              let last = filled.lastIndex(where: { $0 != nil })
        else { return nil }
        let missing = filled.lazy.filter { $0 == nil }.count
        if missing == 0 { return filled.compactMap { $0 } }
        guard Double(missing) / Double(filled.count) <= maxMissingShare else { return nil }

        let cumulative = RouteGeometry.cumulativeDistances(latlngs)

        // The interior runs. Every nil between `first` and `last` has a
        // known sample on both sides by construction, so the pair bracketing
        // each run is what the fill interpolates between.
        var index = first
        while index <= last {
            guard filled[index] == nil else {
                index += 1
                continue
            }
            var end = index
            while end <= last, filled[end] == nil { end += 1 }
            let before = index - 1
            guard let low = filled[before], let high = filled[end],
                  cumulative[end] - cumulative[before] <= maxGapM
            else { return nil }
            let span = cumulative[end] - cumulative[before]
            for hole in index..<end {
                let t = span > 0 ? (cumulative[hole] - cumulative[before]) / span : 0
                filled[hole] = low + (high - low) * t
            }
            index = end
        }

        // The ends, held flat at the nearest known height.
        if first > 0 {
            guard cumulative[first] - cumulative[0] <= maxGapM,
                  let edge = filled[first] else { return nil }
            for hole in 0..<first { filled[hole] = edge }
        }
        if last < filled.count - 1 {
            guard cumulative[filled.count - 1] - cumulative[last] <= maxGapM,
                  let edge = filled[last] else { return nil }
            for hole in (last + 1)..<filled.count { filled[hole] = edge }
        }
        return filled.compactMap { $0 }
    }

    /// How far apart the samples may sit before a gradient measured across
    /// them stops describing a climb.
    ///
    /// A stored profile is 240 points however long the route is
    /// (`maxStoredPoints`), so the spacing grows with the distance: 200 m on
    /// a 50 km ride, but 2.5 km on a 600 km tour. A gradient read across
    /// samples 2.5 km apart is the AVERAGE slope of two and a half
    /// kilometres, and the steepest thing a rider meets on a long tour is a
    /// climb of one or two — averaged in with the valley either side of it,
    /// an alpine pass reads as a gentle drag.
    ///
    /// A kilometre is where that stops: below it the climbs a "max incline"
    /// is about are still resolved, above it they are averaged away. Past
    /// this the answer is nil, which every caller has to handle anyway — a
    /// display simply leaves the row out. Nil is the honest answer here,
    /// and the figure comes back the moment the route is planned again at
    /// full resolution.
    ///
    /// The full-resolution profile that comes off BRouter is never near
    /// this: its vertices are metres apart, which is why the 100 m
    /// `inclineWindowM` exists in the first place.
    public static let maxInclineSpacingM: Double = 1_000

    /// The elevation series with lone outliers taken out: every interior
    /// sample replaced by the median of itself and its two neighbours, both
    /// ends left as measured.
    ///
    /// A real gradient is monotonic across three consecutive samples, so a
    /// median of three leaves every climb and every descent exactly where it
    /// was. A single height the model got wrong is not monotonic — a bridge
    /// deck read as the gorge under it, a tunnel read as the mountain over
    /// it, a node the DEM simply missed — and the median puts it back
    /// between its neighbours.
    ///
    /// Why the gradient reader needs this at all: `inclineWindowM` is 100 m,
    /// and the routes that carry the biggest surprises are the ones whose
    /// vertices are tens of metres apart, so a single 50 m outlier landing
    /// on a window's endpoint IS a 50 % "gradient" as far as the arithmetic
    /// can tell. The minimum window keeps vertex spacing from dominating;
    /// it does nothing about one wrong number, and that is a separate
    /// failure needing a separate answer.
    public static func despiked(_ elevations: [Double]) -> [Double] {
        guard elevations.count > 2 else { return elevations }
        var out = elevations
        for index in 1..<(elevations.count - 1) {
            // Read from the original throughout: a filter fed its own output
            // walks a spike along the line instead of removing it.
            let low = elevations[index - 1]
            let mid = elevations[index]
            let high = elevations[index + 1]
            out[index] = max(min(low, mid), min(max(low, mid), high))
        }
        return out
    }

    /// The steepest sustained gradient on the route, in percent, UPHILL.
    ///
    /// Uphill only, which is what `inclineBand` beside this has always
    /// documented this function as doing and what a "Max incline" figure
    /// means to a rider: an incline is what has to be climbed. It once read
    /// `abs(rise)`, so on a route that drops off a shoulder harder than it
    /// climbs anything — the Rhine valley run down to Chur is one — the
    /// headline gradient was a descent.
    ///
    /// Measured over `despiked` heights: see there for why a minimum window
    /// alone is not enough.
    public static func maxInclinePct(
        latlngs: [CLLocationCoordinate2D], elevations: [Double]?
    ) -> Double? {
        guard let elevations, let cumulative = anchorDistances(latlngs: latlngs, elevations: elevations)
        else { return nil }
        // Too coarse to measure a climb: see `maxInclineSpacingM`.
        if let total = cumulative.last, elevations.count > 1,
           total / Double(elevations.count - 1) > maxInclineSpacingM {
            return nil
        }
        let heights = despiked(elevations)
        var steepest = 0.0
        var start = 0
        for end in 1..<heights.count {
            // Slide the window's start forward until it spans at least the
            // minimum, then read the gradient across it.
            while start < end - 1, cumulative[end] - cumulative[start + 1] >= inclineWindowM {
                start += 1
            }
            let run = cumulative[end] - cumulative[start]
            guard run >= inclineWindowM else { continue }
            let rise = heights[end] - heights[start]
            guard rise > 0 else { continue }
            steepest = max(steepest, rise / run * 100)
        }
        // A flat route with data is 0 %, which is an answer; nil is reserved
        // for "no elevations".
        return steepest
    }

    // MARK: - Incline banding

    /// How hard a stretch is to ride, on a fixed four-step scale. The web
    /// implementation's `INCLINE_BANDS` (`route-stats.js`), ported so the
    /// same GPX bands the same way on both platforms.
    ///
    /// Deliberately free of SwiftUI: the colours live in the view layer, so
    /// this — and the tests that feed it a synthetic climb — stay pure.
    public enum InclineBand: Int, CaseIterable, Equatable {
        case gentle, moderate, hard, severe
    }

    /// The upper bound of each band bar the last, in percent. A gradient at
    /// a threshold lands in the HARDER band — 4 % is the start of moderate,
    /// not the end of gentle, otherwise a sustained 4 % would read as a drag.
    public static let inclineBandThresholds: [Double] = [4, 8, 12]
    /// On foot the same four steps sit much higher: 12 % is a gentle path,
    /// and walking only gets hard past 25 % (the web implementation's foot
    /// bands).
    public static let footInclineBandThresholds: [Double] = [15, 25, 40]

    /// Which band a gradient falls in.
    ///
    /// UPHILL ONLY. A descent takes the gentlest band, matching what
    /// `maxInclinePct` already does and for the same reason: a gradient
    /// figure is about what has to be climbed. Colouring a 10 % descent like
    /// a 10 % climb would make a route that is mostly downhill look
    /// punishing, which is the opposite of true.
    public static func inclineBand(_ pct: Double, thresholds: [Double] = inclineBandThresholds) -> InclineBand {
        // A non-finite gradient — infinity from a zero-length step, or NaN
        // from a missing sample — is MISSING DATA, not an infinitely steep
        // wall, so it takes the gentlest band rather than the harshest.
        // Painting it red would state something about the route that nobody
        // measured.
        guard pct.isFinite, pct > 0 else { return .gentle }
        for (index, threshold) in thresholds.enumerated() where pct < threshold {
            return InclineBand(rawValue: index) ?? .gentle
        }
        return .severe
    }

    /// A run of consecutive profile samples sharing one band. `from` and `to`
    /// index into the points the run was measured over.
    public struct BandRun: Equatable {
        public var band: InclineBand
        public var from: Int
        public var to: Int
    }

    /// The profile split into runs of same-band samples, so the chart can be
    /// filled by steepness — the web implementation's `elevationBandPaths`,
    /// minus the SVG.
    ///
    /// Each run starts at the previous one's LAST index rather than the next
    /// one: that shared edge point is what keeps adjoining bands seamless.
    /// Without it the fills show hairlines of background between them.
    ///
    /// Gradient is measured against real distance rather than the index —
    /// `points` are sampled evenly by distance already (see `profile`), so
    /// one even step in x is one even step in metres.
    public static func bandRuns(
        points: [(x: Double, y: Double)], totalKm: Double, thresholds: [Double] = inclineBandThresholds
    ) -> [BandRun] {
        guard points.count >= 2 else { return [] }

        // Metres of route per sample step. The points may span only a
        // windowed fraction of the route, so the span they actually cover
        // scales the distance each step represents. Without a usable
        // distance every gradient would be infinite or NaN, so the whole
        // chart falls back to one gentle band rather than rendering a lie
        // in red.
        let spanFraction = points[points.count - 1].x - points[0].x
        let spannedKm = totalKm * spanFraction
        let stepM = spannedKm > 0 ? (spannedKm * 1000) / Double(points.count - 1) : 0

        var runs: [BandRun] = []
        for index in 0..<(points.count - 1) {
            let rise = points[index + 1].y - points[index].y
            let band = inclineBand(stepM > 0 ? rise / stepM * 100 : 0, thresholds: thresholds)
            if runs.isEmpty || runs[runs.count - 1].band != band {
                runs.append(BandRun(band: band, from: index, to: index + 1))
            } else {
                runs[runs.count - 1].to = index + 1
            }
        }
        return runs
    }

    /// A scrubbed point on the profile: the interpolated elevation at some
    /// distance along the route, and the local gradient there.
    public struct Selection: Equatable {
        public var km: Double
        public var elevationM: Double
        /// Signed: positive climbing, negative descending — unlike
        /// `maxInclinePct`, which only ever answers "how steep", a scrub
        /// callout also has to say which way.
        public var inclinePct: Double
    }

    /// The elevation (and local gradient) at `km` along the route — the
    /// interactive counterpart to `profile(...)`'s static resample.
    ///
    /// Walks `anchorDistances`, the same placement `maxInclinePct` and
    /// `profile` use, so a scrubbed callout never drifts from where the
    /// chart's own points actually sit — sparse elevation arrays (a thinned,
    /// stored profile) place vertices unevenly, and interpolating against
    /// proportional distance instead would read a different metre than the
    /// mark under the finger.
    public static func selection(
        at km: Double, latlngs: [CLLocationCoordinate2D], elevations: [Double]?
    ) -> Selection? {
        guard let elevations, let cumulative = anchorDistances(latlngs: latlngs, elevations: elevations),
              let total = cumulative.last, total > 0
        else { return nil }

        let target = min(total, max(0, km * 1000))

        // The anchor pair bracketing `target` — the same walk `profile`
        // does per sample, here for one arbitrary point.
        var index = 0
        while index < cumulative.count - 2, cumulative[index + 1] < target {
            index += 1
        }
        let span = cumulative[index + 1] - cumulative[index]
        let t = span > 0 ? min(1, max(0, (target - cumulative[index]) / span)) : 0
        let elevationM = elevations[index] + (elevations[index + 1] - elevations[index]) * t

        // The local gradient: a signed window at least `inclineWindowM`
        // wide, centred on `target` where the route is long enough to
        // afford it, and clamped to the ends otherwise.
        var start = index
        while start > 0, cumulative[index] - cumulative[start - 1] < inclineWindowM / 2 {
            start -= 1
        }
        var end = index + 1
        while end < cumulative.count - 1, cumulative[end + 1] - cumulative[index] < inclineWindowM / 2 {
            end += 1
        }
        let run = cumulative[end] - cumulative[start]
        let inclinePct = run > 0 ? (elevations[end] - elevations[start]) / run * 100 : 0

        return Selection(km: target / 1000, elevationM: elevationM, inclinePct: inclinePct)
    }

    /// The floor on how many points a drawn profile is resampled to.
    ///
    /// 120 was the only number, for every route: fine for a day ride, and
    /// one point per 5 km on a 600 km tour, where the chart became a
    /// smoothed line with every climb averaged out of it and the incline
    /// bands coloured from gradients nothing in the terrain has.
    public static let profileSampleFloor = 120

    /// The ceiling, and where it comes from.
    ///
    /// The chart this was sized for draws one hachure per 5.5 points of
    /// width — 70 strokes on the widest phone — and can be zoomed to a
    /// twentieth of the route. A window that narrow has to still hold a
    /// sample per stroke, so the whole route needs twenty times the stroke
    /// count: 70 × 20 = 1,400. That is what makes zooming in REVEAL detail
    /// rather than magnify a line already drawn, since the strokes in the
    /// window read their own samples instead of interpolating between two
    /// points 5 km apart.
    ///
    /// It costs 1,400 pairs of doubles, rebuilt only when the geometry
    /// changes, against the 120 it was.
    public static let profileSampleCeiling = 1_400

    /// How many points to resample a route of this length to: about one per
    /// kilometre, between the floor and the ceiling, and never more than
    /// the elevation array actually holds — asking for 1,200 samples of a
    /// 240-point stored profile invents 960 points of interpolation and
    /// draws exactly the same line.
    public static func profileSamples(totalKm: Double, available: Int) -> Int {
        let perKilometre = totalKm.isFinite ? Int(totalKm.rounded()) : profileSampleFloor
        let wanted = min(profileSampleCeiling, max(profileSampleFloor, perKilometre))
        return max(2, min(wanted, available))
    }

    public static func profile(
        latlngs: [CLLocationCoordinate2D], elevations: [Double]?, samples: Int
    ) -> Profile? {
        guard let elevations, samples >= 2,
              let cumulative = anchorDistances(latlngs: latlngs, elevations: elevations),
              let total = cumulative.last, total > 0
        else { return nil }

        // Resample at even distances so a route with vertices bunched at its
        // corners still draws with its straights the right width.
        var points: [(x: Double, y: Double)] = []
        points.reserveCapacity(samples)
        var index = 0
        for sample in 0..<samples {
            let target = total * Double(sample) / Double(samples - 1)
            while index < cumulative.count - 2, cumulative[index + 1] < target {
                index += 1
            }
            let span = cumulative[index + 1] - cumulative[index]
            let t = span > 0 ? min(1, max(0, (target - cumulative[index]) / span)) : 0
            let metres = elevations[index] + (elevations[index + 1] - elevations[index]) * t
            points.append((x: Double(sample) / Double(samples - 1), y: metres))
        }
        // Extremes from the source, not the samples: a peak between two
        // sample points would otherwise be shaved off the label.
        let minM = elevations.min() ?? 0
        let maxM = elevations.max() ?? 0
        return Profile(points: points, minM: minM, maxM: maxM, totalKm: total / 1000)
    }
}

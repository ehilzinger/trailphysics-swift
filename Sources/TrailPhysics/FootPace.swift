import CoreLocation
import Foundation

/// The user's own figures for the foot model: how they hike against the
/// signposts, and their easy flat running pace. Both optional in effect —
/// anything unset or unreadable falls back to the defaults.
///
/// Mirrors `settings` in hatchure-web's `foot-pace.js` and the
/// `foot_profiles` row (`hike_factor`, `run_pace_s_per_km`).
public struct FootPaceSettings: Codable, Equatable, Sendable {
    /// SPEED factor against the signposts: hike time is the signposted time
    /// divided by it, so 1.2 walks a 3:00 h sign in 2:30 h and 0.85 is
    /// slower. 1.0 is "like the signposts"; right is faster on the slider.
    public var hikeFactor: Double = 1.0
    /// Easy flat pace, seconds per km, for both run profiles. `nil` until the
    /// user sets one; the per-profile defaults apply meanwhile.
    public var runPaceSecPerKm: Int?

    public init(hikeFactor: Double = 1.0, runPaceSecPerKm: Int? = nil) {
        self.hikeFactor = hikeFactor
        self.runPaceSecPerKm = runPaceSecPerKm
    }

    /// Every key optional, so a stored or synced blob written before a field
    /// existed still decodes (synthesized `Decodable` would demand them).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hikeFactor = try c.decodeIfPresent(Double.self, forKey: .hikeFactor) ?? 1.0
        runPaceSecPerKm = try c.decodeIfPresent(Int.self, forKey: .runPaceSecPerKm)
    }

    /// Bounds are the database's (`foot_profiles` checks), wider than the
    /// 0.7–1.5 the profile screen offers (presets 0.85 / 1.0 / 1.2), so a
    /// factor learned from finished hikes is never cut short by the picker.
    /// Out of range is clamped, not rejected: 2.4 still clearly means "much
    /// faster than the signs".
    public static let hikeFactorRange: ClosedRange<Double> = 0.5...2.0
    public static let runPaceRange: ClosedRange<Int> = 150...900

    /// The hike factor the model uses: clamped, or 1.0 when not a positive
    /// number.
    public var effectiveHikeFactor: Double {
        guard hikeFactor.isFinite, hikeFactor > 0 else { return 1.0 }
        return min(Self.hikeFactorRange.upperBound, max(Self.hikeFactorRange.lowerBound, hikeFactor))
    }

    /// The easy flat pace for `profile`, seconds per km: the user's own,
    /// clamped, or the profile's default (road run 6:00, trail run 7:00).
    public func runPace(for profile: RouteProfile) -> Int {
        if let pace = runPaceSecPerKm, pace > 0 {
            return min(Self.runPaceRange.upperBound, max(Self.runPaceRange.lowerBound, pace))
        }
        return FootPace.defaultRunPaceSecPerKm(for: profile)
    }
}

/// How long a route takes on foot, moving: hiking by DIN 33466 (the Alpine
/// clubs' signpost formula), running by a grade-adjusted pace from Minetti's
/// energy cost of running.
///
/// The spec is `docs/foot-pace-model.md` in hatchure-web, and
/// `HatchureTests/Fixtures/foot-pace.json` — a byte-identical copy of the
/// web's fixture file — pins every number it promises. This is a port of
/// `app/js/foot-pace.js`; when the two disagree, the spec decides and both
/// change with the fixtures.
///
/// Pure arithmetic over plain numbers, like `RiderPhysics`, and compiled
/// wherever `RouteETA` is (the widgets, the clip and the watch too), so it
/// reaches for nothing outside Foundation and CoreLocation.
public enum FootPace {
    /// One stretch of uniform character. Numbers are metres; a negative or
    /// non-finite one reads as 0. `sacScale` is 0–6 as the Route API sends
    /// it (0 = no tag, nil = unknown; both walking ground); `surface` is an
    /// OSM `surface=` value, `roadClass` the Route API's `road_class`.
    public struct Section: Equatable, Sendable {
        public var distanceM: Double
        public var ascentM: Double
        public var descentM: Double
        public var sacScale: Int?
        public var surface: String?
        public var roadClass: String?

        public init(
            distanceM: Double, ascentM: Double = 0, descentM: Double = 0,
            sacScale: Int? = nil, surface: String? = nil, roadClass: String? = nil
        ) {
            self.distanceM = distanceM
            self.ascentM = ascentM
            self.descentM = descentM
            self.sacScale = sacScale
            self.surface = surface
            self.roadClass = roadClass
        }
    }

    /// A way the router placed along the line, metres from the start: what
    /// is underfoot between `fromM` and `toM`. See `FootPace+Route.swift`
    /// for the mapping from `RouteComposition.PlacedSegment`.
    public struct Way: Equatable, Sendable {
        public var fromM: Double
        public var toM: Double
        public var sacScale: Int?
        public var surface: String?
        public var roadClass: String?

        public init(
            fromM: Double, toM: Double,
            sacScale: Int? = nil, surface: String? = nil, roadClass: String? = nil
        ) {
            self.fromM = fromM
            self.toM = toM
            self.sacScale = sacScale
            self.surface = surface
            self.roadClass = roadClass
        }
    }

    /// Moving time against distance: cumulative from (0, 0), one entry per
    /// section end, linear within a section. A day split by time ends where
    /// `seconds` reaches the day's hours; a stop's arrival is `seconds`
    /// interpolated at its distance.
    public struct Timeline: Equatable, Sendable {
        public var distancesM: [Double]
        public var seconds: [Double]

        public init(distancesM: [Double], seconds: [Double]) {
            self.distancesM = distancesM
            self.seconds = seconds
        }
    }

    public static let footProfiles: Set<RouteProfile> = [.hiking, .trailrun, .roadrun]

    // MARK: - Defaults

    /// Moving time per day. What `RouteDays` splits a multi-day foot route by.
    public static let hikeDayHours: Double = 6
    public static let runDayHours: Double = 3

    /// The day length for `profile`, or nil for a riding profile (whose days
    /// are `RouteDays`' own business).
    public static func defaultDayHours(for profile: RouteProfile) -> Double? {
        switch profile {
        case .hiking: return hikeDayHours
        case .trailrun, .roadrun: return runDayHours
        case .bike, .gravel, .road, .roadfast: return nil
        }
    }

    /// Easy flat pace when the user has set none: 6:00/km on the road,
    /// 7:00/km on trails (slower for the same effort).
    public static func defaultRunPaceSecPerKm(for profile: RouteProfile) -> Int {
        profile == .roadrun ? 360 : 420
    }

    // MARK: - Hiking: DIN 33466

    public static let hikeHorizontalMPerH: Double = 4000
    public static let hikeAscentMPerH: Double = 300
    public static let hikeDescentMPerH: Double = 500

    /// SAC slow-down on the section's time. T1/T2 are what DIN's rates
    /// already describe.
    public static func sacHikeFactor(_ sacScale: Int?) -> Double {
        guard let sac = sacScale else { return 1 }
        if sac >= 5 { return 1.6 }
        if sac >= 4 { return 1.35 }
        if sac >= 3 { return 1.15 }
        return 1
    }

    /// Signpost hours: the larger of horizontal and vertical time plus half
    /// the smaller.
    public static func dinHours(distanceM: Double, ascentM: Double, descentM: Double) -> Double {
        let h = distanceM / hikeHorizontalMPerH
        let v = ascentM / hikeAscentMPerH + descentM / hikeDescentMPerH
        return max(h, v) + min(h, v) / 2
    }

    /// `factor` is the hike factor, a speed factor: the time divides by it.
    private static func hikeSeconds(
        distanceM: Double, ascentM: Double, descentM: Double, sacScale: Int?, factor: Double
    ) -> Double {
        dinHours(distanceM: distanceM, ascentM: ascentM, descentM: descentM)
            * 3600 * sacHikeFactor(sacScale) / factor
    }

    // MARK: - Running: Minetti

    /// Minetti et al. (2002), J Appl Physiol 93:1039: energy cost of running,
    /// J/kg/m, against gradient (rise over run), measured over ±45 %.
    /// Horner form, the same operation order as `foot-pace.js`.
    public static func minettiCost(_ i: Double) -> Double {
        ((((155.4 * i - 30.4) * i - 43.3) * i + 46.3) * i + 19.5) * i + 3.6
    }

    private static func minettiSlope(_ i: Double) -> Double {
        (((5 * 155.4 * i - 4 * 30.4) * i - 3 * 43.3) * i + 2 * 46.3) * i + 19.5
    }

    public static let minettiLimit: Double = 0.45

    /// A descent is never costed below this share of the flat pace: on real
    /// ground braking and footing limit it, not energy, and the raw curve
    /// would halve the time at -20 %. 0.85 is the curve at about -3 %.
    public static let downhillFloor: Double = 0.85

    /// Past this uphill grade a runner power-hikes. See `runSeconds`.
    public static let powerHikeGrade: Double = 0.25

    /// Pace factor for a grade: C(i)/C(0), floored for descents, and
    /// continued along the tangent outside ±45 % rather than clamped (a
    /// clamp would cost a 60 % wall like a 45 % one).
    public static func gradeFactor(_ i: Double) -> Double {
        let cost: Double
        if i > minettiLimit {
            cost = minettiCost(minettiLimit) + minettiSlope(minettiLimit) * (i - minettiLimit)
        } else if i < -minettiLimit {
            cost = minettiCost(-minettiLimit) + minettiSlope(-minettiLimit) * (i + minettiLimit)
        } else {
            cost = minettiCost(i)
        }
        return max(downhillFloor, cost / minettiCost(0))
    }

    private static let trailRoadClasses: Set<String> = ["path", "track", "bridleway", "steps"]
    /// `RouteComposition`'s `ground` surfaces: natural, unpaved ground.
    private static let trailSurfaces: Set<String> = [
        "ground", "dirt", "earth", "grass", "grass_paver", "mud",
        "sand", "unpaved", "woodchips", "snow", "ice"
    ]

    /// What is underfoot, for running: T3+ ×1.25, trail ×1.08, else 1.
    public static func runSurfaceFactor(_ section: Section) -> Double {
        if let sac = section.sacScale {
            if sac >= 3 { return 1.25 }
            if sac >= 1 { return 1.08 }
        }
        if let roadClass = section.roadClass, trailRoadClasses.contains(roadClass) { return 1.08 }
        if let surface = section.surface, trailSurfaces.contains(surface) { return 1.08 }
        return 1
    }

    /// A section that climbs and descends is a climb then a descent at the
    /// same steepness, the distance shared by the metres of each. Past
    /// `powerHikeGrade` the climb is power-hiked: the hike time, capped at
    /// the running time, and floored at the running time at exactly 25 % so
    /// the time never drops as the grade rises (spec §2.2).
    private static func runSeconds(
        _ section: Section, distanceM: Double, ascentM: Double, descentM: Double,
        pace: Double, factor: Double
    ) -> Double {
        let surface = runSurfaceFactor(section)
        let vertical = ascentM + descentM
        guard distanceM > 0 else {
            // All vertical and no distance: no grade to run, so walk it.
            return hikeSeconds(
                distanceM: 0, ascentM: ascentM, descentM: descentM,
                sacScale: section.sacScale, factor: factor
            )
        }
        guard vertical > 0 else { return pace * distanceM / 1000 * surface }

        let grade = vertical / distanceM
        let upM = distanceM * ascentM / vertical
        let downM = distanceM - upM

        var up = 0.0
        if upM > 0 {
            up = pace * upM / 1000 * gradeFactor(grade) * surface
            if grade > powerHikeGrade {
                let walked = hikeSeconds(
                    distanceM: upM, ascentM: ascentM, descentM: 0,
                    sacScale: section.sacScale, factor: factor
                )
                let atSwitch = pace * upM / 1000 * gradeFactor(powerHikeGrade) * surface
                up = max(atSwitch, min(up, walked))
            }
        }
        let down = downM > 0 ? pace * downM / 1000 * gradeFactor(-grade) * surface : 0
        return up + down
    }

    // MARK: - One section

    private static func nonNegative(_ x: Double) -> Double {
        x.isFinite && x > 0 ? x : 0
    }

    /// Moving seconds for one section. 0 for a riding profile, which this
    /// model has nothing to say about (`RiderPhysics` does).
    public static func sectionSeconds(
        _ section: Section, profile: RouteProfile, settings: FootPaceSettings = FootPaceSettings()
    ) -> TimeInterval {
        guard footProfiles.contains(profile) else { return 0 }
        let d = nonNegative(section.distanceM)
        let a = nonNegative(section.ascentM)
        let de = nonNegative(section.descentM)
        let factor = settings.effectiveHikeFactor
        if profile == .hiking {
            return hikeSeconds(distanceM: d, ascentM: a, descentM: de, sacScale: section.sacScale, factor: factor)
        }
        return runSeconds(
            section, distanceM: d, ascentM: a, descentM: de,
            pace: Double(settings.runPace(for: profile)), factor: factor
        )
    }

    /// Sum over `sections`, or nil for a riding profile or nothing to cover.
    public static func seconds(
        of sections: [Section], profile: RouteProfile, settings: FootPaceSettings = FootPaceSettings()
    ) -> TimeInterval? {
        guard footProfiles.contains(profile), !sections.isEmpty else { return nil }
        return sections.reduce(0) { $0 + sectionSeconds($1, profile: profile, settings: settings) }
    }

    // MARK: - Cutting a route into sections

    /// Height noise under this is ignored (a dead band, spec §3 step 3): the
    /// same 5 m `RouteElevation.minClimbM` and the web's `MIN_CLIMB_M` use.
    public static let elevationDeadBandM: Double = 5

    /// Minimum section length between samples: `RiderPhysics.gradientWindowM`.
    public static let sectionWindowM: Double = 200

    private static func deadBand(_ elevations: [Double]) -> [Double] {
        let half = elevationDeadBandM / 2
        var out = [elevations[0]]
        out.reserveCapacity(elevations.count)
        var y = elevations[0]
        for e in elevations.dropFirst() {
            y = min(max(y, e - half), e + half)
            out.append(y)
        }
        return out
    }

    /// One window split where the ways under it change; ascent and descent
    /// shared by distance. Uncovered stretches are unknown ground, and where
    /// ways overlap the first listed wins.
    private static func split(
        fromM: Double, toM: Double, ascentM: Double, descentM: Double,
        ways: [Way], into out: inout [Section]
    ) {
        var cuts = [fromM, toM]
        for way in ways where way.toM > fromM && way.fromM < toM {
            if way.fromM > fromM { cuts.append(way.fromM) }
            if way.toM < toM { cuts.append(way.toM) }
        }
        cuts.sort()
        let span = toM - fromM
        for k in 0..<(cuts.count - 1) {
            let lo = cuts[k], hi = cuts[k + 1]
            guard hi > lo else { continue }
            let mid = (lo + hi) / 2
            let way = ways.first { $0.fromM <= mid && $0.toM > mid }
            let share = span > 0 ? (hi - lo) / span : 0
            out.append(Section(
                distanceM: hi - lo, ascentM: ascentM * share, descentM: descentM * share,
                sacScale: way?.sacScale, surface: way?.surface, roadClass: way?.roadClass
            ))
        }
    }

    /// A profile and its ways cut into sections (spec §3).
    ///
    /// `distancesM[i]` is how far along sample i sits, `elevations[i]` its
    /// height (nil for none). `totalM` defaults to the last sample. Without
    /// a usable profile the route is one window with `ascentM`/`descentM`
    /// (descent defaulting to the ascent, a round trip), or flat.
    public static func sections(
        distancesM: [Double]?, elevations: [Double?]?, ways: [Way] = [],
        totalM: Double? = nil, ascentM: Double? = nil, descentM: Double? = nil
    ) -> [Section] {
        let ways = ways.filter { $0.fromM.isFinite && $0.toM.isFinite && $0.toM > $0.fromM }

        var d: [Double] = []
        var e: [Double] = []
        if let distancesM, let elevations {
            for i in 0..<min(distancesM.count, elevations.count) {
                let x = distancesM[i]
                guard x.isFinite, let y = elevations[i], y.isFinite else { continue }
                if let last = d.last, x <= last { continue }
                d.append(x)
                e.append(y)
            }
        }

        let total: Double
        if let totalM, totalM.isFinite, totalM > 0 { total = totalM } else { total = d.last ?? 0 }
        var out: [Section] = []
        guard total > 0 else { return out }

        guard d.count >= 2 else {
            let asc = nonNegative(ascentM ?? 0)
            let desc: Double
            if let descentM, descentM.isFinite { desc = nonNegative(descentM) } else { desc = asc }
            split(fromM: 0, toM: total, ascentM: asc, descentM: desc, ways: ways, into: &out)
            return out
        }

        let y = deadBand(e)
        let n = d.count
        if d[0] > 0 { split(fromM: 0, toM: min(d[0], total), ascentM: 0, descentM: 0, ways: ways, into: &out) }
        var start = 0
        while start < n - 1 {
            var end = start + 1
            while end < n - 1 && d[end] - d[start] < sectionWindowM { end += 1 }
            var up = 0.0, down = 0.0
            for k in (start + 1)...end {
                let delta = y[k] - y[k - 1]
                if delta > 0 { up += delta } else { down -= delta }
            }
            let lo = min(d[start], total), hi = min(d[end], total)
            if hi > lo { split(fromM: lo, toM: hi, ascentM: up, descentM: down, ways: ways, into: &out) }
            start = end
        }
        if d[n - 1] < total { split(fromM: d[n - 1], toM: total, ascentM: 0, descentM: 0, ways: ways, into: &out) }
        return out
    }

    // MARK: - A whole route

    private static let earthRadiusM = 6_371_000.0

    /// `RouteGeometry.distance`, repeated here because `RouteGeometry` is
    /// not compiled into every target this file is (the widgets). Same
    /// formula, so a way's `fromM` from the router lines up with these.
    private static func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let dLat = lat2 - lat1
        let dLng = (b.longitude - a.longitude) * .pi / 180
        let sinLat = sin(dLat / 2)
        let sinLng = sin(dLng / 2)
        let h = sinLat * sinLat + cos(lat1) * cos(lat2) * sinLng * sinLng
        return 2 * earthRadiusM * asin(min(1, sqrt(h)))
    }

    /// The route's sections from its geometry. A stored route keeps every
    /// vertex but thins its profile, so each sample maps back to its vertex
    /// by inverting the stride — the same mapping `RiderPhysics` uses.
    public static func routeSections(
        latlngs: [CLLocationCoordinate2D], elevations: [Double]?, ways: [Way] = [],
        ascentM: Double? = nil, descentM: Double? = nil
    ) -> [Section] {
        guard latlngs.count >= 2 else { return [] }
        var cum = [0.0]
        cum.reserveCapacity(latlngs.count)
        for i in 1..<latlngs.count { cum.append(cum[i - 1] + distance(latlngs[i - 1], latlngs[i])) }
        let total = cum[cum.count - 1]

        var samples: [Double]?
        var heights: [Double?]?
        if let elevations, elevations.count > 1 {
            let n = elevations.count
            if n == latlngs.count {
                samples = cum
            } else {
                let stride = Double(latlngs.count - 1) / Double(n - 1)
                samples = (0..<n).map { cum[min(latlngs.count - 1, Int((Double($0) * stride).rounded()))] }
            }
            heights = elevations
        }
        return sections(
            distancesM: samples, elevations: heights, ways: ways,
            totalM: total, ascentM: ascentM, descentM: descentM
        )
    }

    /// Moving seconds for the whole route, or nil for a riding profile or a
    /// route with no line to measure.
    public static func routeSeconds(
        latlngs: [CLLocationCoordinate2D], elevations: [Double]?, ways: [Way] = [],
        ascentM: Double? = nil, descentM: Double? = nil,
        profile: RouteProfile, settings: FootPaceSettings = FootPaceSettings()
    ) -> TimeInterval? {
        guard footProfiles.contains(profile) else { return nil }
        let parts = routeSections(
            latlngs: latlngs, elevations: elevations, ways: ways, ascentM: ascentM, descentM: descentM
        )
        return seconds(of: parts, profile: profile, settings: settings)
    }

    /// Moving time against distance along the route (see `Timeline`), or nil
    /// as `routeSeconds`.
    public static func timeline(
        latlngs: [CLLocationCoordinate2D], elevations: [Double]?, ways: [Way] = [],
        ascentM: Double? = nil, descentM: Double? = nil,
        profile: RouteProfile, settings: FootPaceSettings = FootPaceSettings()
    ) -> Timeline? {
        guard footProfiles.contains(profile) else { return nil }
        let parts = routeSections(
            latlngs: latlngs, elevations: elevations, ways: ways, ascentM: ascentM, descentM: descentM
        )
        guard !parts.isEmpty else { return nil }
        var line = Timeline(distancesM: [0], seconds: [0])
        for part in parts {
            line.distancesM.append(line.distancesM[line.distancesM.count - 1] + part.distanceM)
            line.seconds.append(
                line.seconds[line.seconds.count - 1] + sectionSeconds(part, profile: profile, settings: settings)
            )
        }
        return line
    }
}

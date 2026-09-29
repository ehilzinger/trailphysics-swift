import CoreLocation
import Foundation

/// How fast a given rider covers a given route, from physics rather than a
/// flat table. Port of `rider-physics.js` in Hatchure's web implementation.
///
/// An arrival time worked out from one flat average speed knows nothing
/// about the rider. A loaded tourer at 180 W and a light rider at 260 W get
/// identical times up the same alpine pass, which is wrong by hours.
///
/// This answers the same question from the four forces a bicycle actually
/// works against. Deliberately pure: no storage, no app state, no UI —
/// arithmetic over plain numbers and arrays, checkable by hand and
/// testable without a route attached.
///
/// Two entry points, because a caller typically needs the answer at two very
/// different costs:
///
///   `estimateSpeedKmh` — one solve at the route's mean gradient. Cheap
///                         enough for every row of a saved-route list.
///   `detailedSpeedKmh` — one solve per segment of the elevation profile,
///                         summing times. On demand, one route at a time.
///
/// The detailed figure is always slower than the approximation on rolling
/// terrain, and that gap is the reason it exists: climbing at 6 km/h costs
/// ten minutes a kilometre where descending at 45 km/h gives back only
/// eighty seconds. A mean gradient cannot see that asymmetry — it is a
/// property of averaging *times*, not slopes.
public enum RiderPhysics {
    // MARK: - Physical constants

    public static let gravity: Double = 9.80665

    /// Air density at sea level, 15 °C. Thinner air higher up is a real
    /// effect (roughly -10% per 1000 m) and is applied by `airDensity(at:)`
    /// from the route's own elevation where there is one.
    public static let airDensitySeaLevel: Double = 1.225

    /// Chain and bearings. 2–3% is the usual measured range for a clean
    /// drivetrain; the rider's power is at the pedals, and this is what
    /// reaches the road.
    public static let drivetrainEfficiency: Double = 0.97

    // MARK: - Rider-facing presets

    /// CdA is never asked for directly. Nobody outside a wind tunnel knows
    /// their own drag area, and on a flat route a wrong guess dominates
    /// every other error in this module — so it is derived from a bike type
    /// the rider *can* answer, optionally sharpened by their height.
    ///
    /// Drag area in m² for a rider of average build in that position; the
    /// widely-published ranges rather than anything measured here.
    public static let bikeTypeCdA: [String: Double] = [
        "road": 0.32,     // hands on the hoods, the position most people actually ride
        "gravel": 0.36,   // flared bars, a slightly more upright back
        "trekking": 0.42, // upright, bar bag, the default profile here
        "mtb": 0.46       // wide bars, most upright of the four
    ]
    public static let defaultBikeType = "trekking"

    /// Rolling resistance coefficient by surface. Spans a factor of four,
    /// which sounds dramatic but is worth less than a km/h at touring speeds
    /// on the flat — included because it is cheap and matters on the long
    /// shallow climbs where a loaded bike spends its day.
    public static let crrBySurface: [String: Double] = [
        "asphalt": 0.004,
        "gravel": 0.010,
        "offroad": 0.018
    ]
    public static let defaultSurface = "asphalt"

    /// Luggage is not a separate field. Rider weight and bike-plus-kit
    /// weight are asked separately because people know them separately, and
    /// this is the fallback for the second when it hasn't been given: a
    /// bike, bags, water and tools for a loaded tour.
    public static let defaultBikeKg: Double = 18

    // MARK: - Sanity bounds

    /// These bound the *inputs*, not the answer. A profile outside them is
    /// rejected whole rather than clamped: a 5000 W entry is a typo or a
    /// unit mix-up, and quietly treating it as 500 would produce a
    /// confident, wrong arrival time. This is the accepted range; anything
    /// that stores rider profiles should enforce exactly the same bounds.
    public static let minRiderKg: Double = 30
    public static let maxRiderKg: Double = 200
    public static let minBikeKg: Double = 3
    public static let maxBikeKg: Double = 80
    public static let minWatts: Double = 40
    public static let maxWatts: Double = 500
    public static let minHeightCm: Double = 100
    public static let maxHeightCm: Double = 250

    /// The braking cap. A loaded touring bike on an unknown descent does not
    /// do 90 km/h whatever the physics says, because the rider is on the
    /// brakes looking for the next hairpin. Without this the harmonic mean
    /// is quietly wrecked by a handful of steep segments.
    public static let maxDescentKmh: Double = 65

    /// Below this gradient the rider is assumed to stop pedalling and coast.
    /// -2% is about where a touring pace carries itself; above it people
    /// keep turning the cranks, below it they mostly don't.
    public static let coastingGradient: Double = -0.02

    /// Minimum distance a gradient is measured over, in metres. Not a fresh
    /// choice — this is `RouteElevation`'s own `inclineWindowM` reasoning
    /// (BRouter's elevation model is quantised, so a short segment reads as
    /// a phantom ramp nobody rode); here the consequence of not smoothing is
    /// worse than a wrong headline number, because every phantom ramp adds
    /// real minutes to the total. The same 200 m as the display window.
    public static let gradientWindowM: Double = 200

    public static let fatigueExponent: Double = 0.04
    public static let minFatigueFactor: Double = 0.75

    // MARK: - Rider

    /// The rider's own figures, in the shape `normalize` expects, before
    /// validation.
    public struct Rider: Sendable, Codable, Equatable {
        public var riderKg: Double
        public var bikeKg: Double?
        public var watts: Double
        public var heightCm: Double?
        public var bikeType: String
        public var surface: String
        public var fatigue: Bool
        /// An explicit, measured drag area. Honoured when present but never
        /// asked for — exists so a rider who has actually been measured
        /// isn't overridden by a table. Not meant to be persisted: storing
        /// it would let a stale value outlive a bike-type change.
        public var cda: Double?

        public init(
            riderKg: Double, bikeKg: Double? = nil, watts: Double,
            heightCm: Double? = nil, bikeType: String = RiderPhysics.defaultBikeType,
            surface: String = RiderPhysics.defaultSurface, fatigue: Bool = false,
            cda: Double? = nil
        ) {
            self.riderKg = riderKg
            self.bikeKg = bikeKg
            self.watts = watts
            self.heightCm = heightCm
            self.bikeType = bikeType
            self.surface = surface
            self.fatigue = fatigue
            self.cda = cda
        }
    }

    /// A rider's figures, resolved into what a solve actually needs: total
    /// mass, drag area, rolling resistance — every fallback already applied.
    public struct NormalizedParams: Sendable {
        public var totalKg: Double
        public var watts: Double
        public var cda: Double
        public var crr: Double
        public var bikeType: String
        public var surface: String
        public var fatigue: Bool
        /// Air density for the segment being solved. Mutable because a
        /// detailed solve updates it per window from that window's
        /// elevation; a cheap solve sets it once to sea level.
        public var rho: Double
    }

    // MARK: - Deriving the parameters a solve needs

    /// Air density at a given elevation, via the standard barometric lapse.
    /// Simplified to the troposphere case, which covers anywhere a bicycle
    /// goes.
    public static func airDensity(atElevationM elevationM: Double?) -> Double {
        guard let elevationM, elevationM.isFinite else { return airDensitySeaLevel }
        let h = max(0, elevationM)
        return airDensitySeaLevel * pow(1 - 2.25577e-5 * h, 4.25588)
    }

    /// Drag area for a rider, from the bike type and — when given — their
    /// build.
    ///
    /// The bike type sets the position, which is most of it. Height and
    /// weight only scale that baseline by body size, via the DuBois
    /// body-surface formula normalised to a 175 cm / 75 kg reference, so an
    /// average rider gets exactly the table figure and a much larger or
    /// smaller one gets a proportionate adjustment. Clamped hard: DuBois is
    /// an approximation being pushed well past what it was fitted for, and a
    /// ±25% band is enough to carry the real signal without letting an odd
    /// entry invent a drag area.
    public static func defaultCdA(heightCm: Double?, weightKg: Double?, bikeType: String) -> Double {
        let base = bikeTypeCdA[bikeType] ?? bikeTypeCdA[defaultBikeType]!
        guard let h = heightCm, h.isFinite, h > 0,
              let w = weightKg, w.isFinite, w > 0 else { return base }

        let bsa = 0.007184 * pow(h, 0.725) * pow(w, 0.425)
        let reference = 0.007184 * pow(175, 0.725) * pow(75, 0.425)
        let scale = min(1.25, max(0.75, bsa / reference))
        return base * scale
    }

    /// Normalises whatever the UI or storage hands over into the shape
    /// every solve below assumes, or returns nil when it isn't usable.
    ///
    /// Returning nil rather than a defaulted profile is deliberate: "no
    /// rider profile" has to stay distinguishable from "a rider profile
    /// made of guesses", because the first means fall back to a generic
    /// speed and the second means show a confident but wrong figure.
    /// Only the two fields nobody can substitute for — weight and power —
    /// are required; everything else has a defensible default.
    public static func normalize(_ rider: Rider?) -> NormalizedParams? {
        guard let rider else { return nil }
        guard rider.riderKg.isFinite, rider.riderKg >= minRiderKg, rider.riderKg <= maxRiderKg
        else { return nil }
        guard rider.watts.isFinite, rider.watts >= minWatts, rider.watts <= maxWatts
        else { return nil }

        let bikeKg: Double
        if let raw = rider.bikeKg, raw.isFinite, raw >= minBikeKg, raw <= maxBikeKg {
            bikeKg = raw
        } else {
            bikeKg = defaultBikeKg
        }

        let bikeType = bikeTypeCdA[rider.bikeType] != nil ? rider.bikeType : defaultBikeType
        let surface = crrBySurface[rider.surface] != nil ? rider.surface : defaultSurface

        // An explicit CdA is honoured when present but never asked for.
        let cda: Double
        if let raw = rider.cda, raw.isFinite, raw > 0.1, raw <= 1.2 {
            cda = raw
        } else {
            cda = defaultCdA(heightCm: rider.heightCm, weightKg: rider.riderKg, bikeType: bikeType)
        }

        return NormalizedParams(
            totalKg: rider.riderKg + bikeKg,
            watts: rider.watts,
            cda: cda,
            crr: crrBySurface[surface]!,
            bikeType: bikeType,
            surface: surface,
            fatigue: rider.fatigue,
            rho: airDensitySeaLevel
        )
    }

    // MARK: - The solve
    //
    // Steady-state power balance for a bicycle on a constant slope:
    //
    //   P·η = v · ( m·g·(sin θ + Crr·cos θ) + ½·ρ·CdA·v² )
    //
    // which rearranges to a depressed cubic in v:
    //
    //   ½·ρ·CdA·v³ + m·g·(sin θ + Crr·cos θ)·v − P·η = 0
    //
    // Acceleration is deliberately absent. Over a 200 m window at touring
    // speeds the kinetic-energy term is a rounding error against the other
    // three, and including it would require modelling how hard the rider
    // brakes into each bend — a much bigger guess than the one it fixes.

    /// The real positive root, in m/s.
    ///
    /// Newton from a seed, falling back to bisection. Newton alone is not
    /// safe here: on a steep descent the linear coefficient goes strongly
    /// negative, the cubic grows a local maximum, and an unlucky seed walks
    /// the iteration off to a negative root that is mathematically real and
    /// physically nonsense. Bisection over a bracket guaranteed to contain
    /// the positive root cannot do that, so it decides the answer whenever
    /// Newton fails to converge cleanly.
    public static func solveSpeedMs(watts: Double, gradient: Double, params: NormalizedParams) -> Double {
        let cdaTerm = 0.5 * params.rho * params.cda
        let theta = atan(gradient)
        let resistTerm = params.totalKg * gravity * (sin(theta) + params.crr * cos(theta))
        let drive = watts * drivetrainEfficiency

        // f(v) = cdaTerm·v³ + resistTerm·v − drive
        //
        // Strictly increasing in v wherever resistTerm >= 0, and with
        // exactly one positive root regardless of resistTerm's sign
        // (Descartes: the coefficient signs change exactly once, since
        // drive > 0).
        func f(_ v: Double) -> Double { cdaTerm * v * v * v + resistTerm * v - drive }

        // Bracket the root. f(0) = -drive < 0 always, so only an upper
        // bound where f turns positive is needed; doubling from a sane seed
        // finds one in a handful of steps even on the steepest descent.
        var hi = 1.0
        var guardCount = 0
        while f(hi) < 0 && guardCount < 60 {
            hi *= 2
            guardCount += 1
        }
        let lo0 = 0.0

        // Newton first, from the midpoint of the bracket.
        var v = hi / 2
        for _ in 0..<12 {
            let fv = f(v)
            let slope = 3 * cdaTerm * v * v + resistTerm
            guard slope > 1e-9 else { break }
            let next = v - fv / slope
            guard next > lo0, next < hi else { break }
            if abs(next - v) < 1e-9 { return next }
            v = next
        }

        // Bisection. Always converges.
        var lo = 0.0
        var hiB = hi
        for _ in 0..<60 {
            let mid = (lo + hiB) / 2
            if f(mid) < 0 { lo = mid } else { hiB = mid }
        }
        return (lo + hiB) / 2
    }

    /// Speed on one stretch of constant gradient, in m/s, with the two
    /// behavioural caps a bare solve doesn't know about.
    ///
    /// Below `coastingGradient` the rider is treated as freewheeling: the
    /// solve runs at zero power, giving terminal velocity for that slope,
    /// because pedalling 200 W down an 8% descent is not something people
    /// do. The braking cap then applies on top, for the reason at
    /// `maxDescentKmh`.
    public static func speedForGradientMs(_ gradient: Double, params: NormalizedParams) -> Double {
        let watts = gradient < coastingGradient ? 0 : params.watts
        var v = solveSpeedMs(watts: watts, gradient: gradient, params: params)
        let capMs = maxDescentKmh / 3.6
        if v > capMs { v = capMs }
        return v
    }

    // MARK: - Fatigue

    /// How much of the entered power is still available after `hours` of
    /// riding.
    ///
    /// A critical-power style decay: sustainable output falls roughly as a
    /// small negative power of duration. The exponent is deliberately
    /// gentle — the figure a tourer enters is what they can hold for a long
    /// day, not a 20-minute test, so most of the decay this models is
    /// already priced into their own number. It exists to stop a
    /// twelve-hour day being estimated at hour-one pace, not to re-derive a
    /// power curve.
    ///
    /// Floored so a very long day cannot decay toward zero and produce an
    /// arrival time in the following week.
    public static func fatigueFactor(hours: Double?) -> Double {
        guard let hours, hours.isFinite, hours > 1 else { return 1 }
        let f = pow(hours, -fatigueExponent)
        return max(minFatigueFactor, f)
    }

    /// The hours fatigue should actually be computed over, given the whole
    /// route's riding time and (optionally) how long the longest planned
    /// day is.
    ///
    /// `dayHours` is the longest day rather than the mean — the day that
    /// actually costs something, where taking the mean would let one short
    /// transfer day flatter every other day on the tour. An unsplit route
    /// passes nothing and falls back to the total, which is correct: an
    /// unsplit route IS one day, however long.
    public static func fatigueHours(totalHours: Double, dayHours: Double?) -> Double {
        if let dayHours, dayHours.isFinite, dayHours > 0 {
            return min(totalHours, dayHours)
        }
        return totalHours
    }

    // MARK: - Tier one: the approximation

    /// Average speed in km/h from distance and total ascent alone, or nil
    /// when there isn't enough to work with.
    ///
    /// A saved route usually carries both (its total ascent, and the
    /// geometry), so this can run for every row of a list without touching
    /// the elevation array. What it cannot see is the *distribution* of that
    /// ascent: 1000 m spread evenly and 1000 m in one wall give the same
    /// answer here, and the second is genuinely slower — `detailedSpeedKmh`
    /// is the fix.
    ///
    /// The mean gradient is halved on the way in. A route with 1000 m of
    /// ascent over 100 km does not climb at 1% throughout — it climbs at
    /// some steeper figure for part of the distance and descends for the
    /// rest, and feeding the naive ascent/distance ratio in as a *sustained*
    /// gradient overstates the time badly. Half the ratio is the standard
    /// approximation for an out-and-back-ish profile.
    ///
    /// `dayHours` is optional: the longest single day's riding time, when
    /// the route is split into days. Only fatigue reads it.
    public static func estimateSpeedKmh(
        rider: Rider?, distanceKm: Double, ascentM: Double?, dayHours: Double? = nil
    ) -> Double? {
        guard var params = normalize(rider) else { return nil }
        guard distanceKm.isFinite, distanceKm > 0 else { return nil }

        let ascent = (ascentM?.isFinite == true && ascentM! > 0) ? ascentM! : 0
        let gradient = (ascent / (distanceKm * 1000)) / 2

        params.rho = airDensitySeaLevel
        let ms = speedForGradientMs(gradient, params: params)
        guard ms > 0 else { return nil }

        var kmh = ms * 3.6
        if params.fatigue {
            kmh *= fatigueFactor(hours: fatigueHours(totalHours: distanceKm / kmh, dayHours: dayHours))
        }
        return kmh
    }

    // MARK: - Tier two: the detailed solve

    /// Average speed in km/h from the full elevation profile, or nil when
    /// the route can't support one.
    ///
    /// Walks the profile in windows of at least `gradientWindowM`, solving
    /// for each and accumulating TIME. Summing times rather than averaging
    /// speeds is not a detail — the distance-weighted harmonic mean is what
    /// "average speed" means, and averaging the segment speeds instead
    /// would flatter every hilly route by exactly the amount the fast
    /// descents inflate it.
    ///
    /// `dayHours` is optional and means the same as in `estimateSpeedKmh`.
    public static func detailedSpeedKmh(
        rider: Rider?, latlngs: [CLLocationCoordinate2D], elevations: [Double]?,
        dayHours: Double? = nil
    ) -> Double? {
        guard var params = normalize(rider) else { return nil }
        guard let elevations else { return nil }
        guard latlngs.count >= 2, elevations.count >= 2 else { return nil }

        let cum = RouteGeometry.cumulativeDistances(latlngs)
        guard let totalM = cum.last, totalM > 0 else { return nil }

        // The elevation array is walked, not the geometry, and the two are
        // different lengths whenever the route came back from storage
        // (a stored profile is thinned; see
        // `RouteElevation.profileForStorage`). Each elevation index maps to
        // the vertex it was sampled from by inverting the storage stride.
        //
        // Deliberately NOT a proportional split of the total distance:
        // BRouter emits vertices densely through bends and sparsely along
        // straights, so assuming even spacing puts samples far from their
        // real position on a winding route. Same array, same trap as the
        // elevation-profile resampling in `RouteElevation`.
        let n = elevations.count
        let stride = n > 1 ? Double(latlngs.count - 1) / Double(n - 1) : 0
        func distanceAt(_ index: Int) -> Double {
            if n == latlngs.count { return cum[index] }
            let mapped = min(latlngs.count - 1, Int((Double(index) * stride).rounded()))
            return cum[mapped]
        }

        var seconds = 0.0
        var covered = 0.0
        var start = 0
        while start < n - 1 {
            // Extend to at least one smoothing window.
            var end = start + 1
            while end < n - 1 && distanceAt(end) - distanceAt(start) < gradientWindowM {
                end += 1
            }

            let run = distanceAt(end) - distanceAt(start)
            guard run > 0 else { start = end; continue }

            let rise = elevations[end] - elevations[start]
            params.rho = airDensity(atElevationM: (elevations[start] + elevations[end]) / 2)

            let ms = speedForGradientMs(rise / run, params: params)
            if ms > 0 {
                seconds += run / ms
                covered += run
            }
            start = end
        }

        guard covered > 0, seconds > 0 else { return nil }

        var kmh = (covered / 1000) / (seconds / 3600)
        if params.fatigue {
            kmh *= fatigueFactor(hours: fatigueHours(totalHours: seconds / 3600, dayHours: dayHours))
        }
        return kmh
    }
}

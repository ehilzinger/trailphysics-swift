import CoreLocation
import Foundation

/// Metres climbed, and the gradient under the rider right now — the wrist's
/// own measurement, fix by fix, the same shape as `RideOdometer` and for the
/// same reason: it has to run identically on the phone and the watch, so it
/// lives where both can reach it and neither has to trust the other's
/// arithmetic.
///
/// Nothing here reads `RouteElevation` — that is the STORED profile, thinned
/// to about 48 points and known before a wheel turns. This is the opposite
/// measurement: what the barometer actually reported while riding, which is
/// the only figure a ride's summary and log can stand behind on a free
/// ride, where there is no route to have a profile at all.
public struct RideAscent {
    /// A fix looser than this does not move the climb. `verticalAccuracy` is
    /// negative when the device has no altitude opinion at all, and CoreLocation
    /// widens it into the tens of metres under trees or between buildings —
    /// unlike a few metres in the open. Past 20 m a fix is reporting its own
    /// uncertainty, not the ground, and letting it through would rebase the
    /// climb onto a number that means nothing.
    public static let maxVerticalAccuracyM: Double = 20

    /// The window `gradePercent` is measured over.
    ///
    /// Shorter and the number is noise for two reasons at once: consecutive
    /// fixes a few metres apart carry the barometer's own resolution as a
    /// large fraction of the rise, and — on a route with a stored
    /// profile — the vertices themselves are not that close together either.
    /// `RouteElevation.inclineWindowM` makes the identical argument for a
    /// route's profile, at the same 200 m; a live fix is noisier than a
    /// modelled vertex, and 200 m of riding is still only a few seconds.
    public static let gradeWindowM: Double = 200

    public init() {}

    /// Metres climbed so far: unbroken rises only, filtered the way
    /// `RouteElevation.ascent` filters a stored profile — a rise accumulates
    /// until the first fall and is banked only once it amounted to a real
    /// climb, past `RouteElevation.minClimbM`.
    ///
    /// Summing every positive step instead banks each sub-metre wobble the
    /// barometer produces standing still. `RouteElevation.minClimbM`'s own
    /// comment carries the measured cost of that: 6,280 m reported against a
    /// true 4,200 over one 546 km tour, from unfiltered summation of a
    /// full-resolution profile — noisier fix to fix than a modelled vertex,
    /// so the same mistake here would be worse, not better.
    public private(set) var climbedM: Double = 0

    /// The rise over the run across the last `gradeWindowM` of ground
    /// covered, signed — a rider wants to know they are descending as much
    /// as climbing, which `RouteElevation.maxInclinePct` does not answer
    /// because a stored profile is read forwards, never live. Nil until a
    /// trusted window has actually filled; a ride's first 200 m has no
    /// gradient to report and guessing one from less ground would be a
    /// number nobody measured.
    public private(set) var gradePercent: Double?

    /// The last fix trusted enough to move the climb, kept only so the next
    /// one has something to difference against.
    private var lastTrusted: CLLocation?

    /// The current unbroken rise, banked into `climbedM` on the first fall
    /// past it.
    private var risingM: Double = 0

    /// Horizontal ground covered since the last rebase, and the (distance,
    /// altitude) samples still inside `gradeWindowM` of it — oldest first.
    /// Small by construction (a fix every few seconds over 200 m of riding
    /// is a handful of entries), so trimming from the front is cheap enough
    /// not to need a proper deque.
    private var traveledM: Double = 0
    private var window: [(distanceM: Double, altitudeM: Double)] = []

    /// Folds in one fix.
    public mutating func note(_ location: CLLocation) {
        guard location.verticalAccuracy >= 0,
              location.verticalAccuracy <= Self.maxVerticalAccuracyM
        else {
            // Untrusted, and left out of the arithmetic entirely — it must
            // not even become the new base, or a single fix under a bridge
            // rebases the climb onto a made-up altitude and the NEXT trusted
            // fix reads the recovery as a cliff.
            return
        }

        defer { lastTrusted = location }

        guard let previous = lastTrusted else {
            window = [(0, location.altitude)]
            traveledM = 0
            return
        }

        let elapsed = location.timestamp.timeIntervalSince(previous.timestamp)
        // Same gap `RideOdometer.step` rebases on, and the same reason: a
        // stretch this long went unmeasured (a tunnel, a suspended app), and
        // the straight-line altitude delta across it is not a climb anyone
        // rode — it would bank a lift, or erase a real ascent the watch
        // simply wasn't running for.
        guard elapsed > 0, elapsed < RideOdometer.staleAfter else {
            risingM = 0
            window = [(0, location.altitude)]
            traveledM = 0
            return
        }

        let stepM = location.distance(from: previous)
        traveledM += stepM
        window.append((traveledM, location.altitude))
        // Drop from the front only while the NEXT sample back still spans
        // the full window — dropping on `window[0]`'s own span instead
        // undershoots by however wide that one step was, and with fixes a
        // real bike ride apart (a few metres a second) that is enough to
        // dip back under `gradeWindowM` and read as "not enough ground yet"
        // right after it just had enough.
        while window.count > 1, traveledM - window[1].distanceM >= Self.gradeWindowM {
            window.removeFirst()
        }
        if let first = window.first, traveledM - first.distanceM >= Self.gradeWindowM {
            let run = traveledM - first.distanceM
            gradePercent = run > 0 ? (location.altitude - first.altitudeM) / run * 100 : nil
        } else {
            gradePercent = nil
        }

        let delta = location.altitude - previous.altitude
        if delta > 0 {
            risingM += delta
        } else if delta < 0 {
            if risingM >= RouteElevation.minClimbM { climbedM += risingM }
            risingM = 0
        }
    }

    public mutating func reset() {
        self = RideAscent()
    }
}

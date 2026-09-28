import Foundation

/// The rolling average behind every speed and every ETA in a ride.
///
/// Lifted out of `RideSession` and `WatchRideSession`, which had grown two
/// copies of it, because a rider standing still watched the wrist report
/// **ten thousand kilometres an hour**.
///
/// **The quantity fed in is a position along the route, not a distance
/// covered.** On a planned day it is `fraction × routeKm`, and
/// `RouteGeometry.project` answers with the nearest point on the line
/// however far away the fix is. Where a route doubles back — an
/// out-and-back, a loop that passes its own start, a valley ridden up and
/// down — the outbound and return legs run within metres of each other on
/// the ground and a hundred kilometres apart along the line. A few metres
/// of GPS jitter flips the projection between them, and the difference is
/// read as ground covered.
///
/// `RideApproach.isFixUsable` does not catch this. It bounds how far OFF
/// the line a fix may be, which is a different question: both candidate
/// projections are right next to the line, and both are perfectly usable.
/// What is wrong is the distance BETWEEN them.
///
/// So the window keeps a ceiling. A figure above it is not a fast rider, it
/// is a position that moved without them — and the honest response is to
/// throw the window away and start again from here, rather than to publish
/// a number no bicycle has ever produced.
public struct RideSpeedWindow: Equatable, Sendable {
    public struct Sample: Equatable, Sendable {
        public var metres: Double
        public var at: Date
    }

    /// Ten minutes. Long enough that a set of lights does not halve the
    /// reading, short enough to follow a change of terrain.
    public static let windowSeconds: TimeInterval = 600

    /// Below this the base is too short to mean anything: two fixes ten
    /// seconds apart on a line whose vertices are tens of metres apart
    /// measure the line's resolution, not the rider.
    public static let minimumBaseSeconds: TimeInterval = 30

    /// Above this, the position jumped rather than the rider.
    ///
    /// Generous on purpose. A loaded tourer on an alpine descent reaches
    /// sixty, exceptionally eighty; a ferry crossing — which a route may
    /// genuinely contain, see `RouteFerries` — does rather less. A hundred
    /// and twenty is out of reach of all of them and still three orders of
    /// magnitude below a projection flip, so this cannot suppress a real
    /// figure while catching every fake one.
    ///
    /// A rider who puts the bike on a train without ending the day will
    /// trip it. That is the right answer: the number this publishes is
    /// their riding pace, and a train is not riding.
    public static func ceilingKmh(for profile: RouteProfile) -> Double {
        switch profile {
        case .hiking, .trailrun: return 40
        case .road, .roadfast, .bike, .gravel, .roadrun: return 120
        }
    }

    public init() {}

    public private(set) var samples: [Sample] = []

    /// Throws the window away.
    ///
    /// Called whenever the AXIS changes rather than the position — a plan
    /// swapped mid-ride, a day reconfigured. The samples are positions
    /// along a route, so a new route makes every one of them a measurement
    /// of something else, and the first reading after the swap would be the
    /// difference between two unrelated numbers.
    public mutating func reset() {
        samples.removeAll(keepingCapacity: true)
    }

    /// Adds a fix and answers the smoothed speed, if there is an honest one.
    ///
    /// - Returns: km/h, or nil when there is nothing trustworthy to say —
    ///   too short a base, or a window the ceiling has just rejected.
    ///   Callers leave whatever they last published alone on nil rather
    ///   than blanking it: a rebase means this window cannot answer, not
    ///   that the rider has stopped.
    public mutating func note(metres: Double, at now: Date, ceilingKmh: Double) -> Double? {
        samples.append(Sample(metres: metres, at: now))
        let cutoff = now.addingTimeInterval(-Self.windowSeconds)
        samples.removeAll { $0.at < cutoff }

        guard let first = samples.first, samples.count >= 2 else { return nil }
        let seconds = now.timeIntervalSince(first.at)
        guard seconds >= Self.minimumBaseSeconds else { return nil }

        // Backwards along the line — a jump, or a genuine turn-around — is
        // not negative speed. Measured forward only.
        let covered = max(0, metres - first.metres)
        let kmh = covered / seconds * 3.6
        guard kmh.isFinite else {
            rebase(to: samples[samples.count - 1])
            return nil
        }
        guard kmh <= ceilingKmh else {
            // The window spans a jump. Keeping only the newest sample means
            // the next fix measures from HERE, so one bad projection costs
            // one window rather than poisoning the next ten minutes.
            rebase(to: samples[samples.count - 1])
            return nil
        }
        return kmh
    }

    private mutating func rebase(to sample: Sample) {
        samples = [sample]
    }
}

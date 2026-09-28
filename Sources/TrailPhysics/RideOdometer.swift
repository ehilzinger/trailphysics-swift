import CoreLocation
import Foundation

/// How far the rider actually went, one fix at a time.
///
/// Lifted out of `RideSession` when the watch learned to run its own ride.
/// It was already pure, `static` and deliberately outside the actor so it
/// could be tested without one — the only thing that changed is which
/// targets can see it, because `RideSession` imports UIKit and ActivityKit
/// and cannot cross to watchOS, while this rule must.
///
/// The alternative was a second implementation on the wrist, and the whole
/// argument for a standalone watch is that it runs the *same* logic: a
/// phone and a watch disagreeing about how far a rider went, by a few
/// hundred metres a day, would be the least debuggable bug in the app.
///
/// `RideSession.odometerStep` still exists and forwards here, so every
/// existing call site and `RideOdometerTests` are untouched.
public enum RideOdometer {
    /// What a fix did to the odometer.
    public enum Step: Equatable, Sendable {
        /// Metres the rider covered. Counted, and the fix becomes the base.
        case count(Double)
        /// Nothing countable happened, but this fix is where the next step
        /// is measured from.
        case rebase
        /// Neither counted nor measured from — the base stays put.
        case ignore
    }

    /// No fix for this long and everything derived from one is stale. Also
    /// the gap past which two fixes are not a step but a tunnel.
    public static let staleAfter: TimeInterval = 90

    /// Below this, a step is GPS jitter at a café table rather than riding.
    /// The same judgement `updateMovingTime` makes about a gap, applied to
    /// a distance, so the two figures cannot disagree about what counted.
    public static let minStepM: Double = 5

    /// A fix less accurate than this does not move the odometer. Nothing
    /// rejects the fix itself — it is still a position, and the approach
    /// model wants it — but a ±150 m fix under a bridge, differenced
    /// against the last one, is a hundred metres of "riding" the rider did
    /// not do, and a day of those is what puts a summary kilometres over.
    public static let maxAccuracyM: Double = 50

    /// And nor does a step that implies a speed nothing on this route could
    /// hold. A fix that jumps a block sideways is a jump, not a sprint;
    /// counting it would bank the error and then bank the way back too.
    public static let maxSpeedKmh: Double = 120

    /// Raw distance between consecutive fixes, under the same two rules
    /// `updateMovingTime` applies — so the distance and the moving time
    /// cannot disagree about what counted as riding — and two more that
    /// keep the figure from drifting upwards over a day.
    ///
    /// The upward drift is the point. Every rejected fix that still became
    /// the base would contribute the error between where the phone thought
    /// it was and where it was, twice: once going wrong and once coming
    /// back. Over six hours under trees that is the difference between a
    /// summary that says thirty kilometres and one that says forty.
    public static func step(from previous: CLLocation, to location: CLLocation) -> Step {
        // A fix the device itself does not believe in.
        guard location.horizontalAccuracy >= 0,
              location.horizontalAccuracy <= maxAccuracyM
        else { return .ignore }
        let elapsed = location.timestamp.timeIntervalSince(previous.timestamp)
        // A gap longer than the stale window is a tunnel, a pocket or a
        // train, not riding — drawing a straight line across it would add
        // kilometres the rider did not turn a pedal for. Measured from
        // here on, though: the rider is somewhere new.
        guard elapsed > 0, elapsed < staleAfter else { return .rebase }
        let distance = location.distance(from: previous)
        // Under this, it is GPS jitter at a café table. Left uncounted AND
        // uncommitted: taking the fix as the new base would let a slow
        // drift accumulate a step at a time.
        //
        // The floor is the fix's own accuracy, not a flat five metres. A
        // device that says ±10 m is saying a nine-metre step might be
        // nothing at all — and a stationary bike under an awning produces
        // exactly that, once a second, all afternoon: eight metres of
        // "riding" every second is 28 km/h of standing still. Because an
        // ignored fix does not become the base, nothing is lost by being
        // strict here; a genuinely slow rider is simply measured over two
        // fixes instead of one, and arrives at the same distance.
        guard distance >= max(minStepM, location.horizontalAccuracy) else { return .ignore }
        // Over this, it is not riding either — a fix that jumped a block
        // sideways is a jump, not a sprint. Same treatment for the same
        // reason: banking it would add the jump out, and then the jump
        // back when the position settles.
        guard distance / elapsed * 3.6 <= maxSpeedKmh else { return .ignore }
        return .count(distance)
    }
}

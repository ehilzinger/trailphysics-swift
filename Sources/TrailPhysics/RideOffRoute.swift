import CoreLocation
import Foundation

/// Whether the rider is still on the planned line, and when that is worth
/// saying out loud.
///
/// A ride can measure the distance from the line on every fix, and still
/// have no use for it: being off the line is not worth treating as an error
/// while there is no line to guide back to. This is that
/// line-to-guide-back-to, and the rule for when to draw it.
///
/// **The whole problem is that raw distance is unusable.** A fix under trees
/// jumps a hundred metres; a cycleway runs thirty metres from the road the
/// router picked; a village one-way system puts a rider a block off the line
/// for ninety seconds of perfectly correct riding. A threshold read straight
/// off one fix would flap between on and off several times a kilometre, and
/// a rider whose watch buzzes at every bridge stops believing any of it.
///
/// So two mechanisms, both here rather than at the call site so the phone
/// and the wrist cannot read them differently:
///
/// 1. **Hysteresis.** Leaving takes more distance than returning. Without
///    the gap, a rider sitting exactly on the threshold toggles on every
///    fix.
/// 2. **Confirmation by ground covered, not by time.** A rider is only off
///    route once they have *ridden* a distance while off it. Measured with
///    the odometer rather than a clock deliberately: standing still 90 m
///    from the line is a café, a level crossing or a photograph, and none of
///    those is a wrong turn. A clock would call all three.
///
/// Both figures are the odometer's, which means this states the same
/// quantity the rider sees on the screen and cannot drift from it.
public enum RideOffRoute {
    public struct Thresholds: Equatable, Sendable {
        /// Past this, the rider might have left the line.
        public var leavingM: Double
        /// Inside this, they are back on it. Lower than `leavingM` on
        /// purpose — the gap between them is the hysteresis.
        public var returningM: Double
        /// How far they must RIDE beyond `leavingM` before it is called.
        public var confirmAfterM: Double

        /// A bike is doing 20 km/h, so 250 m of confirmation is
        /// three-quarters of a minute — long enough to rule out a GPS jump
        /// and a one-way detour, short enough that the line back is still
        /// worth having. 80 m of clearance covers a parallel cycleway and
        /// an urban canyon without covering an actual wrong turn.
        public static let wheeled = Thresholds(
            leavingM: 80, returningM: 40, confirmAfterM: 250
        )

        /// On foot the same times are a quarter of the distance, the ratio
        /// the approach alerts already use — and a walker
        /// genuinely is a few metres from the line where a cyclist is
        /// pinned to a carriageway.
        public static let foot = Thresholds(
            leavingM: 50, returningM: 25, confirmAfterM: 120
        )

        public static func `for`(profile: RouteProfile) -> Thresholds {
            switch profile {
            case .hiking, .trailrun: return foot
            // `roadrun` on the wheeled column because a runner on a road
            // covers ground more like a slow cyclist than like a walker.
            case .road, .roadfast, .bike, .gravel, .roadrun: return wheeled
            }
        }
    }

    /// Where the rider stands relative to the line.
    ///
    /// `straying` is deliberately a state rather than a detail: it is the
    /// period during which the departure has been noticed and NOT yet
    /// announced, and having it named is what keeps "noticed" and
    /// "announced" from collapsing into one threshold.
    public enum Standing: String, Codable, Equatable, Sendable {
        case onRoute
        case straying
        case offRoute
    }

    public struct State: Equatable, Sendable {
        public var standing: Standing = .onRoute
        /// The odometer reading when the line was first left. The
        /// confirmation distance is measured from here.
        public var strayingSinceM: Double?

        public static let onRoute = State()
    }

    /// What the caller should act on. Edges, never levels: `left` fires once
    /// per departure, so a haptic or a router call hangs off it without the
    /// caller keeping its own "have I done this yet" flag.
    public enum Event: Equatable, Sendable {
        case none
        case left
        case rejoined
    }

    public struct Step: Equatable, Sendable {
        public var state: State
        public var event: Event
    }

    /// One fix's worth of judgement.
    ///
    /// - Parameters:
    ///   - offRouteM: how far the projected fix was from the line. **Nil
    ///     resets** — it means there is no line to be off (a free ride) or
    ///     no usable projection, and neither is a wrong turn.
    ///   - odometerM: ground covered so far, from `RideOdometer`. Only its
    ///     differences are used.
    ///   - suppressed: the caller's veto, for when being off the line is the
    ///     plan. A stop 400 m off the route is 400 m of riding away from it,
    ///     and announcing a wrong turn to a rider who is deliberately riding
    ///     to a planned café would be the caller failing to read its own
    ///     plan.
    ///     Suppression resets rather than pauses: coming back from a stop,
    ///     the confirmation starts again from the line.
    public static func advance(
        _ state: State,
        offRouteM: Double?,
        odometerM: Double,
        suppressed: Bool = false,
        thresholds: Thresholds
    ) -> Step {
        guard let offRouteM, offRouteM.isFinite, !suppressed else {
            return Step(
                state: .onRoute,
                // Still an edge: a rider who was off the line and then
                // committed to a stop should have the line back put away,
                // and the caller learns that the only way it learns
                // anything.
                event: state.standing == .offRoute ? .rejoined : .none
            )
        }

        switch state.standing {
        case .onRoute:
            guard offRouteM > thresholds.leavingM else {
                return Step(state: .onRoute, event: .none)
            }
            return Step(
                state: State(standing: .straying, strayingSinceM: odometerM),
                event: .none
            )

        case .straying:
            // Back inside the inner threshold: never happened. No event,
            // because nothing was ever announced — this is the whole
            // purpose of `straying` existing.
            if offRouteM <= thresholds.returningM {
                return Step(state: .onRoute, event: .none)
            }
            let since = state.strayingSinceM ?? odometerM
            // Guarded against a backwards odometer, which cannot happen
            // today (`RideOdometer` only ever adds) but would otherwise
            // make this unconfirmable forever rather than fail visibly.
            let ridden = max(0, odometerM - since)
            guard ridden >= thresholds.confirmAfterM else {
                return Step(
                    state: State(standing: .straying, strayingSinceM: since),
                    event: .none
                )
            }
            return Step(
                state: State(standing: .offRoute, strayingSinceM: since),
                event: .left
            )

        case .offRoute:
            guard offRouteM <= thresholds.returningM else {
                return Step(state: state, event: .none)
            }
            return Step(state: .onRoute, event: .rejoined)
        }
    }

    // MARK: - The way back

    /// How far ahead along the line to aim the rejoin leg.
    ///
    /// Not the nearest point, which is the obvious answer and the wrong
    /// one: on a switchback descent or beside a one-way the nearest point
    /// is behind the rider, and a line drawn back up the hill they just
    /// came down is worse than no line. Aiming ahead also means the leg
    /// rejoins going the right way round.
    public static let rejoinLeadM: Double = 300

    /// Where the way back should meet the route.
    ///
    /// Clamped to the day's own end: a rider off the line in the last
    /// kilometre should be sent to where they are stopping, not to a point
    /// on tomorrow.
    ///
    /// - Returns: nil when there is nothing ahead to rejoin — the rider is
    ///   already at or past the day's end, and the honest answer is no line
    ///   rather than a line to where they already are.
    public static func rejoinTarget(
        line: [CLLocationCoordinate2D],
        cumulative: [Double],
        fraction: Double,
        dayTo: Double
    ) -> CLLocationCoordinate2D? {
        guard let total = cumulative.last, total > 0, line.count >= 2 else { return nil }
        let here = min(max(0, fraction), 1) * total
        let dayEnd = min(max(0, dayTo), 1) * total
        let target = min(here + rejoinLeadM, dayEnd)
        // A lead shorter than a tenth of the intended one is a rider who is
        // essentially at the day's end already.
        guard target - here > rejoinLeadM / 10 else { return nil }
        return RouteGeometry.point(on: line, cumulative: cumulative, atMetres: target)
    }
}

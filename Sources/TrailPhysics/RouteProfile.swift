import Foundation

/// The seven ways a route can be drawn, grouped into three sports (`Sport`).
///
/// The pace and ride models switch on it: a trekking bike, a road bike and a
/// trail runner get different speed ceilings, off-route thresholds and
/// default paces from the same line.
///
/// The raw values are a persistence format — stored in preferences, saved
/// routes, a database and a ride snapshot — so they must not be renamed. Any
/// translation to a routing engine's own profile ids belongs at the wire.
/// Display names and glyphs are the host app's business and belong beside
/// its string catalogue, not here.
public enum RouteProfile: String, Codable, CaseIterable, Identifiable, Sendable {
    case bike, gravel, road, roadfast, hiking, trailrun, roadrun

    public var id: String { rawValue }

    /// Ride, hike or run — the top-level choice, with the profiles as the
    /// flavour inside it.
    ///
    /// Derived from the profile, never stored beside it: a second stored
    /// value could only ever disagree. The raw values are persistence, not
    /// wording.
    public enum Sport: String, Codable, CaseIterable, Identifiable, Sendable {
        case ride, hike, run

        public var id: String { rawValue }

        /// The profile a sport starts on when nothing was picked in it yet.
        public var defaultProfile: RouteProfile {
            switch self {
            case .ride: return .bike
            case .hike: return .hiking
            case .run: return .trailrun
            }
        }

        /// The sports a picker offers: all three.
        public static var selectable: [Sport] { allCases }
    }

    public var sport: Sport {
        switch self {
        case .bike, .gravel, .road, .roadfast: return .ride
        case .hiking: return .hike
        case .trailrun, .roadrun: return .run
        }
    }

    /// Feet rather than wheels. Approach thresholds, detour factors and
    /// surface scoring are the same for a hike and a run, so it stays one
    /// question.
    public var isOnFoot: Bool { sport != .ride }

    /// This profile first, then the others of the same sport — the order to
    /// read cached results in when the exact profile has too few.
    public var relatives: [RouteProfile] {
        [self] + RouteProfile.allCases.filter { $0 != self && $0.sport == sport }
    }

    public static let `default` = RouteProfile.bike

    /// A sport's profiles, in declaration order.
    public static func profiles(for sport: Sport) -> [RouteProfile] {
        allCases.filter { $0.sport == sport }
    }

    /// The profiles a rider may pick: every one. Pickers read this rather
    /// than `allCases` so a profile that ever has to be held back has one
    /// place to go.
    public static var selectable: [RouteProfile] { allCases }
}

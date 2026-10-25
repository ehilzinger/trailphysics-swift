import Foundation

/// One turn a router reports along a route: the `cues` of a route API that
/// gives, per junction, the manoeuvre, the turn, the name and the angles of
/// the other ways leaving it.
///
/// Decoded from the API's snake_case JSON. An unknown manoeuvre reads as
/// `other` and a missing source as `engine`, so a router that learns a new
/// manoeuvre does not break an app that has not.
public struct RouteCue: Codable, Equatable, Sendable {
    public enum Maneuver: String, Codable, CaseIterable, Sendable {
        case depart
        case `continue`
        case slightLeft = "slight_left"
        case left
        case sharpLeft = "sharp_left"
        case slightRight = "slight_right"
        case right
        case sharpRight = "sharp_right"
        case keepLeft = "keep_left"
        case keepRight = "keep_right"
        case uTurn = "u_turn"
        case roundabout
        case waypoint
        case arrive
        case other
    }

    /// `engine`: a junction the router announced. `fork`: one it passed in
    /// silence, announced by the route API. `route`: depart, waypoint,
    /// arrive.
    public enum Source: String, Codable, CaseIterable, Sendable {
        case engine, fork, route
    }

    /// The junction's index into the route's coordinates.
    public var point: Int
    /// Along the line to the next cue.
    public var distanceM: Double
    public var maneuver: Maneuver
    /// −180…180 from straight on, negative to the left; nil where it has none.
    public var turnDeg: Double?
    /// On a roundabout, which exit (1 = the first).
    public var exit: Int?
    public var name: String?
    public var ref: String?
    /// The other ways leaving the junction, as `turnDeg`; nil when the
    /// router cannot tell.
    public var otherWaysDeg: [Double]?
    public var source: Source

    public init(
        point: Int, distanceM: Double = 0, maneuver: Maneuver, turnDeg: Double? = nil, exit: Int? = nil,
        name: String? = nil, ref: String? = nil, otherWaysDeg: [Double]? = nil, source: Source = .engine
    ) {
        self.point = point
        self.distanceM = distanceM
        self.maneuver = maneuver
        self.turnDeg = turnDeg
        self.exit = exit
        self.name = name
        self.ref = ref
        self.otherWaysDeg = otherWaysDeg
        self.source = source
    }

    enum CodingKeys: String, CodingKey {
        case point
        case distanceM = "distance_m"
        case maneuver
        case turnDeg = "turn_deg"
        case exit, name, ref
        case otherWaysDeg = "other_ways_deg"
        case source
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        point = try c.decode(Int.self, forKey: .point)
        guard point >= 0 else {
            throw DecodingError.dataCorruptedError(forKey: .point, in: c, debugDescription: "negative point")
        }
        distanceM = (try? c.decodeIfPresent(Double.self, forKey: .distanceM)) ?? 0
        maneuver = ((try? c.decodeIfPresent(String.self, forKey: .maneuver)) ?? nil).flatMap(Maneuver.init(rawValue:)) ?? .other
        turnDeg = try? c.decodeIfPresent(Double.self, forKey: .turnDeg)
        exit = try? c.decodeIfPresent(Int.self, forKey: .exit)
        name = ((try? c.decodeIfPresent(String.self, forKey: .name)) ?? nil).flatMap { $0.isEmpty ? nil : $0 }
        ref = ((try? c.decodeIfPresent(String.self, forKey: .ref)) ?? nil).flatMap { $0.isEmpty ? nil : $0 }
        otherWaysDeg = (try? c.decodeIfPresent([Double?].self, forKey: .otherWaysDeg))?.map { $0.compactMap { $0 } }
        source = ((try? c.decodeIfPresent(String.self, forKey: .source)) ?? nil).flatMap(Source.init(rawValue:)) ?? .engine
    }

    /// A route API's cue list, decoded loosely: a cue without a usable point
    /// is left out rather than failing the list, and the rest come in line
    /// order.
    public struct List: Decodable, Equatable, Sendable {
        public var cues: [RouteCue]

        public init(cues: [RouteCue]) {
            self.cues = RouteCue.inLineOrder(cues)
        }

        public init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            var out: [RouteCue] = []
            while !c.isAtEnd {
                if let cue = try? c.decode(RouteCue.self) {
                    out.append(cue)
                } else {
                    _ = try? c.decode(Skip.self)
                }
            }
            cues = RouteCue.inLineOrder(out)
        }

        private struct Skip: Decodable {}
    }

    /// Sorted by point, keeping the router's order at one point (a waypoint
    /// before the turn it reports there).
    static func inLineOrder(_ cues: [RouteCue]) -> [RouteCue] {
        cues.enumerated().sorted { ($0.element.point, $0.offset) < ($1.element.point, $1.offset) }.map(\.element)
    }
}

/// The fields of a route's segment the cue plan reads, decoded from the
/// route API's segments.
public struct CueWay: Codable, Equatable, Sendable {
    public var fromPoint: Int
    public var toPoint: Int
    public var roadClass: String?
    public var sacScale: Int?
    public var trailVisibility: String?

    public init(fromPoint: Int, toPoint: Int, roadClass: String?, sacScale: Int? = nil, trailVisibility: String? = nil) {
        self.fromPoint = fromPoint
        self.toPoint = toPoint
        self.roadClass = roadClass
        self.sacScale = sacScale
        self.trailVisibility = trailVisibility
    }

    enum CodingKeys: String, CodingKey {
        case fromPoint = "from_point"
        case toPoint = "to_point"
        case roadClass = "road_class"
        case sacScale = "sac_scale"
        case trailVisibility = "trail_visibility"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fromPoint = try c.decode(Int.self, forKey: .fromPoint)
        toPoint = try c.decode(Int.self, forKey: .toPoint)
        roadClass = ((try? c.decodeIfPresent(String.self, forKey: .roadClass)) ?? nil).flatMap { $0.isEmpty ? nil : $0 }
        sacScale = try? c.decodeIfPresent(Int.self, forKey: .sacScale)
        trailVisibility = ((try? c.decodeIfPresent(String.self, forKey: .trailVisibility)) ?? nil).flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// Which rules and timings a route's cues follow.
///
/// A walker at 1.2 m/s and a road rider at 8 m/s need the same seconds of
/// warning, which are very different metres; and a forest track forking off
/// a road is the way to take on foot and no choice at all on a road bike.
public enum CueSport: String, Codable, CaseIterable, Sendable {
    case foot, run, bike, road

    public static func `for`(profile: RouteProfile) -> CueSport {
        switch profile {
        case .hiking: return .foot
        case .trailrun, .roadrun: return .run
        case .road, .roadfast: return .road
        case .bike, .gravel: return .bike
        }
    }

    /// Heads-up and now are seconds at the speed actually moving; the merge
    /// window is seconds at `nominalMps`, which also stands in while no
    /// speed is known. `nowMinM` keeps "now" from shrinking below what a
    /// fix wanders when moving slowly; going back along the line by
    /// `rewindM` re-arms the cues behind.
    public struct Timing: Equatable, Sendable {
        public var headsUpS: Double
        public var nowS: Double
        public var mergeS: Double
        public var nominalMps: Double
        public var nowMinM: Double
        public var rewindM: Double

        public var mergeM: Double { mergeS * nominalMps }
    }

    public var timing: Timing {
        switch self {
        case .foot: return Timing(headsUpS: 45, nowS: 8, mergeS: 15, nominalMps: 1.2, nowMinM: 10, rewindM: 25)
        case .run: return Timing(headsUpS: 30, nowS: 6, mergeS: 10, nominalMps: 3, nowMinM: 12, rewindM: 30)
        case .bike: return Timing(headsUpS: 30, nowS: 8, mergeS: 8, nominalMps: 5.6, nowMinM: 25, rewindM: 60)
        case .road: return Timing(headsUpS: 25, nowS: 6, mergeS: 6, nominalMps: 8.4, nowMinM: 30, rewindM: 80)
        }
    }

    var onFoot: Bool { self == .foot || self == .run }
}

/// The kind of way a cue leads onto, for the cue that has no name (on foot,
/// most of them): "onto the path", "up the steps".
public enum CueWayKind: String, Codable, CaseIterable, Sendable {
    case steps, path, footway, track, cycleway, road
}

public enum CueSlope: String, Codable, CaseIterable, Sendable {
    case up, down, level
}

/// Where the way itself changes.
public enum CueNotice: String, Codable, CaseIterable, Sendable {
    case steps
    case harderGrade = "harder_grade"
    case faintTrail = "faint_trail"
}

/// One manoeuvre, and what it leads onto.
public struct CueStep: Codable, Equatable, Sendable {
    public var maneuver: RouteCue.Maneuver
    public var turnDeg: Double?
    public var exit: Int?
    public var name: String?
    public var ref: String?
    public var onto: CueWayKind?
    public var slope: CueSlope?
    /// On a step merged into a cue: metres from the step before.
    public var gapM: Double?
}

/// One moment to say something, in a plan from `CuePlan.build`.
public struct PlannedCue: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case turn, waypoint, arrive
        case headsUp = "heads_up"
    }

    public var kind: Kind
    public var alongM: Double
    public var point: Int
    /// nil on a heads-up.
    public var maneuver: RouteCue.Maneuver?
    public var turnDeg: Double?
    public var exit: Int?
    public var name: String?
    public var ref: String?
    public var onto: CueWayKind?
    public var slope: CueSlope?
    /// The manoeuvres merged into this one, in order.
    public var then: [CueStep]
    public var notice: CueNotice?
    /// The new grade, on a `harderGrade` notice.
    public var sacScale: Int?
}

/// Which of a router's turns are worth saying, merged and described: the
/// plan the tracker walks. Pure, and held to the JavaScript port's numbers
/// by shared test vectors.
public enum CuePlan {
    /// A way leaving within this many degrees of the route's own is a fork.
    public static let forkDeg: Double = 45
    /// At most this many manoeuvres in one merged cue: "left, then right,
    /// then left" is as much as anyone keeps in their head.
    public static let maxMerged = 3
    /// The way ahead is up or down past this grade, over `slopeM`.
    public static let slopeGrade: Double = 0.04
    public static let slopeM: Double = 40
    /// The way a cue leads onto is the first stretch at least this long
    /// (or steps of any length): a turn onto 12 m of footway and then 757 m
    /// of steps is a turn onto the steps.
    public static let ontoMinM: Double = 15

    static let roads: Set<String> = [
        "motorway", "trunk", "primary", "secondary", "tertiary", "unclassified", "residential",
        "living_street", "service"
    ]

    static let wayKinds: [String: CueWayKind] = [
        "steps": .steps, "path": .path, "bridleway": .path, "footway": .footway, "pedestrian": .footway,
        "track": .track, "cycleway": .cycleway
    ]

    static let visibility: [String: Int] = ["excellent": 0, "good": 1, "intermediate": 2, "bad": 3, "horrible": 4, "no": 5]

    /// The cues to say, in order along the line.
    ///
    /// - A fork cue on wheels stands only where the route's road class
    ///   changes there, or the route is itself off the road network:
    ///   measured on five road rides, all 35 fork cues sat on a road that
    ///   went on, nearly all a forest track peeling off, and the cue cannot
    ///   tell a track from a road. On foot the track is often the way, so
    ///   every fork cue stands.
    /// - A plain `continue` stands only when another way leaves within
    ///   `forkDeg` of the line (or the router did not say which ways leave).
    /// - `depart` is not said.
    /// - A cue within the sport's merge window of the one before joins it
    ///   as a `then`, up to `maxMerged` in all. On foot 16–36% of a router's
    ///   cues come within 25 m of the one before. A waypoint always stands
    ///   alone; an arrival just after a turn is its last `then`.
    /// - On foot, heads-ups where steps begin, the grade rises to T2 or
    ///   above, or the trail turns faint; each quiet for the sport's
    ///   heads-up distance after the last of its kind (a stair in flights is
    ///   one stair), and onto a turn within the merge window as its
    ///   `notice` rather than alone.
    ///
    /// - Parameters:
    ///   - cumulative: metres along the line at each vertex, index 0 is 0.
    ///   - elevations: height at each vertex, nil where unknown.
    public static func build(
        cues: [RouteCue], ways: [CueWay], cumulative: [Double], elevations: [Double?]?, sport: CueSport
    ) -> [PlannedCue] {
        guard !cumulative.isEmpty else { return [] }
        let timing = sport.timing
        let mergeM = timing.mergeM
        let last = cumulative.count - 1
        func at(_ p: Int) -> Double { cumulative[min(max(0, p), last)] }

        let kept = cues.filter { $0.point <= last && keeps($0, sport: sport, ways: ways) }
        var out: [PlannedCue] = []
        var prevAlong: Double?
        for c in kept {
            let along = at(c.point)
            var s = step(c, ways: ways, cumulative: cumulative, elevations: elevations)
            if let lead = out.last, lead.kind == .turn, c.maneuver != .waypoint,
               let prev = prevAlong, along - prev <= mergeM, 1 + lead.then.count < maxMerged {
                s.gapM = along - prev
                out[out.count - 1].then.append(s)
            } else {
                let kind: PlannedCue.Kind = c.maneuver == .arrive ? .arrive : c.maneuver == .waypoint ? .waypoint : .turn
                out.append(PlannedCue(
                    kind: kind, alongM: along, point: c.point, maneuver: s.maneuver, turnDeg: s.turnDeg, exit: s.exit,
                    name: s.name, ref: s.ref, onto: s.onto, slope: s.slope, then: [], notice: nil, sacScale: nil
                ))
            }
            prevAlong = along
        }

        guard sport.onFoot else { return out }
        for n in notices(ways, cumulative: cumulative, quietM: timing.headsUpS * timing.nominalMps) {
            let nAlong = at(n.point)
            if let i = out.firstIndex(where: { $0.kind == .turn && abs($0.alongM - nAlong) <= mergeM && $0.notice == nil }) {
                out[i].notice = n.notice
                out[i].sacScale = n.notice == .harderGrade ? n.sacScale : nil
                continue
            }
            out.append(PlannedCue(
                kind: .headsUp, alongM: nAlong, point: n.point, maneuver: nil, turnDeg: nil, exit: nil, name: nil, ref: nil,
                onto: onto(ways, from: n.point, cumulative: cumulative),
                slope: slope(from: n.point, cumulative: cumulative, elevations: elevations),
                then: [], notice: n.notice, sacScale: n.notice == .harderGrade ? n.sacScale : nil
            ))
        }
        // By place; a turn before a heads-up at the same place; else as
        // they were (a stable sort, as the JavaScript port's).
        return out.enumerated().sorted { a, b in
            if a.element.alongM != b.element.alongM { return a.element.alongM < b.element.alongM }
            let ha = a.element.kind == .headsUp ? 1 : 0, hb = b.element.kind == .headsUp ? 1 : 0
            return ha != hb ? ha < hb : a.offset < b.offset
        }.map(\.element)
    }

    /// As the JavaScript port's `((d % 360) + 540) % 360 - 180`.
    static func norm180(_ d: Double) -> Double {
        (d.truncatingRemainder(dividingBy: 360) + 540).truncatingRemainder(dividingBy: 360) - 180
    }

    /// The segment the route runs on just after `point` (or just before it).
    static func way(_ ways: [CueWay], at point: Int, before: Bool) -> CueWay? {
        ways.first { before ? ($0.fromPoint < point && point <= $0.toPoint) : ($0.fromPoint <= point && point < $0.toPoint) }
    }

    static func kind(_ way: CueWay?) -> CueWayKind? {
        guard let rc = way?.roadClass else { return nil }
        return wayKinds[rc] ?? .road
    }

    static func onto(_ ways: [CueWay], from point: Int, cumulative: [Double]) -> CueWayKind? {
        guard let first = way(ways, at: point, before: false), let start = ways.firstIndex(of: first) else { return nil }
        for w in ways[start...] {
            let len = cumulative[min(w.toPoint, cumulative.count - 1)] - cumulative[max(w.fromPoint, point)]
            if len >= ontoMinM || w.roadClass == "steps" { return kind(w) }
        }
        return kind(first)
    }

    static func slope(from point: Int, cumulative: [Double], elevations: [Double?]?) -> CueSlope? {
        guard let elevations, point < elevations.count, let e0 = elevations[point] else { return nil }
        let start = cumulative[point]
        var j = point + 1
        while j < cumulative.count {
            if cumulative[j] - start >= slopeM || j == cumulative.count - 1 {
                let run = cumulative[j] - start
                guard run >= 10, j < elevations.count, let e1 = elevations[j] else { return nil }
                let grade = (e1 - e0) / run
                return grade > slopeGrade ? .up : grade < -slopeGrade ? .down : .level
            }
            j += 1
        }
        return nil
    }

    static func keeps(_ cue: RouteCue, sport: CueSport, ways: [CueWay]) -> Bool {
        if cue.maneuver == .depart { return false }
        if cue.source == .fork, sport == .bike || sport == .road,
           let before = way(ways, at: cue.point, before: true), let after = way(ways, at: cue.point, before: false),
           before.roadClass == after.roadClass, let rc = after.roadClass, roads.contains(rc) {
            return false
        }
        if cue.maneuver == .continue, cue.source == .engine, let others = cue.otherWaysDeg, let turn = cue.turnDeg,
           !others.contains(where: { abs(norm180($0 - turn)) < forkDeg }) {
            return false
        }
        return true
    }

    struct Notice { var point: Int; var notice: CueNotice; var sacScale: Int? }

    static func notices(_ ways: [CueWay], cumulative: [Double], quietM: Double) -> [Notice] {
        var out: [Notice] = []
        var last: [CueNotice: Double] = [:]
        func at(_ p: Int) -> Double { cumulative[min(p, cumulative.count - 1)] }
        for (i, s) in ways.enumerated() {
            let p = i > 0 ? ways[i - 1] : nil
            var notice: CueNotice?
            if let p, s.roadClass == "steps", p.roadClass != "steps" {
                notice = .steps
            } else if let p, let sn = s.sacScale, let pn = p.sacScale, sn > pn, sn >= 2 {
                notice = .harderGrade
            } else if let p, (s.trailVisibility.flatMap { visibility[$0] } ?? 0) >= 3,
                      (p.trailVisibility.flatMap { visibility[$0] } ?? 0) < 3 {
                notice = .faintTrail
            }
            let here = at(s.fromPoint)
            // Steps are quiet after the end of the last flight, the others
            // after the last notice of their kind.
            let quiet = notice.flatMap { last[$0] }
            if s.roadClass == "steps" { last[.steps] = at(s.toPoint) }
            if let notice, notice != .steps { last[notice] = here }
            guard let notice else { continue }
            if let quiet, here - quiet < quietM { continue }
            out.append(Notice(point: s.fromPoint, notice: notice, sacScale: s.sacScale))
        }
        return out
    }

    static func step(_ cue: RouteCue, ways: [CueWay], cumulative: [Double], elevations: [Double?]?) -> CueStep {
        CueStep(
            maneuver: cue.maneuver, turnDeg: cue.turnDeg, exit: cue.exit, name: cue.name, ref: cue.ref,
            onto: onto(ways, from: cue.point, cumulative: cumulative),
            slope: slope(from: cue.point, cumulative: cumulative, elevations: elevations), gapM: nil
        )
    }
}

/// When each planned cue is due, from metres along the line and the speed
/// actually moving.
///
/// Edges, never levels, like `RideOffRoute`: each cue's heads-up and its
/// "now" fire once, so a voice line or a haptic hangs off the event with no
/// flag of the caller's own.
public enum CueTracker {
    /// Slower than this is standing still: no countdown runs, and a photo
    /// stop at a fork does not use up its heads-up.
    public static let stillMps: Double = 0.5

    public enum Announced: Int, Codable, Sendable {
        case none = 0, headsUp = 1, now = 2
    }

    public struct State: Codable, Equatable, Sendable {
        /// The plan's first cue not yet passed.
        public var next: Int
        /// How far it has been said.
        public var announced: Announced
        /// The furthest along the line so far.
        public var highM: Double
        /// The last fix's metres.
        public var lastM: Double?

        public init(next: Int = 0, announced: Announced = .none, highM: Double = 0, lastM: Double? = nil) {
            self.next = next
            self.announced = announced
            self.highM = highM
            self.lastM = lastM
        }

        public static let start = State()
    }

    public struct Event: Equatable, Sendable {
        public enum Moment: String, Sendable {
            case headsUp = "heads_up"
            case now
        }

        public var moment: Moment
        /// Into the plan.
        public var index: Int
    }

    public struct Step: Equatable, Sendable {
        public var state: State
        public var event: Event?
    }

    /// One fix's worth of cue timing.
    ///
    /// - `alongM` nil pauses: no line to be on (off route, a free ride).
    ///   The cue ahead keeps its place, so coming back picks it up again.
    /// - A cue is passed once the rider is half the sport's "now" minimum
    ///   past it.
    /// - Back along the line by more than `rewindM` (turned round at a
    ///   missed fork) re-arms every cue ahead of the rider: the missed fork
    ///   is the way back. Nothing fires while still going back; the cue is
    ///   said once they head for it.
    /// - Standing still fires nothing. `speedMps` nil reads as the sport's
    ///   nominal speed.
    /// - "Now" at the sport's seconds, never nearer than its minimum
    ///   metres; heads-up at its seconds, never nearer than twice "now". A
    ///   rider already inside "now" gets "now" alone.
    public static func advance(
        _ state: State, alongM: Double?, speedMps: Double?, plan: [PlannedCue], sport: CueSport
    ) -> Step {
        let timing = sport.timing
        guard let alongM, alongM.isFinite else { return Step(state: state, event: nil) }
        var next = state.next, announced = state.announced, highM = max(state.highM, alongM)
        let passM = timing.nowMinM / 2
        let goingBack = state.lastM.map { alongM < $0 - passM } ?? false

        if alongM < state.highM - timing.rewindM {
            let back = plan.firstIndex { $0.alongM > alongM - passM } ?? plan.count
            if back < next {
                next = back
                announced = .none
            }
            highM = alongM
        }
        while next < plan.count, alongM > plan[next].alongM + passM {
            next += 1
            announced = .none
        }
        var out = State(next: next, announced: announced, highM: highM, lastM: alongM)
        guard next < plan.count, !goingBack else { return Step(state: out, event: nil) }

        let speed = speedMps.flatMap { $0.isFinite ? $0 : nil } ?? timing.nominalMps
        guard speed >= stillMps else { return Step(state: out, event: nil) }
        let d = plan[next].alongM - alongM
        let nowM = max(timing.nowMinM, speed * timing.nowS)
        let headsUpM = max(2 * nowM, speed * timing.headsUpS)
        if announced.rawValue < Announced.now.rawValue, d <= nowM {
            out.announced = .now
            return Step(state: out, event: Event(moment: .now, index: next))
        }
        if announced == .none, d <= headsUpM {
            out.announced = .headsUp
            return Step(state: out, event: Event(moment: .headsUp, index: next))
        }
        return Step(state: out, event: nil)
    }
}

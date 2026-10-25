import Foundation
import Testing
@testable import TrailPhysics

/// The cue vectors the JavaScript port pins (`Fixtures/cues.json`, a
/// byte-identical copy of the file its `test/build-cue-fixtures.mjs`
/// writes): each case's plan and each trace's events, exactly.
struct CueFixtureTests {
    struct Fixture: Decodable {
        struct Case: Decodable {
            var name: String
            var sport: CueSport
            var cumulative: [Double]
            var elevations: [Double?]
            var segments: [CueWay]
            var cues: RouteCue.List
            var plan: [PlannedCue]
        }

        struct Trace: Decodable {
            var name: String
            var `case`: String
            var fixes: [[Double?]]
            var events: [Event]
            var final: CueTracker.State
        }

        /// `[fix index, type, cue index]`.
        struct Event: Decodable, Equatable {
            var fix: Int
            var type: String
            var index: Int

            init(fix: Int, type: String, index: Int) {
                self.fix = fix
                self.type = type
                self.index = index
            }

            init(from decoder: Decoder) throws {
                var c = try decoder.unkeyedContainer()
                fix = try c.decode(Int.self)
                type = try c.decode(String.self)
                index = try c.decode(Int.self)
            }
        }

        var version: Int
        var cases: [Case]
        var traces: [Trace]
    }

    static let fixture: Fixture = {
        let url = Bundle.module.url(forResource: "cues", withExtension: "json", subdirectory: "Fixtures")!
        return try! JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }()

    @Test("Every case's plan, as the JavaScript port makes it", arguments: fixture.cases.map(\.name))
    func plan(_ name: String) throws {
        let c = try #require(Self.fixture.cases.first { $0.name == name })
        let plan = CuePlan.build(cues: c.cues.cues, ways: c.segments, cumulative: c.cumulative, elevations: c.elevations, sport: c.sport)
        #expect(plan == c.plan)
    }

    @Test("Every trace's events and final state", arguments: fixture.traces.map(\.name))
    func trace(_ name: String) throws {
        let t = try #require(Self.fixture.traces.first { $0.name == name })
        let c = try #require(Self.fixture.cases.first { $0.name == t.case })
        var state = CueTracker.State.start
        var events: [Fixture.Event] = []
        for (i, fix) in t.fixes.enumerated() {
            let step = CueTracker.advance(state, alongM: fix[0], speedMps: fix[1], plan: c.plan, sport: c.sport)
            state = step.state
            if let e = step.event { events.append(.init(fix: i, type: e.moment.rawValue, index: e.index)) }
        }
        #expect(events == t.events)
        #expect(state == t.final)
    }
}

struct CueTests {
    private func cues(_ json: String) throws -> [RouteCue] {
        try JSONDecoder().decode(RouteCue.List.self, from: Data(json.utf8)).cues
    }

    @Test("The route API's shape; what it does not know reads as other, a bad cue is left out")
    func parsing() throws {
        let list = try cues("""
        [{"point": 9, "maneuver": "arrive", "source": "route"},
         {"point": 6, "distance_m": 310, "maneuver": "keep_left", "turn_deg": 2, "exit": null, "name": "", "ref": "B 37",
          "other_ways_deg": [33], "source": "fork"},
         {"point": -1, "maneuver": "left"},
         {"point": 7, "maneuver": "jump"}]
        """)
        #expect(list.map(\.point) == [6, 7, 9])
        #expect(list[0] == RouteCue(point: 6, distanceM: 310, maneuver: .keepLeft, turnDeg: 2, ref: "B 37", otherWaysDeg: [33], source: .fork))
        #expect(list[1].maneuver == .other && list[1].source == .engine)
    }

    @Test("Each profile is timed for its sport")
    func sports() {
        #expect(RouteProfile.allCases.map { CueSport.for(profile: $0) }
            == RouteProfile.allCases.map { [.hiking: .foot, .trailrun: .run, .roadrun: .run, .road: .road, .roadfast: .road][$0] ?? .bike })
        #expect(abs(CueSport.foot.timing.mergeM - 18) < 1e-9)
    }

    @Test("A fork cue on a road that goes on is dropped when riding, never on foot")
    func forkRule() throws {
        let list = try cues("""
        [{"point": 4, "maneuver": "keep_left", "turn_deg": 0, "other_ways_deg": [30], "source": "fork"},
         {"point": 10, "maneuver": "keep_right", "turn_deg": 3, "other_ways_deg": [-30], "source": "fork"}]
        """)
        let ways = [CueWay(fromPoint: 0, toPoint: 10, roadClass: "secondary"), CueWay(fromPoint: 10, toPoint: 20, roadClass: "track")]
        let line = (0...20).map { Double($0) * 10 }
        #expect(CuePlan.build(cues: list, ways: ways, cumulative: line, elevations: nil, sport: .road).map(\.point) == [10])
        #expect(CuePlan.build(cues: list, ways: ways, cumulative: line, elevations: nil, sport: .foot).map(\.point) == [4, 10])
    }

    @Test("Heads-up then now, each once; nothing standing still or off the line")
    func tracker() {
        let plan = CuePlan.build(
            cues: [RouteCue(point: 10, maneuver: .left), RouteCue(point: 20, maneuver: .right)],
            ways: [CueWay(fromPoint: 0, toPoint: 30, roadClass: "path")],
            cumulative: (0...30).map { Double($0) * 10 }, elevations: nil, sport: .foot
        )
        func run(_ fixes: [(Double?, Double?)]) -> [String?] {
            var state = CueTracker.State.start
            return fixes.map { fix in
                let step = CueTracker.advance(state, alongM: fix.0, speedMps: fix.1, plan: plan, sport: .foot)
                state = step.state
                return step.event.map { "\($0.moment.rawValue)\($0.index)" }
            }
        }
        #expect(run([(0, 1.2), (46, 1.2), (50, 1.2), (91, 1.2), (95, 1.2)]) == [nil, "heads_up0", nil, "now0", nil])
        #expect(run([(60, 0.1), (95, 0), (nil, 1.2), (95, 1.2)]) == [nil, nil, nil, "now0"])
        #expect(run([(95, 1.2), (150, 1.2)]) == ["now0", "heads_up1"])
    }
}

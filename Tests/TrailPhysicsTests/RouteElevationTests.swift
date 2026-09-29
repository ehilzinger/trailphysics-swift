import CoreLocation
import Foundation
import Testing
@testable import TrailPhysics

/// The elevation figures: the incline is measured over a window, so a single
/// noisy vertex cannot become the route's "max incline".
struct RouteElevationTests {
    /// A straight line north, one vertex every ~50 m.
    private func line(_ count: Int) -> [CLLocationCoordinate2D] {
        (0..<count).map { CLLocationCoordinate2D(latitude: 48.0 + Double($0) * 0.00045, longitude: 11.0) }
    }

    /// The window is calibrated against a real road climb rather than picked
    /// round: Alpe d'Huez's steepest ramps are documented at about 13%, which
    /// a 100 m window overstates as 18% by still reading the elevation
    /// model's own noise. Ported from the JavaScript port's test of the same
    /// name, so the two cannot move the constant apart again.
    @Test("Max incline is measured over a 200 m window")
    func measuresOverTwoHundredMetres() throws {
        // 300 m of line, one vertex every 10 m, rising 30 m in its first
        // 100 m only. A 100 m window would report that as 30%; a 200 m one
        // spreads the same 30 m over 200 m.
        let metresPerDegree = 6_371_000 * Double.pi / 180
        let latlngs = (0..<31).map {
            CLLocationCoordinate2D(latitude: 48 + Double($0) * 10 / metresPerDegree, longitude: 11)
        }
        let elevations = (0..<31).map { 100 + Double(min($0, 10)) * 3 }
        let pct = try #require(RouteElevation.maxInclinePct(latlngs: latlngs, elevations: elevations))
        #expect(RouteElevation.inclineWindowM == 200)
        #expect(abs(pct - 15) < 0.5)
    }

    @Test("A steady 10 % climb reads as 10 %, a lone spike does not")
    func incline() {
        let latlngs = line(21) // ~1 km
        let steady = (0..<21).map { Double($0) * 5.0 } // 5 m per 50 m
        let pct = RouteElevation.maxInclinePct(latlngs: latlngs, elevations: steady)
        #expect(pct != nil)
        #expect(abs((pct ?? 0) - 10) < 1.5)

        // One vertex 40 m above its neighbours: 80 % point to point, but the
        // 100 m window sees at most 40 m over 100 m.
        var spiked = Array(repeating: 100.0, count: 21)
        spiked[10] = 140
        let spikePct = RouteElevation.maxInclinePct(latlngs: latlngs, elevations: spiked) ?? 0
        #expect(spikePct < 45)
    }

    @Test("The profile resamples to the requested count and keeps the extremes")
    func profile() {
        let latlngs = line(11)
        let elevations = [100.0, 120, 140, 160, 180, 200, 180, 160, 140, 120, 100]
        let profile = RouteElevation.profile(latlngs: latlngs, elevations: elevations, samples: 50)
        #expect(profile?.points.count == 50)
        #expect(profile?.minM == 100)
        #expect(profile?.maxM == 200)
        #expect(profile?.points.first?.x == 0)
        #expect(profile?.points.last?.x == 1)
    }

    @Test("Missing or unplaceable elevations give no figures rather than wrong ones")
    func missing() {
        #expect(RouteElevation.maxInclinePct(latlngs: line(5), elevations: nil) == nil)
        #expect(RouteElevation.maxInclinePct(latlngs: line(5), elevations: [1]) == nil)
        // More elevations than vertices can't be placed on the line.
        #expect(RouteElevation.profile(latlngs: line(5), elevations: [1, 2, 3, 4, 5, 6], samples: 10) == nil)
    }

    @Test("Storage thins to the chart's resolution and whole metres, keeping both ends")
    func storage() {
        #expect(RouteElevation.profileForStorage(nil) == nil)
        #expect(RouteElevation.profileForStorage([100]) == nil)
        #expect(RouteElevation.profileForStorage([100.4, 120.6]) == [100, 121])

        let long = (0..<3000).map { Double($0) * 0.5 }
        let stored = RouteElevation.profileForStorage(long)
        #expect(stored?.count == RouteElevation.maxStoredPoints)
        #expect(stored?.first == 0)
        #expect(stored?.last == long.last?.rounded())
    }

    @Test("Jitter is not climbing, and a real climb is counted whole")
    func ascent() {
        #expect(RouteElevation.ascent(nil) == nil)
        #expect(RouteElevation.ascent([100]) == nil)

        // One unbroken 60 m climb, then back down: 60 m, not 120.
        #expect(RouteElevation.ascent([100, 130, 160, 120, 100]) == 60)

        // A thousand ±2 m wobbles on a flat road are the elevation model's
        // noise. Unfiltered summation reported a kilometre of climbing on a
        // route with none, which is how a 546 km tour came to advertise
        // 6280 m against a true 4200.
        let flat = (0..<1000).map { $0.isMultiple(of: 2) ? 100.0 : 102.0 }
        #expect(RouteElevation.ascent(flat) == 0)

        // The filter is a floor on one rise, not on the total: thirty
        // separate 6 m rises are 180 m of real climbing.
        var rolling: [Double] = [100]
        for _ in 0..<30 {
            rolling.append(contentsOf: [106, 100])
            rolling[rolling.count - 2] = rolling[rolling.count - 3] + 6
            rolling[rolling.count - 1] = rolling[rolling.count - 3]
        }
        #expect(RouteElevation.ascent(rolling) == 180)
    }

    @Test("A day's ascent measures its own slice and carries nothing in")
    func ascentOfSlice() {
        // Climbs 50 m over the first half, 20 m over the second.
        let elevations: [Double] = [0, 25, 50, 40, 60]
        #expect(RouteElevation.ascent(elevations, from: 0, through: 2) == 50)
        #expect(RouteElevation.ascent(elevations, from: 2, through: 4) == 20)
        // An empty or inverted slice is no climbing rather than a crash.
        #expect(RouteElevation.ascent(elevations, from: 3, through: 3) == 0)
        #expect(RouteElevation.ascent(elevations, from: 4, through: 1) == 0)
        // A slice reaching past the end stops at the end.
        #expect(RouteElevation.ascent(elevations, from: 0, through: 99) == 70)
    }

    @Test("A profile read back from storage lands on the vertices it was sampled from")
    func thinnedReadsBack() {
        let latlngs = line(1001) // ~50 km
        let full = (0..<1001).map { Double($0) * 5.0 } // 10 % all the way
        let stored = RouteElevation.profileForStorage(full)!
        #expect(stored.count == 240)

        let pct = RouteElevation.maxInclinePct(latlngs: latlngs, elevations: stored)
        #expect(pct != nil)
        #expect(abs((pct ?? 0) - 10) < 1.5)

        let profile = RouteElevation.profile(latlngs: latlngs, elevations: stored, samples: 50)
        #expect(profile?.points.count == 50)
        #expect(profile?.minM == 0)
        #expect(profile?.maxM == 5000)
        #expect(abs((profile?.totalKm ?? 0) - 50) < 1)
    }

    /// The other half of storage thinning: 240 points is a fine profile for
    /// a day ride and a very coarse one for a tour, and the incline figure
    /// is the one that cannot survive the coarseness.
    @Test("An incline the stored samples cannot resolve is refused")
    func inclineRefusesCoarseSamples() {
        // A 600 km line thinned to 240 samples is one every 2.5 km.
        let long = (0..<12_001).map {
            CLLocationCoordinate2D(latitude: 45.0 + Double($0) * 0.00045, longitude: 11.0)
        }
        let full = (0..<12_001).map { index -> Double in
            // A 10 % climb of 1 km every 20 km, flat in between: the shape a
            // 2.5 km sample spacing averages into nothing.
            let intoBlock = index % 400
            return intoBlock < 20 ? Double(intoBlock) * 5 : 100
        }
        #expect(RouteElevation.maxInclinePct(latlngs: long, elevations: full) != nil)
        let stored = RouteElevation.profileForStorage(full)
        #expect(RouteElevation.maxInclinePct(latlngs: long, elevations: stored) == nil)

        // The same thinning on a route short enough for the samples to still
        // land inside a climb keeps its figure — see `thinnedReadsBack`.
        let short = line(1001)
        let spacing = (RouteGeometry.cumulativeDistances(short).last ?? 0) / 239
        #expect(spacing < RouteElevation.maxInclineSpacingM)
    }

    @Test("A scrub lands on an exact anchor's own elevation")
    func selectionAtAnchor() {
        let latlngs = line(21) // ~1 km, one vertex every ~50 m
        let elevations = (0..<21).map { Double($0) * 5.0 } // 10 % all the way
        // Anchor 10 sits at ~500 m — 0.5 km — with elevation 50.
        let selection = RouteElevation.selection(at: 0.5, latlngs: latlngs, elevations: elevations)
        #expect(selection != nil)
        #expect(abs((selection?.elevationM ?? 0) - 50) < 1)
        #expect(abs((selection?.inclinePct ?? 0) - 10) < 1.5)
    }

    @Test("A scrub between two anchors interpolates, and a descent reads negative")
    func selectionInterpolates() {
        let latlngs = line(11)
        // A climb up to the midpoint, then straight back down.
        let elevations = [100.0, 120, 140, 160, 180, 200, 180, 160, 140, 120, 100]
        let total = RouteGeometry.cumulativeDistances(latlngs).last ?? 0

        let midKm = total / 2 / 1000
        let onClimb = RouteElevation.selection(at: midKm * 0.4, latlngs: latlngs, elevations: elevations)
        #expect(onClimb != nil)
        #expect((onClimb?.inclinePct ?? 0) > 0)

        let onDescent = RouteElevation.selection(at: midKm * 1.6, latlngs: latlngs, elevations: elevations)
        #expect(onDescent != nil)
        #expect((onDescent?.inclinePct ?? 0) < 0)
    }

    @Test("A scrub past either end clamps to that end's own elevation")
    func selectionClampsAtEdges() {
        let latlngs = line(11)
        let elevations = [100.0, 120, 140, 160, 180, 200, 180, 160, 140, 120, 100]
        let total = (RouteGeometry.cumulativeDistances(latlngs).last ?? 0) / 1000

        let before = RouteElevation.selection(at: -5, latlngs: latlngs, elevations: elevations)
        #expect(abs((before?.elevationM ?? -1) - 100) < 0.1)
        #expect(abs((before?.km ?? -1) - 0) < 0.01)

        let after = RouteElevation.selection(at: total + 5, latlngs: latlngs, elevations: elevations)
        #expect(abs((after?.elevationM ?? -1) - 100) < 0.1)
        #expect(abs((after?.km ?? -1) - total) < 0.01)
    }

    @Test("Missing or unplaceable elevations give no selection")
    func selectionMissing() {
        #expect(RouteElevation.selection(at: 1, latlngs: line(5), elevations: nil) == nil)
        #expect(RouteElevation.selection(at: 1, latlngs: line(5), elevations: [1]) == nil)
        #expect(RouteElevation.selection(at: 1, latlngs: line(5), elevations: [1, 2, 3, 4, 5, 6]) == nil)
    }
}

/// How many points a drawn profile is resampled to. One number for every
/// route made a 600 km tour a smoothed line: at 120 points that is a sample
/// every 5 km, so every climb was averaged out of the shape and out of the
/// colours drawn from it.
struct ProfileResolutionTests {
    @Test("Samples follow the route's length, between a floor and a ceiling")
    func samplesScale() {
        let plenty = 100_000
        // Short rides keep the resolution they always had.
        #expect(RouteElevation.profileSamples(totalKm: 8, available: plenty)
            == RouteElevation.profileSampleFloor)
        #expect(RouteElevation.profileSamples(totalKm: 120, available: plenty)
            == RouteElevation.profileSampleFloor)
        // About one per kilometre in between.
        #expect(RouteElevation.profileSamples(totalKm: 600, available: plenty) == 600)
        // And a ceiling, so a 3,000 km tour does not carry a point per km.
        #expect(RouteElevation.profileSamples(totalKm: 3_000, available: plenty)
            == RouteElevation.profileSampleCeiling)
    }

    @Test("Never more samples than the profile actually holds")
    func neverInventsPoints() {
        // A stored profile is 240 points however long the route is: asking
        // for 600 interpolates 360 of them and draws the same line.
        #expect(RouteElevation.profileSamples(totalKm: 600, available: 240) == 240)
        #expect(RouteElevation.profileSamples(totalKm: 600, available: 0) == 2)
        #expect(RouteElevation.profileSamples(totalKm: .nan, available: 1_000)
            == RouteElevation.profileSampleFloor)
    }

    /// The point of the ceiling: zooming to the narrowest window the chart
    /// allows must still leave a sample behind every stroke it draws.
    @Test("A zoomed window still holds a sample per stroke")
    func zoomKeepsDetail() {
        // The numbers of the chart the ceiling was sized for: one stroke per
        // 5.5 pt of width, and a floor of a twentieth of the route on the
        // zoom.
        let strokesOnAPhone = Int((393.0 - 4) / 5.5)
        let samplesInTheNarrowestWindow =
            Double(RouteElevation.profileSampleCeiling) * 0.05
        #expect(samplesInTheNarrowestWindow >= Double(strokesOnAPhone))
    }

    @Test("A long route's profile resolves a climb the old sampling missed")
    func resolvesAClimb() {
        // 600 km with a single 2 km wall in the middle of it. At a sample
        // every 5 km the wall lands between two samples and flattens; at a
        // sample per kilometre it survives.
        let latlngs = (0..<12_001).map {
            CLLocationCoordinate2D(latitude: 45.0 + Double($0) * 0.00045, longitude: 11.0)
        }
        let elevations = (0..<12_001).map { index -> Double in
            let wall = 6_000
            if index < wall { return 0 }
            if index < wall + 40 { return Double(index - wall) * 5 }
            return 200
        }
        let coarse = RouteElevation.profile(latlngs: latlngs, elevations: elevations, samples: 120)
        let scaled = RouteElevation.profile(
            latlngs: latlngs, elevations: elevations,
            samples: RouteElevation.profileSamples(totalKm: 600, available: elevations.count)
        )
        #expect(scaled?.points.count == 600)
        // The steepest step the drawn points contain, as a share of the
        // wall's real 10 %: the coarse profile spreads it over 5 km.
        func steepestStep(_ profile: RouteElevation.Profile?) -> Double {
            guard let profile, profile.points.count > 1 else { return 0 }
            let stepM = profile.totalKm * 1000 / Double(profile.points.count - 1)
            var steepest = 0.0
            for index in 1..<profile.points.count {
                let rise = profile.points[index].y - profile.points[index - 1].y
                steepest = max(steepest, rise / stepM * 100)
            }
            return steepest
        }
        #expect(steepestStep(coarse) < 5)
        #expect(steepestStep(scaled) > steepestStep(coarse) * 2)
    }
}

/// Colouring the profile by gradient. The shape says where the climbs are;
/// the colour says how hard they are. Both halves are worth pinning: which
/// band a gradient lands in, and that the bands together still cover the
/// whole chart with no gaps.
///
/// Ported case for case from `route-stats.test.js` in Hatchure's web
/// implementation, so the two cannot drift on the thresholds or the
/// fallbacks.
struct InclineBandTests {
    /// `count` evenly spaced samples rising by `riseM` each step.
    private func ramp(_ count: Int, riseM: Double) -> [(x: Double, y: Double)] {
        (0..<count).map {
            (x: Double($0) / Double(count - 1), y: Double($0) * riseM)
        }
    }

    @Test("A climb bands by steepness")
    func bandsBySteepness() {
        #expect(RouteElevation.inclineBand(1) == .gentle)
        #expect(RouteElevation.inclineBand(6) == .moderate)
        #expect(RouteElevation.inclineBand(10) == .hard)
        #expect(RouteElevation.inclineBand(20) == .severe)
    }

    @Test("A threshold value lands in the harder band")
    func thresholdsRoundUp() {
        // 4 % is the start of the second band, not the end of the first —
        // otherwise a sustained 4 % would read as a drag.
        #expect(RouteElevation.inclineBand(3.99) == .gentle)
        #expect(RouteElevation.inclineBand(4) == .moderate)
        #expect(RouteElevation.inclineBand(8) == .hard)
        #expect(RouteElevation.inclineBand(12) == .severe)
    }

    @Test("Descents and flats are gentle")
    func descentsAreGentle() {
        // Uphill only, matching maxInclinePct: a gradient figure is about
        // what has to be climbed. Colouring a 10 % descent like a 10 % climb
        // would make a mostly-downhill route look punishing.
        #expect(RouteElevation.inclineBand(0) == .gentle)
        #expect(RouteElevation.inclineBand(-5) == .gentle)
        #expect(RouteElevation.inclineBand(-20) == .gentle)
    }

    @Test("A gradient it cannot use falls back to gentle")
    func nonFiniteIsGentle() {
        // A division by a zero distance is missing data, not an infinitely
        // steep wall, and painting it red would state something about the
        // route that nobody measured.
        #expect(RouteElevation.inclineBand(.nan) == .gentle)
        #expect(RouteElevation.inclineBand(.infinity) == .gentle)
        #expect(RouteElevation.inclineBand(-.infinity) == .gentle)
    }

    @Test("A uniformly gentle route is one run")
    func oneRunWhenGentle() {
        let flat = (0..<40).map { (x: Double($0) / 39, y: 100.0) }
        let runs = RouteElevation.bandRuns(points: flat, totalKm: 10)
        #expect(runs.count == 1)
        #expect(runs.first?.band == .gentle)
    }

    @Test("A run splits where the gradient crosses a threshold")
    func splitsAtThreshold() {
        // Flat, then a wall: more than one run, the last harder than the first.
        let mixed: [(x: Double, y: Double)] = [
            (0, 0), (1.0 / 6, 0), (2.0 / 6, 0), (3.0 / 6, 0),
            (4.0 / 6, 50), (5.0 / 6, 100), (1, 150)
        ]
        let runs = RouteElevation.bandRuns(points: mixed, totalKm: 1)
        #expect(runs.count > 1)
        #expect(runs.first?.band == .gentle)
        #expect(runs.last?.band != .gentle)
    }

    @Test("Adjacent runs share an edge, leaving no gap between bands")
    func noGapBetweenRuns() {
        // Each run starts where the previous ended, or the fill shows
        // hairlines of background between the bands.
        let mixed: [(x: Double, y: Double)] = [
            (0, 0), (1.0 / 6, 0), (2.0 / 6, 40), (3.0 / 6, 80),
            (4.0 / 6, 80), (5.0 / 6, 80), (1, 200)
        ]
        let runs = RouteElevation.bandRuns(points: mixed, totalKm: 1)
        #expect(runs.count > 1)
        for index in 1..<runs.count {
            #expect(runs[index].from == runs[index - 1].to)
        }
    }

    @Test("The runs span the profile end to end")
    func spansFullWidth() {
        let mixed: [(x: Double, y: Double)] = [
            (0, 0), (1.0 / 6, 30), (2.0 / 6, 60), (3.0 / 6, 60),
            (4.0 / 6, 20), (5.0 / 6, 90), (1, 140)
        ]
        let runs = RouteElevation.bandRuns(points: mixed, totalKm: 2)
        #expect(runs.first?.from == 0)
        #expect(runs.last?.to == mixed.count - 1)
    }

    @Test("Without a usable distance everything is one gentle band")
    func noDistanceIsGentle() {
        // Every gradient would be infinite or NaN; rendering that as red
        // would be a lie about a route nobody measured.
        let climb = ramp(3, riseM: 100)
        let runs = RouteElevation.bandRuns(points: climb, totalKm: 0)
        #expect(!runs.isEmpty)
        #expect(runs.allSatisfy { $0.band == .gentle })
    }

    @Test("A profile with nothing to band gives no runs")
    func tooFewPoints() {
        #expect(RouteElevation.bandRuns(points: [], totalKm: 5).isEmpty)
        #expect(RouteElevation.bandRuns(points: [(x: 0, y: 100)], totalKm: 5).isEmpty)
    }
}

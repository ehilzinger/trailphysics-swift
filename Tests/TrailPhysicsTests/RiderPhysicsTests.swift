import CoreLocation
import Foundation
import Testing
@testable import TrailPhysics

/// `normalize` rejects an out-of-band profile outright rather than clamping
/// it — "no profile" must stay distinguishable from "a profile made of
/// guesses".
struct RiderNormalizeTests {
    @Test("Out-of-band rider weight is rejected, not clamped")
    func rejectsRiderWeight() {
        let tooLight = RiderPhysics.Rider(riderKg: 10, watts: 150)
        #expect(RiderPhysics.normalize(tooLight) == nil)

        let tooHeavy = RiderPhysics.Rider(riderKg: 500, watts: 150)
        #expect(RiderPhysics.normalize(tooHeavy) == nil)
    }

    @Test("Out-of-band watts is rejected, not clamped")
    func rejectsWatts() {
        let tooLittle = RiderPhysics.Rider(riderKg: 75, watts: 5)
        #expect(RiderPhysics.normalize(tooLittle) == nil)

        let tooMuch = RiderPhysics.Rider(riderKg: 75, watts: 5000)
        #expect(RiderPhysics.normalize(tooMuch) == nil)
    }

    @Test("Nil rider normalizes to nil")
    func nilRider() {
        #expect(RiderPhysics.normalize(nil) == nil)
    }

    @Test("Missing or out-of-band bike weight falls back to the default, not rejection")
    func defaultsBikeWeight() {
        let noBikeWeight = RiderPhysics.Rider(riderKg: 75, watts: 150)
        let params = RiderPhysics.normalize(noBikeWeight)
        #expect(params?.totalKg == 75 + RiderPhysics.defaultBikeKg)

        let outOfBand = RiderPhysics.Rider(riderKg: 75, bikeKg: 999, watts: 150)
        #expect(RiderPhysics.normalize(outOfBand)?.totalKg == 75 + RiderPhysics.defaultBikeKg)
    }

    @Test("An unknown bike type or surface falls back to the default rather than failing")
    func unknownEnumsFallBack() {
        let rider = RiderPhysics.Rider(
            riderKg: 75, watts: 150, bikeType: "spaceship", surface: "lava"
        )
        let params = RiderPhysics.normalize(rider)
        #expect(params?.bikeType == RiderPhysics.defaultBikeType)
        #expect(params?.surface == RiderPhysics.defaultSurface)
    }

    @Test("An explicit CdA is honoured; an out-of-range one is ignored in favor of the derived default")
    func explicitCdA() {
        let measured = RiderPhysics.Rider(riderKg: 75, watts: 150, cda: 0.28)
        #expect(RiderPhysics.normalize(measured)?.cda == 0.28)

        let nonsense = RiderPhysics.Rider(riderKg: 75, watts: 150, cda: 5.0)
        let fallback = RiderPhysics.normalize(nonsense)
        #expect(fallback?.cda == RiderPhysics.bikeTypeCdA[RiderPhysics.defaultBikeType])
    }
}

struct RiderSolveTests {
    private func flatParams(watts: Double = 150, totalKg: Double = 93) -> RiderPhysics.NormalizedParams {
        RiderPhysics.NormalizedParams(
            totalKg: totalKg, watts: watts,
            cda: RiderPhysics.bikeTypeCdA[RiderPhysics.defaultBikeType]!,
            crr: RiderPhysics.crrBySurface[RiderPhysics.defaultSurface]!,
            bikeType: RiderPhysics.defaultBikeType, surface: RiderPhysics.defaultSurface,
            fatigue: false, rho: RiderPhysics.airDensitySeaLevel
        )
    }

    @Test("On flat ground the solved speed satisfies the power-balance equation")
    func flatGroundSatisfiesBalance() {
        let params = flatParams()
        let v = RiderPhysics.solveSpeedMs(watts: params.watts, gradient: 0, params: params)

        // P·η = v · ( m·g·Crr + ½·ρ·CdA·v² ), rearranged as a residual.
        let drive = params.watts * RiderPhysics.drivetrainEfficiency
        let resist = v * (params.totalKg * RiderPhysics.gravity * params.crr
            + 0.5 * params.rho * params.cda * v * v)
        #expect(abs(drive - resist) < 1e-6)
    }

    @Test("A steeper climb is slower than a shallow one at the same power")
    func steeperClimbIsSlower() {
        let params = flatParams()
        let shallow = RiderPhysics.solveSpeedMs(watts: params.watts, gradient: 0.02, params: params)
        let steep = RiderPhysics.solveSpeedMs(watts: params.watts, gradient: 0.08, params: params)
        #expect(steep < shallow)
    }

    @Test("Below the coasting gradient the rider free-wheels at zero watts")
    func coastsOnSteepDescent() {
        let params = flatParams()
        let coasting = RiderPhysics.speedForGradientMs(-0.05, params: params)
        let zeroWatts = RiderPhysics.solveSpeedMs(watts: 0, gradient: -0.05, params: params)
        #expect(abs(coasting - zeroWatts) < 1e-9)
    }

    @Test("The descent speed never exceeds the braking cap")
    func cappedDescent() {
        let params = flatParams()
        let v = RiderPhysics.speedForGradientMs(-0.15, params: params)
        #expect(v * 3.6 <= RiderPhysics.maxDescentKmh + 1e-9)
    }
}

struct RiderFatigueTests {
    @Test("An hour or less applies no fatigue")
    func noFatigueUnderOneHour() {
        #expect(RiderPhysics.fatigueFactor(hours: 1) == 1)
        #expect(RiderPhysics.fatigueFactor(hours: 0.5) == 1)
        #expect(RiderPhysics.fatigueFactor(hours: nil) == 1)
    }

    @Test("Fatigue decays but never below the floor")
    func decaysAndFloors() {
        let sixHours = RiderPhysics.fatigueFactor(hours: 6)
        #expect(sixHours < 1 && sixHours >= RiderPhysics.minFatigueFactor)

        // 0.75^(-1/0.04) ≈ 566 hours is where the unfloored curve would
        // reach the floor exactly; well past that it must still be pinned.
        let extremeHours = RiderPhysics.fatigueFactor(hours: 5000)
        #expect(extremeHours == RiderPhysics.minFatigueFactor)
    }

    @Test("A single-day route uses its own total; a split route caps at the longest day")
    func dayCap() {
        #expect(RiderPhysics.fatigueHours(totalHours: 40, dayHours: nil) == 40)
        #expect(RiderPhysics.fatigueHours(totalHours: 40, dayHours: 8) == 8)
        // A day figure longer than the total is clamped to the total.
        #expect(RiderPhysics.fatigueHours(totalHours: 5, dayHours: 8) == 5)
    }
}

struct RiderEstimateSpeedTests {
    @Test("With no rider profile, the estimate is nil")
    func nilWithoutProfile() {
        #expect(RiderPhysics.estimateSpeedKmh(rider: nil, distanceKm: 50, ascentM: 200) == nil)
    }

    @Test("The mean gradient fed into the solve is half the naive ascent/distance ratio")
    func halvesTheGradient() {
        let rider = RiderPhysics.Rider(riderKg: 75, bikeKg: 18, watts: 150)
        let distanceKm = 100.0
        let ascentM = 1000.0

        let estimated = RiderPhysics.estimateSpeedKmh(rider: rider, distanceKm: distanceKm, ascentM: ascentM)
        #expect(estimated != nil)

        // Hand-compute the same figure via the halved gradient directly.
        guard let params = RiderPhysics.normalize(rider) else {
            Issue.record("expected a valid normalized profile")
            return
        }
        var flatRho = params
        flatRho.rho = RiderPhysics.airDensitySeaLevel
        let gradient = (ascentM / (distanceKm * 1000)) / 2
        let expectedMs = RiderPhysics.speedForGradientMs(gradient, params: flatRho)
        #expect(abs(estimated! - expectedMs * 3.6) < 1e-6)
    }

    @Test("Zero or negative distance yields nil")
    func rejectsBadDistance() {
        let rider = RiderPhysics.Rider(riderKg: 75, watts: 150)
        #expect(RiderPhysics.estimateSpeedKmh(rider: rider, distanceKm: 0, ascentM: 100) == nil)
        #expect(RiderPhysics.estimateSpeedKmh(rider: rider, distanceKm: -10, ascentM: 100) == nil)
    }

    @Test("A route with no ascent still estimates, at zero gradient")
    func noAscentStillEstimates() {
        let rider = RiderPhysics.Rider(riderKg: 75, watts: 150)
        let flat = RiderPhysics.estimateSpeedKmh(rider: rider, distanceKm: 50, ascentM: nil)
        #expect(flat != nil && flat! > 0)
    }
}

struct RiderDetailedSpeedTests {
    private func line(_ n: Int, stepDegrees: Double = 0.01) -> [CLLocationCoordinate2D] {
        (0..<n).map { CLLocationCoordinate2D(latitude: 48.0 + Double($0) * stepDegrees, longitude: 11.0) }
    }

    @Test("Too little geometry or elevation yields nil")
    func rejectsShortInput() {
        let rider = RiderPhysics.Rider(riderKg: 75, watts: 150)
        #expect(RiderPhysics.detailedSpeedKmh(rider: rider, latlngs: line(1), elevations: [1]) == nil)
        #expect(RiderPhysics.detailedSpeedKmh(rider: rider, latlngs: line(5), elevations: nil) == nil)
    }

    @Test("The detailed solve is a time-weighted harmonic mean, not an arithmetic mean of segment speeds")
    func harmonicNotArithmeticMean() {
        // Two equal-distance segments: one steep climb, one fast descent.
        // Roughly 1.1 km per segment at this latitude step.
        let rider = RiderPhysics.Rider(riderKg: 75, bikeKg: 18, watts: 150)
        let latlngs = line(3, stepDegrees: 0.01)
        let elevations: [Double] = [0, 300, 0]

        guard let detailed = RiderPhysics.detailedSpeedKmh(rider: rider, latlngs: latlngs, elevations: elevations)
        else {
            Issue.record("expected a detailed speed")
            return
        }

        // Compute each segment's own solved speed to build the naive
        // arithmetic mean for comparison.
        guard var params = RiderPhysics.normalize(rider) else {
            Issue.record("expected a valid normalized profile")
            return
        }
        let cum = RouteGeometry.cumulativeDistances(latlngs)
        let runUp = cum[1] - cum[0]
        let runDown = cum[2] - cum[1]
        params.rho = RiderPhysics.airDensitySeaLevel
        let upMs = RiderPhysics.speedForGradientMs(300 / runUp, params: params)
        let downMs = RiderPhysics.speedForGradientMs(-300 / runDown, params: params)
        let arithmeticMeanKmh = (upMs + downMs) / 2 * 3.6

        // The harmonic (time-weighted) mean is pulled toward the slower
        // segment and must be strictly less than the naive arithmetic mean
        // whenever the two segment speeds differ.
        #expect(detailed < arithmeticMeanKmh)
    }

    @Test("A thinned elevation array (fewer points than the geometry) is still walked correctly")
    func handlesThinnedElevations() {
        let rider = RiderPhysics.Rider(riderKg: 75, bikeKg: 18, watts: 150)
        let latlngs = line(11, stepDegrees: 0.002)
        // Only 3 elevation samples for 11 geometry points, forcing the
        // stride-mapping path.
        let elevations: [Double] = [0, 50, 0]

        let result = RiderPhysics.detailedSpeedKmh(rider: rider, latlngs: latlngs, elevations: elevations)
        #expect(result != nil && result! > 0)
    }

    @Test("The two tiers stay distinguishable on a lumpy route")
    func tiersDifferOnLumpyRoute() {
        // What the Overview tab's result line is built on: it states the
        // detailed figure AS A COMPARISON against the quick one, so the two
        // have to be separately obtainable and actually differ where the
        // ascent is unevenly distributed. The quick tier sees only total
        // ascent and cannot tell one wall from an even drag; the detailed
        // tier walks the profile and is the slower, truer figure.
        //
        // If a refactor ever makes the quick tier defer to a cached
        // detailed one, this is what catches it — the panel would silently
        // start reporting "the same as the quick estimate" on every route.
        let rider = RiderPhysics.Rider(riderKg: 75, bikeKg: 18, watts: 150)
        let latlngs = line(5, stepDegrees: 0.01)
        // All the climbing in one wall, then flat: same total ascent as an
        // even spread, materially slower to ride.
        let elevations: [Double] = [0, 400, 400, 400, 400]

        let ascent = 400.0
        let distanceKm = RouteGeometry.cumulativeDistances(latlngs).last! / 1000

        guard let quick = RiderPhysics.estimateSpeedKmh(
                rider: rider, distanceKm: distanceKm, ascentM: ascent),
              let detailed = RiderPhysics.detailedSpeedKmh(
                rider: rider, latlngs: latlngs, elevations: elevations)
        else {
            Issue.record("expected both tiers to solve")
            return
        }

        // Both real speeds, and far enough apart that the result line reports a
        // real difference rather than falling through to "the same".
        #expect(quick.isFinite && quick > 0)
        #expect(detailed.isFinite && detailed > 0)
        #expect(abs(quick - detailed) >= 0.1)
    }
}

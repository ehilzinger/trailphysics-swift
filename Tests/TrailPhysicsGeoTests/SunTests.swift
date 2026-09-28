import Foundation
import Testing
@testable import TrailPhysicsGeo

/// The sunrise equation, against times that can be checked against any
/// almanac. A minute or two of tolerance: the formula is accurate to about
/// that, and pinning it tighter would be testing the arithmetic's noise.
struct SunTests {
    private let munich = (lat: 48.1374, lng: 11.5755)

    private func utc() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.date(from: iso)!
    }

    private func minutes(between a: Date, and b: Date) -> Double {
        abs(a.timeIntervalSince(b)) / 60
    }

    @Test("Midsummer sunset over Munich lands where the almanac puts it")
    func midsummerSunset() throws {
        // 21 June 2026, Munich: sunset about 21:17 local, which is 19:17 UTC.
        let sunset = try #require(Sun.sunset(
            on: date("2026-06-21T12:00:00Z"),
            lat: munich.lat, lng: munich.lng, calendar: utc()
        ))
        #expect(minutes(between: sunset, and: date("2026-06-21T19:17:00Z")) < 3)
    }

    @Test("Midwinter sunset is five hours earlier, and sunrise is after eight")
    func midwinterSunset() throws {
        // 21 December 2026, Munich: sunset about 16:22 local (15:22 UTC),
        // sunrise about 08:03 local (07:03 UTC).
        let sunset = try #require(Sun.sunset(
            on: date("2026-12-21T12:00:00Z"),
            lat: munich.lat, lng: munich.lng, calendar: utc()
        ))
        let sunrise = try #require(Sun.sunrise(
            on: date("2026-12-21T12:00:00Z"),
            lat: munich.lat, lng: munich.lng, calendar: utc()
        ))
        #expect(minutes(between: sunset, and: date("2026-12-21T15:22:00Z")) < 3)
        #expect(minutes(between: sunrise, and: date("2026-12-21T07:03:00Z")) < 3)
        #expect(sunrise < sunset)
    }

    @Test("Dusk comes after sunset, by something like half an hour")
    func duskFollowsSunset() throws {
        let sunset = try #require(Sun.sunset(
            on: date("2026-09-07T12:00:00Z"),
            lat: munich.lat, lng: munich.lng, calendar: utc()
        ))
        let dusk = try #require(Sun.duskEnds(
            on: date("2026-09-07T12:00:00Z"),
            lat: munich.lat, lng: munich.lng, calendar: utc()
        ))
        #expect(dusk > sunset)
        let gap = minutes(between: dusk, and: sunset)
        #expect(gap > 25 && gap < 50)
    }

    @Test("A midnight-sun day has no sunset at all, which is an answer")
    func polarDay() {
        // Nordkapp in June: the sun does not set, so nil rather than a
        // made-up time.
        #expect(Sun.sunset(
            on: date("2026-06-21T12:00:00Z"), lat: 71.17, lng: 25.78, calendar: utc()
        ) == nil)
    }

    @Test("The evening asked about is the evening the date falls on")
    func lateArrivalAsksAboutItsOwnEvening() throws {
        // An arrival at 23:50 asks about that night's sunset, not the next
        // day's — the failure a naive "12 hours from now" would have.
        let sunset = try #require(Sun.sunset(
            on: date("2026-06-21T21:50:00Z"),
            lat: munich.lat, lng: munich.lng, calendar: utc()
        ))
        #expect(minutes(between: sunset, and: date("2026-06-21T19:17:00Z")) < 3)
    }

    @Test("Nonsense coordinates answer nil rather than a number")
    func badInput() {
        #expect(Sun.sunset(on: Date(), lat: .nan, lng: 11.5) == nil)
        #expect(Sun.sunset(on: Date(), lat: 120, lng: 11.5) == nil)
    }
}

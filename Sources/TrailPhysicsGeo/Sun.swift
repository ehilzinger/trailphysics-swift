import Foundation

/// When the sun rises and sets at a point on a day.
///
/// Local arithmetic, no network and no framework: the sunrise equation is a
/// dozen lines of trigonometry, accurate to a minute or two at the
/// latitudes anyone rides at, and the alternative — a service call for a
/// figure that never changes — would make a ride's briefing depend on being
/// online to answer "will I finish in the dark".
///
/// The implementation is the standard NOAA/Wikipedia sunrise equation. It
/// is written out in full rather than compressed because each intermediate
/// has a name in the literature, and a wrong sign in a compressed version
/// is a bug nobody can see.
///
/// **Refraction is included** (the −0.833° zenith): the sun is called set
/// when its upper limb touches the horizon, which is what a rider means by
/// sunset, not when its centre crosses.
///
/// Civil twilight — the roughly half hour after sunset when a rider can
/// still see the road — is offered separately, because "you arrive after
/// sunset" and "you arrive in the dark" are different warnings and only the
/// second is worth alarming anyone about.
public enum Sun {
    /// The sun's altitude, in degrees, at which each event happens.
    private static let sunsetZenith = -0.833
    private static let civilZenith = -6.0

    /// Sunset at this point on the day `date` falls on, in the current
    /// calendar. Nil above the polar circles on days when the sun does not
    /// set at all, which is a real answer and not a failure.
    public static func sunset(
        on date: Date, lat: Double, lng: Double, calendar: Calendar = .current
    ) -> Date? {
        event(.set, altitude: sunsetZenith, on: date, lat: lat, lng: lng, calendar: calendar)
    }

    public static func sunrise(
        on date: Date, lat: Double, lng: Double, calendar: Calendar = .current
    ) -> Date? {
        event(.rise, altitude: sunsetZenith, on: date, lat: lat, lng: lng, calendar: calendar)
    }

    /// The end of civil twilight: the light is gone and a rider needs
    /// lights to be seen by.
    public static func duskEnds(
        on date: Date, lat: Double, lng: Double, calendar: Calendar = .current
    ) -> Date? {
        event(.set, altitude: civilZenith, on: date, lat: lat, lng: lng, calendar: calendar)
    }

    private enum Event {
        case rise, set
    }

    private static func event(
        _ event: Event, altitude: Double, on date: Date,
        lat: Double, lng: Double, calendar: Calendar
    ) -> Date? {
        guard lat.isFinite, lng.isFinite, abs(lat) <= 90 else { return nil }

        // The day is taken from the CALENDAR's own start of day rather than
        // from the instant handed in: a ride arriving at 23:50 asks about
        // that evening's sunset, and an instant a few minutes either side of
        // midnight must not silently answer for the next one.
        let noon = calendar.startOfDay(for: date).addingTimeInterval(12 * 3600)
        let julian = noon.timeIntervalSince1970 / 86_400 + 2_440_587.5

        // Days since J2000, corrected for the leap-second offset the
        // equation is stated with.
        let n = (julian - 2_451_545.0 + 0.0008).rounded()
        // Mean solar noon at this longitude, east positive.
        let meanSolarNoon = n - lng / 360

        let meanAnomaly = (357.5291 + 0.98560028 * meanSolarNoon)
            .truncatingRemainder(dividingBy: 360)
        let m = radians(meanAnomaly)
        // Equation of the centre: the orbit is an ellipse, so the sun runs
        // ahead of and behind its mean position through the year.
        let centre = 1.9148 * sin(m) + 0.0200 * sin(2 * m) + 0.0003 * sin(3 * m)
        let eclipticLongitude = (meanAnomaly + centre + 180 + 102.9372)
            .truncatingRemainder(dividingBy: 360)
        let lambda = radians(eclipticLongitude)

        let transit = 2_451_545.0 + meanSolarNoon
            + 0.0053 * sin(m) - 0.0069 * sin(2 * lambda)

        // The sun's declination today, from the tilt of the earth's axis.
        let sinDeclination = sin(lambda) * sin(radians(23.4397))
        let declination = asin(sinDeclination)

        let phi = radians(lat)
        let cosHourAngle = (sin(radians(altitude)) - sin(phi) * sin(declination))
            / (cos(phi) * cos(declination))
        // Above the polar circles the sun may never reach the altitude
        // asked about: midnight sun, or a day that never gets light.
        guard cosHourAngle >= -1, cosHourAngle <= 1 else { return nil }
        let hourAngle = degrees(acos(cosHourAngle))

        let julianEvent = event == .set
            ? transit + hourAngle / 360
            : transit - hourAngle / 360
        return Date(timeIntervalSince1970: (julianEvent - 2_440_587.5) * 86_400)
    }

    /// Where on the horizon the sun sets, in degrees clockwise from north —
    /// west of 270 in summer, south of it in winter. For a drawn horizon
    /// that puts the sun where the rider will see it go; a degree or two
    /// out (the declination is the one-line approximation, refraction is
    /// left out) is far below what that drawing can show. Nil where the sun
    /// does not set that day.
    public static func setAzimuth(on date: Date, lat: Double, calendar: Calendar = .current) -> Double? {
        guard lat.isFinite, abs(lat) < 90 else { return nil }
        let day = Double(calendar.ordinality(of: .day, in: .year, for: date) ?? 1)
        let declination = 23.44 * sin(radians(360.0 / 365.0 * (284 + day)))
        let cosine = sin(radians(declination)) / cos(radians(lat))
        guard abs(cosine) <= 1 else { return nil }
        return 360 - degrees(acos(cosine))
    }

    /// `position`'s calendar: the equations count the day and hour in UTC.
    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// Where the sun stands at `date` seen from a point: its azimuth in
    /// degrees clockwise from north and its altitude above the horizon
    /// (negative below it). The NOAA solar-position equations at the
    /// instant's own fractional year and true solar time — Hatchure's web
    /// implementation, line for line. No refraction: a sketch of the
    /// day's arc wants the geometry, not the last half degree at the
    /// horizon. Nil for an unusable input.
    public static func position(at date: Date, lat: Double, lng: Double) -> (azimuth: Double, altitude: Double)? {
        guard lat.isFinite, lng.isFinite, abs(lat) <= 90 else { return nil }
        let parts = utc.dateComponents([.hour, .minute, .second], from: date)
        guard let dayOfYear = utc.ordinality(of: .day, in: .year, for: date),
              let daysInYear = utc.range(of: .day, in: .year, for: date)?.count
        else { return nil }
        let hours = Double(parts.hour ?? 0) + Double(parts.minute ?? 0) / 60 + Double(parts.second ?? 0) / 3600
        // The fractional year, in radians.
        let gamma = 2 * .pi / Double(daysInYear) * (Double(dayOfYear) - 1 + (hours - 12) / 24)
        let equationOfTimeMin = 229.18 * (0.000075 + 0.001868 * cos(gamma) - 0.032077 * sin(gamma)
            - 0.014615 * cos(2 * gamma) - 0.040849 * sin(2 * gamma))
        let declination = 0.006918 - 0.399912 * cos(gamma) + 0.070257 * sin(gamma)
            - 0.006758 * cos(2 * gamma) + 0.000907 * sin(2 * gamma)
            - 0.002697 * cos(3 * gamma) + 0.00148 * sin(3 * gamma)
        let trueSolarMin = hours * 60 + equationOfTimeMin + 4 * lng
        let hourAngle = radians(trueSolarMin / 4 - 180)
        let phi = radians(lat)
        let sinAltitude = sin(phi) * sin(declination) + cos(phi) * cos(declination) * cos(hourAngle)
        let altitude = degrees(asin(max(-1, min(1, sinAltitude))))
        let azimuth = (degrees(atan2(sin(hourAngle), cos(hourAngle) * sin(phi) - tan(declination) * cos(phi))) + 180 + 360)
            .truncatingRemainder(dividingBy: 360)
        return (azimuth, altitude)
    }

    private static func radians(_ degrees: Double) -> Double { degrees * .pi / 180 }
    private static func degrees(_ radians: Double) -> Double { radians * 180 / .pi }
}

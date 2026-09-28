# TrailPhysics

Route geometry and pace physics for cycling, hiking and running, in Swift.
It powers the route planning, arrival times and live ride tracking in
[Hatchure](https://hatchure.app) on iPhone and Apple Watch.

- **Rider physics.** Speed comes from power rather than a flat table: air
  drag (with air thinning by altitude), rolling resistance, gravity and
  drivetrain loss, solved per segment and summed as time, plus fatigue on
  long days.
- **Foot pace.** Hiking time from DIN 33466 signpost times, scaled by the
  SAC hiking scale. Running pace follows Minetti's metabolic cost of running
  on a gradient, with a switch to power-hiking on the steepest ground.
- **Elevation.** Ascent filtered against GPS and DEM noise (5 m climb
  filter, spike removal), the steepest sustained incline, incline bands, and
  a profile resampled for drawing.
- **Geometry.** Spherical distance, projecting a point onto a line in a way
  that stays on the right leg where a route doubles back, slicing,
  simplification, bearings, bounding boxes, WKT, sunrise and sunset.
- **Live ride filters.** A rolling speed window with a ceiling against
  projection jumps, off-route hysteresis, barometric ascent, the climbing
  left, and relative bearings.

Pure value types and static functions: no UI, no networking, no global
state. It needs only Foundation and CoreLocation.

## Libraries

| Product | What it holds |
| --- | --- |
| `TrailPhysicsGeo` | `RouteGeometry`, `BoundingBox`, `RouteLineDecimation`, `Sun` |
| `TrailPhysics` | `RiderPhysics`, `FootPace`, `RouteElevation`, `RouteProfile`, `RideSpeedWindow`, `RideOffRoute`, `RideAscent`, `RideOdometer`, `RideProfileMath`, `RideBearing`. Re-exports `TrailPhysicsGeo`. |

Platforms: iOS 18, watchOS 11, macOS 14.

```swift
.package(url: "https://github.com/<owner>/TrailPhysics", from: "0.1.0")
```

## Example

```swift
import CoreLocation
import TrailPhysics

let line: [CLLocationCoordinate2D] = [
    .init(latitude: 46.00, longitude: 7.00),
    .init(latitude: 46.01, longitude: 7.01),
    .init(latitude: 46.02, longitude: 7.02),
]
let elevations: [Double] = [1_200, 1_350, 1_500]

// How fast a 75 kg rider on an 18 kg bike at 180 W covers it.
let rider = RiderPhysics.Rider(riderKg: 75, bikeKg: 18, watts: 180)
let kmh = RiderPhysics.detailedSpeedKmh(rider: rider, latlngs: line, elevations: elevations)

// How long it takes to hike.
let seconds = FootPace.routeSeconds(latlngs: line, elevations: elevations, profile: .hiking)

// Metres climbed, filtered for noise.
let climbed = RouteElevation.ascent(elevations)

// Where a GPS fix sits along the line.
let cumulative = RouteGeometry.cumulativeDistances(line)
let fix = CLLocationCoordinate2D(latitude: 46.012, longitude: 7.011)
let position = RouteGeometry.project(fix, along: line, cumulative: cumulative)

// When the sun sets at the start today.
let sunset = Sun.sunset(on: .now, lat: line[0].latitude, lng: line[0].longitude)
```

## Profiles

`RouteProfile` names seven ways a route can be drawn (`bike`, `gravel`,
`road`, `roadfast`, `hiking`, `trailrun`, `roadrun`) in three sports. The pace
and ride models switch on it. Its raw values are a stored format, so they
never change. Display names and routing-engine ids are left to the app.

## Tests

```bash
swift test
```

The foot-pace vectors in `Tests/TrailPhysicsTests/Fixtures/foot-pace.json`
are shared with Hatchure's JavaScript implementation, so the two stay in
agreement to the second.

## Licence

Copyright 2026 Enzo Hilzinger.

Licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE).

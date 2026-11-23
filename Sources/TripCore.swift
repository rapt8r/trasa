import Foundation

// Foundation only (no CoreLocation/SwiftUI) so Tests/main.swift can check it on any platform.

struct TrackPoint: Codable {
    var t: Date
    var lat: Double
    var lon: Double
    var alt: Double
    var speed: Double?   // m/s; nil when GPS reported it invalid
    var course: Double?  // degrees; nil when invalid
    var hAcc: Double     // horizontal accuracy, metres
    var seg: Int? = nil  // bumped on every resume after a pause; nil = first segment
}

/// Below this speed a segment counts as standing still: GPS jitter at a red light
/// would otherwise add distance. Tune against real drives.
let movingSpeedThreshold = 0.5 // m/s

func haversine(_ a: TrackPoint, _ b: TrackPoint) -> Double {
    let r = 6_371_000.0, rad = Double.pi / 180
    let dLat = (b.lat - a.lat) * rad, dLon = (b.lon - a.lon) * rad
    let h = sin(dLat / 2) * sin(dLat / 2) + cos(a.lat * rad) * cos(b.lat * rad) * sin(dLon / 2) * sin(dLon / 2)
    return 2 * r * asin(min(1, sqrt(h)))
}

struct TripStats {
    var distance = 0.0     // m
    var duration = 0.0     // s
    var movingTime = 0.0   // s
    var maxSpeed = 0.0     // m/s
    var minAlt = 0.0
    var maxAlt = 0.0
    var avgSpeed: Double { duration > 0 ? distance / duration : 0 }
    var avgMovingSpeed: Double { movingTime > 0 ? distance / movingTime : 0 }

    init(_ p: [TrackPoint]) {
        guard !p.isEmpty else { return }
        minAlt = p.map(\.alt).min() ?? 0
        maxAlt = p.map(\.alt).max() ?? 0
        maxSpeed = p.compactMap(\.speed).max() ?? 0
        for (a, b) in zip(p, p.dropFirst()) {
            let d = haversine(a, b), dt = b.t.timeIntervalSince(a.t)
            // A pause sits between two segments: it adds neither distance nor time.
            guard dt > 0, a.seg == b.seg else { continue }
            duration += dt
            if (b.speed ?? d / dt) > movingSpeedThreshold {
                distance += d
                movingTime += dt
            }
        }
    }
}

struct Trip: Identifiable {
    let url: URL
    let points: [TrackPoint]
    let stats: TripStats
    var id: URL { url }
    var start: Date { points.first?.t ?? .distantPast }

    init(url: URL, points: [TrackPoint]) {
        self.url = url
        self.points = points
        self.stats = TripStats(points)
    }
}

/// One JSON object per line. A line cut off by a crash mid-write is skipped, the rest survives.
func parseJSONL(_ data: Data) -> [TrackPoint] {
    let decoder = JSONDecoder()
    return data.split(separator: UInt8(ascii: "\n")).compactMap { try? decoder.decode(TrackPoint.self, from: Data($0)) }
}

func gpx(_ points: [TrackPoint]) -> String {
    let iso = ISO8601DateFormatter()
    var s = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
    s += "<gpx version=\"1.1\" creator=\"Journey\" xmlns=\"http://www.topografix.com/GPX/1/1\">\n<trk><trkseg>\n"
    for p in points {
        s += "<trkpt lat=\"\(p.lat)\" lon=\"\(p.lon)\"><ele>\(p.alt)</ele><time>\(iso.string(from: p.t))</time>"
        if let v = p.speed { s += "<extensions><speed>\(v)</speed></extensions>" }
        s += "</trkpt>\n"
    }
    return s + "</trkseg></trk>\n</gpx>\n"
}

/// Consecutive slices of a track for a speed-coloured map line.
/// `fraction` is the slice's average speed relative to the trip's top speed (0...1).
struct SpeedChunk: Identifiable {
    let id: Int
    let range: ClosedRange<Int>
    let fraction: Double
}

func speedChunks(_ p: [TrackPoint], maxChunks: Int = 60) -> [SpeedChunk] {
    guard p.count > 1, maxChunks > 0 else { return [] }
    let top = p.compactMap(\.speed).max() ?? 0
    let step = max(1, (p.count - 1 + maxChunks - 1) / maxChunks)
    var chunks: [SpeedChunk] = []
    var start = 0
    while start < p.count - 1 {
        let end = min(start + step, p.count - 1)
        let v = p[start...end].compactMap(\.speed)
        let avg = v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count)
        chunks.append(SpeedChunk(id: chunks.count, range: start...end, fraction: top > 0 ? min(1, avg / top) : 0))
        start = end
    }
    return chunks
}

func csv(_ points: [TrackPoint]) -> String {
    let iso = ISO8601DateFormatter()
    var s = "time,lat,lon,alt_m,speed_kmh,course_deg,accuracy_m\n"
    for p in points {
        let v = p.speed.map { String(format: "%.1f", $0 * 3.6) } ?? ""
        let c = p.course.map { String(format: "%.0f", $0) } ?? ""
        let alt = String(format: "%.1f", p.alt), acc = String(format: "%.0f", p.hAcc)
        s += "\(iso.string(from: p.t)),\(p.lat),\(p.lon),\(alt),\(v),\(c),\(acc)\n"
    }
    return s
}

/// 0 = N, 90 = E; any finite degree value is accepted.
func compass(_ degrees: Double) -> String {
    guard degrees.isFinite else { return "–" }
    let names = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
    let i = Int(((degrees.truncatingRemainder(dividingBy: 360) + 360 + 22.5) / 45).rounded(.down)) % 8
    return names[i]
}

func formatDuration(_ seconds: Double) -> String {
    let s = Int(max(0, seconds))
    return String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
}

/// "12 min", "1 h 05 min": for lists, where the second-precise clock is noise.
func formatShortDuration(_ seconds: Double) -> String {
    let minutes = Int((max(0, seconds) / 60).rounded())
    return minutes < 60 ? "\(minutes) min" : String(format: "%d h %02d min", minutes / 60, minutes % 60)
}

/// "1 przejazd", "2 przejazdy", "5 przejazdów", "22 przejazdy".
func tripsLabel(_ n: Int) -> String {
    let word: String
    if n == 1 {
        word = "przejazd"
    } else if (2...4).contains(n % 10) && !(12...14).contains(n % 100) {
        word = "przejazdy"
    } else {
        word = "przejazdów"
    }
    return "\(n) \(word)"
}

func formatKm(_ metres: Double, locale: Locale = .current) -> String { String(format: "%.2f km", locale: locale, metres / 1000) }
func formatKmh(_ mps: Double) -> String { String(format: "%.0f km/h", mps * 3.6) }

// MARK: Follow camera (pure logic; the view turns CameraSpec into a MapCamera)

// All of these need tuning on a real drive.
let cameraEnterSpeed = 15.0 / 3.6     // m/s; at or above: behind-the-marker view
let cameraExitSpeed = 8.0 / 3.6       // m/s; below this for cameraExitDwell: top-down view
let cameraExitDwell = 4.0             // s; stops stop-and-go traffic from flipping the view
let cameraHeadingMinSpeed = 1.5       // m/s; below this GPS course is noise, the last heading is held
let cameraBlendTime = 4.0             // s for the full top-down <-> behind-the-marker change
let cameraDrivingPitch = 60.0         // degrees from straight down; much more and the horizon cuts across the top of the screen
let cameraHeadingSmoothing = 0.7      // s; how gently the map turns to follow the car
let cameraDrivingDistance = 260.0     // m from camera to the point it looks at, at low speed
let cameraDistancePerSpeed = 5.0      // extra metres of distance per m/s, so the view opens up when fast
let cameraLookAheadFraction = 0.25    // the camera aims this share of its distance ahead of the car; puts the marker low on screen
let cameraOverheadDistance = 650.0    // m
let cameraNoticeLift = 0.2            // share of the look-ahead given up while a notice sits above the sheet, which raises the marker clear of it

/// One step of a critically damped spring: starts gently, arrives gently, never overshoots.
/// `smoothTime` is roughly how long it takes to get there.
func springStep(_ value: inout Double, _ velocity: inout Double, to target: Double, smoothTime: Double, dt: Double) {
    guard dt > 0 else { return }
    let omega = 2 / max(0.0001, smoothTime)
    let decay = exp(-omega * dt)
    let change = value - target
    let temp = (velocity + omega * change) * dt
    velocity = (velocity - omega * temp) * decay
    value = target + (change + temp) * decay
}

/// Signed shortest turn from one compass direction to another, in -180...180 degrees.
func shortestTurn(from: Double, to: Double) -> Double {
    (to - from + 540).truncatingRemainder(dividingBy: 360) - 180
}

func wrapDegrees(_ d: Double) -> Double {
    let r = d.truncatingRemainder(dividingBy: 360)
    return r < 0 ? r + 360 : r
}

struct CameraSpec {
    var lat: Double
    var lon: Double
    var distance: Double
    var heading: Double
    var pitch: Double
}

/// Point reached from (lat, lon) after `distance` metres along `bearing` degrees.
func destination(lat: Double, lon: Double, bearing: Double, distance: Double) -> (lat: Double, lon: Double) {
    let rad = Double.pi / 180, d = distance / 6_371_000.0
    let p1 = lat * rad, l1 = lon * rad, b = bearing * rad
    let p2 = asin(sin(p1) * cos(d) + cos(p1) * sin(d) * cos(b))
    let l2 = l1 + atan2(sin(b) * sin(d) * cos(p1), cos(d) - sin(p1) * sin(p2))
    return (p2 / rad, l2 / rad)
}

struct CameraState {
    private(set) var driving = false
    /// Where the map is turned right now; eases towards `targetHeading`.
    private(set) var heading = 0.0
    /// The car's last trustworthy course.
    private(set) var targetHeading = 0.0
    private(set) var blend = 0.0 // 0 = top-down, 1 = behind the marker
    private var headingVelocity = 0.0
    private var hasHeading = false
    private var slowSince: Date?
    private var lastT: Date?

    mutating func update(_ p: TrackPoint) {
        let v = p.speed ?? 0
        // Time-based, so it behaves the same at 1 fix/s and at 60 frames/s.
        let dt = lastT.map { min(2, max(0, p.t.timeIntervalSince($0))) } ?? 0
        lastT = p.t

        if let c = p.course, v >= cameraHeadingMinSpeed {
            targetHeading = c
            if !hasHeading {
                heading = c // first course: face it at once instead of spinning round from north
                hasHeading = true
            }
        }
        if hasHeading {
            var value = heading
            springStep(&value, &headingVelocity, to: heading + shortestTurn(from: heading, to: targetHeading),
                       smoothTime: cameraHeadingSmoothing, dt: dt)
            heading = wrapDegrees(value)
        }

        if v >= cameraEnterSpeed {
            driving = true
            slowSince = nil
        } else if v < cameraExitSpeed {
            if driving {
                let since = slowSince ?? p.t
                slowSince = since
                if p.t.timeIntervalSince(since) >= cameraExitDwell {
                    driving = false
                    slowSince = nil
                }
            }
        } else {
            slowSince = nil
        }
        let step = dt / cameraBlendTime
        blend = driving ? min(1, blend + step) : max(0, blend - step)
    }

    /// - lift: 0...1, how much room to leave under the marker for a notice above the sheet.
    func spec(for p: TrackPoint, lift: Double = 0) -> CameraSpec {
        let eased = blend * blend * (3 - 2 * blend) // ease in, ease out
        let drivingDistance = cameraDrivingDistance + (p.speed ?? 0) * cameraDistancePerSpeed
        let distance = cameraOverheadDistance + (drivingDistance - cameraOverheadDistance) * eased
        let aim = eased > 0
            ? destination(lat: p.lat, lon: p.lon, bearing: heading,
                          distance: distance * cameraLookAheadFraction * (1 - cameraNoticeLift * min(1, max(0, lift))) * eased)
            : (lat: p.lat, lon: p.lon)
        return CameraSpec(lat: aim.lat,
                          lon: aim.lon,
                          distance: distance,
                          heading: heading,
                          pitch: cameraDrivingPitch * eased)
    }
}

// MARK: Replay of a recorded trip

let replayMaxGap = 5.0 // s; longer gaps (pauses, lost GPS) are jumped over instead of waited out

/// Replay clock after one tick: advances by `step`, jumping straight to the next fix over a long gap.
func nextReplayClock(_ p: [TrackPoint], index: Int, clock: Date, step: Double) -> Date {
    if index + 1 < p.count, p[index + 1].t.timeIntervalSince(p[index].t) > replayMaxGap || p[index + 1].seg != p[index].seg {
        return p[index + 1].t
    }
    return clock.addingTimeInterval(step)
}

// MARK: Per-frame motion between fixes

let motionSmoothing = 0.3       // s; how quickly the shown position closes in on the predicted one
let motionTurnSmoothing = 0.35  // s; the same for the direction the marker points
let motionMaxTurnRate = 60.0    // deg/s; anything faster is the phone being handled, not the car turning
let motionGpsTurnShare = 0.5    // without a gyroscope: how much of the turn seen between two fixes is assumed to continue
let motionMaxPrediction = 1.5   // s; without a new fix the marker coasts this long, then stops
let motionMinSpeed = 0.5        // m/s; slower than this the marker is not moved along the course
let motionSnapDistance = 200.0  // m; a fix further away than this is shown at once, without a glide

/// GPS gives one fix per second. Between fixes the car keeps its speed and goes on turning at the
/// rate the gyroscope reports (or, without one, part of the rate seen between the last two fixes),
/// so the shown position is predicted from the last fix and eased towards that prediction every frame.
struct MotionSmoother {
    private(set) var point: TrackPoint?
    /// Where the car is assumed to be heading right now: the fix's course carried on by the turn rate.
    private(set) var predictedCourse: Double?
    private var fix: TrackPoint?
    private var predicted = (lat: 0.0, lon: 0.0)
    private var gpsTurnRate = 0.0 // deg/s
    private var age = 0.0
    private var latVelocity = 0.0
    private var lonVelocity = 0.0
    private var courseVelocity = 0.0

    mutating func feed(_ p: TrackPoint) {
        gpsTurnRate = 0
        if let last = fix, let c0 = last.course, let c1 = p.course {
            let dt = p.t.timeIntervalSince(last.t)
            if dt > 0, dt <= 3 { gpsTurnRate = shortestTurn(from: c0, to: c1) / dt * motionGpsTurnShare }
        }
        if let shown = point, haversine(shown, p) <= motionSnapDistance {
            // keep gliding from where the marker is
        } else {
            point = p
            latVelocity = 0
            lonVelocity = 0
            courseVelocity = 0
        }
        fix = p
        predicted = (p.lat, p.lon)
        predictedCourse = p.course
        age = 0
    }

    /// Advances by `dt` seconds of trip time and returns the position to show.
    /// - yawRate: turn rate from the gyroscope, degrees per second clockwise; nil when there is none.
    /// - compass: compass heading in degrees; only used while the car stands still.
    mutating func step(_ dt: Double, yawRate: Double? = nil, compass: Double? = nil) -> TrackPoint? {
        guard let fix, var shown = point, dt > 0 else { return point }
        let v = fix.speed ?? 0
        let moving = v >= motionMinSpeed
        // Without a new fix the prediction runs for motionMaxPrediction seconds, then holds.
        let run = max(0, min(dt, motionMaxPrediction - age))
        age = min(age + dt, motionMaxPrediction)
        if moving, run > 0, let course = predictedCourse {
            let rate = max(-motionMaxTurnRate, min(motionMaxTurnRate, yawRate ?? gpsTurnRate))
            let next = wrapDegrees(course + rate * run)
            predictedCourse = next
            predicted = destination(lat: predicted.lat, lon: predicted.lon, bearing: next, distance: v * run)
        }
        // Springs, not a straight blend: the marker picks up and settles gently when a fix corrects it.
        springStep(&shown.lat, &latVelocity, to: predicted.lat, smoothTime: motionSmoothing, dt: dt)
        springStep(&shown.lon, &lonVelocity, to: predicted.lon, smoothTime: motionSmoothing, dt: dt)
        let k = 1 - exp(-dt / motionSmoothing)
        shown.alt += (fix.alt - shown.alt) * k
        if let speed = fix.speed {
            let from = shown.speed ?? speed
            shown.speed = from + (speed - from) * k
        } else {
            shown.speed = nil
        }
        // Standing still, GPS has no course: the compass says which way the car points.
        if let target = moving ? predictedCourse : (compass ?? predictedCourse) {
            let from = shown.course ?? target
            var value = from
            springStep(&value, &courseVelocity, to: from + shortestTurn(from: from, to: target),
                       smoothTime: motionTurnSmoothing, dt: dt)
            shown.course = wrapDegrees(value)
        }
        shown.hAcc = fix.hAcc
        shown.seg = fix.seg
        shown.t = fix.t.addingTimeInterval(age)
        point = shown
        return shown
    }
}

// MARK: Fuel cost (estimate from distance until the car reports real consumption)

/// Litres used over `distance` metres at `per100` l/100 km.
func fuelUsed(distance: Double, per100: Double) -> Double { max(0, distance) / 100_000 * max(0, per100) }
func formatLitres(_ litres: Double, locale: Locale = .current) -> String { String(format: "%.1f l", locale: locale, litres) }
func formatCost(_ zloty: Double, locale: Locale = .current) -> String { String(format: "%.2f zł", locale: locale, max(0, zloty)) }

// MARK: Statistics per week / month

struct PeriodSummary: Identifiable {
    let start: Date
    var count = 0
    var distance = 0.0
    var duration = 0.0
    var id: Date { start }
}

/// Trips grouped by calendar `unit` (.month, .weekOfYear), newest period first.
func summarize(_ trips: [Trip], by unit: Calendar.Component, calendar: Calendar = .current) -> [PeriodSummary] {
    var periods: [Date: PeriodSummary] = [:]
    for trip in trips {
        guard let start = calendar.dateInterval(of: unit, for: trip.start)?.start else { continue }
        var s = periods[start] ?? PeriodSummary(start: start)
        s.count += 1
        s.distance += trip.stats.distance
        s.duration += trip.stats.duration
        periods[start] = s
    }
    return periods.values.sorted { $0.start > $1.start }
}

// MARK: Roads and speed limits (OpenStreetMap data, fetched per tile by RoadInfo)

let roadTileSize = 0.03          // degrees; about 3.3 km north-south, 2 km east-west in Poland
let roadMatchMaxDistance = 30.0  // m from the road centre line
let roadMatchMaxAngle = 45.0     // degrees between the course and the road direction

struct RoadWay {
    let highway: String
    let limit: Int?   // km/h
    let name: String?
    let lats: [Double]
    let lons: [Double]
}

struct RoadTile: Hashable {
    let x: Int
    let y: Int

    init(lat: Double, lon: Double) {
        x = Int((lon / roadTileSize).rounded(.down))
        y = Int((lat / roadTileSize).rounded(.down))
    }

    var south: Double { Double(y) * roadTileSize }
    var north: Double { Double(y + 1) * roadTileSize }
    var west: Double { Double(x) * roadTileSize }
    var east: Double { Double(x + 1) * roadTileSize }
    var name: String { "\(x)_\(y)" }
}

func overpassQuery(_ tile: RoadTile) -> String {
    let roads = "motorway|trunk|primary|secondary|tertiary|unclassified|residential|living_street|motorway_link|trunk_link|primary_link|secondary_link|tertiary_link"
    let bbox = String(format: "%.4f,%.4f,%.4f,%.4f", tile.south, tile.west, tile.north, tile.east)
    return "[out:json][timeout:25];way[highway~\"^(\(roads))$\"](\(bbox));out tags geom;"
}

/// Limit in km/h from OSM tags, or nil when the map does not say. Only explicit values are trusted:
/// guessing "50 in town, 90 outside" from the road class alone would show wrong signs.
// ponytail: the implicit values are Polish (motorway 140, living street 20); add a country table if used abroad.
func parseSpeedLimit(maxspeed: String?, highway: String) -> Int? {
    if let raw = maxspeed?.trimmingCharacters(in: .whitespaces) {
        if let v = Int(raw) { return (5...150).contains(v) ? v : nil }
        switch raw {
        case "PL:urban": return 50
        case "PL:rural": return 90
        case "PL:motorway": return 140
        case "PL:living_street": return 20
        default: return nil
        }
    }
    switch highway {
    case "motorway": return 140
    case "living_street": return 20
    default: return nil
    }
}

private struct OverpassResponse: Decodable {
    struct Node: Decodable {
        let lat: Double
        let lon: Double
    }
    struct Element: Decodable {
        let tags: [String: String]?
        let geometry: [Node?]?
    }
    let elements: [Element]
}

/// Roads from an Overpass "out tags geom" JSON response; nil when the data is not such a response.
func parseWays(_ data: Data) -> [RoadWay]? {
    guard let response = try? JSONDecoder().decode(OverpassResponse.self, from: data) else { return nil }
    return response.elements.compactMap { e in
        guard let highway = e.tags?["highway"], let nodes = e.geometry?.compactMap({ $0 }), nodes.count > 1 else { return nil }
        return RoadWay(highway: highway,
                       limit: parseSpeedLimit(maxspeed: e.tags?["maxspeed"], highway: highway),
                       name: e.tags?["name"],
                       lats: nodes.map(\.lat),
                       lons: nodes.map(\.lon))
    }
}

struct RoadMatch {
    let way: RoadWay
    /// Nearest point on the road's centre line.
    let lat: Double
    let lon: Double
    /// Direction of the road there, turned to agree with the course when one is given.
    let bearing: Double
    let distance: Double // m from the position to that point
}

/// The road the car is most likely on: nearest centre line within `roadMatchMaxDistance`
/// that runs along the course (either direction). Without a course, simply the nearest.
func matchRoad(_ ways: [RoadWay], lat: Double, lon: Double, course: Double?) -> RoadMatch? {
    let mPerLat = 111_320.0, mPerLon = 111_320.0 * cos(lat * Double.pi / 180)
    var best: RoadMatch?
    var bestDistance = roadMatchMaxDistance
    for way in ways where way.lats.count > 1 {
        for i in 0..<(way.lats.count - 1) {
            let ax = (way.lons[i] - lon) * mPerLon, ay = (way.lats[i] - lat) * mPerLat
            let bx = (way.lons[i + 1] - lon) * mPerLon, by = (way.lats[i + 1] - lat) * mPerLat
            let dx = bx - ax, dy = by - ay
            let len2 = dx * dx + dy * dy
            let t = len2 > 0 ? max(0, min(1, -(ax * dx + ay * dy) / len2)) : 0
            let px = ax + t * dx, py = ay + t * dy
            let distance = (px * px + py * py).squareRoot()
            guard distance < bestDistance else { continue }
            var bearing = len2 > 0 ? wrapDegrees(atan2(dx, dy) * 180 / Double.pi) : (course ?? 0)
            if let course, len2 > 0 {
                var turn = abs(shortestTurn(from: course, to: bearing))
                if turn > 90 {
                    bearing = wrapDegrees(bearing + 180) // the road is drawn the other way round
                    turn = 180 - turn
                }
                guard turn <= roadMatchMaxAngle else { continue }
            }
            bestDistance = distance
            best = RoadMatch(way: way, lat: lat + py / mPerLat, lon: lon + px / mPerLon, bearing: bearing, distance: distance)
        }
    }
    return best
}

// MARK: What the screen should react to

let speedLimitTolerance = 3.0 // km/h over the limit before the speed is flagged; GPS speed wobbles by a little

func isOverLimit(speed: Double?, limit: Int) -> Bool {
    guard let speed else { return false }
    return speed * 3.6 > Double(limit) + speedLimitTolerance
}

enum GPSStatus {
    case good
    case weak       // a fix, but a rough one
    case searching  // no recent fix
}

let gpsStaleAfter = 5.0     // s without a fix
let gpsWeakAccuracy = 30.0  // m

func gpsStatus(fix: TrackPoint?, now: Date) -> GPSStatus {
    guard let fix, now.timeIntervalSince(fix.t) <= gpsStaleAfter else { return .searching }
    return fix.hAcc > gpsWeakAccuracy ? .weak : .good
}

let nightSunElevation = -4.0 // degrees; the sun this far below the horizon counts as night (dusk is already dark on the road)

/// Height of the sun above the horizon in degrees, good to about a degree (low-precision almanac formulas).
func solarElevation(lat: Double, lon: Double, date: Date) -> Double {
    let rad = Double.pi / 180
    let n = (date.timeIntervalSince1970 - 946_728_000) / 86_400 // days since 2000-01-01 12:00 UTC
    let meanLongitude = 280.460 + 0.9856474 * n
    let anomaly = (357.528 + 0.9856003 * n) * rad
    let ecliptic = (meanLongitude + 1.915 * sin(anomaly) + 0.020 * sin(2 * anomaly)) * rad
    let obliquity = (23.439 - 0.0000004 * n) * rad
    let declination = asin(sin(obliquity) * sin(ecliptic))
    let rightAscension = atan2(cos(obliquity) * sin(ecliptic), cos(ecliptic))
    let siderealDegrees = (18.697374558 + 24.06570982441908 * n) * 15 + lon
    let hourAngle = siderealDegrees * rad - rightAscension
    let phi = lat * rad
    return asin(sin(phi) * sin(declination) + cos(phi) * cos(declination) * cos(hourAngle)) / rad
}

func isNight(lat: Double, lon: Double, date: Date) -> Bool {
    solarElevation(lat: lat, lon: lon, date: date) < nightSunElevation
}

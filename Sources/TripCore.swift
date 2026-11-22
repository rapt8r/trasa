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
    s += "<gpx version=\"1.1\" creator=\"Trasa\" xmlns=\"http://www.topografix.com/GPX/1/1\">\n<trk><trkseg>\n"
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

func formatKm(_ metres: Double) -> String { String(format: "%.2f km", metres / 1000) }
func formatKmh(_ mps: Double) -> String { String(format: "%.0f km/h", mps * 3.6) }

// MARK: Follow camera (pure logic; the view turns CameraSpec into a MapCamera)

// All of these need tuning on a real drive.
let cameraEnterSpeed = 15.0 / 3.6     // m/s; at or above: behind-the-marker view
let cameraExitSpeed = 8.0 / 3.6       // m/s; below this for cameraExitDwell: top-down view
let cameraExitDwell = 4.0             // s; stops stop-and-go traffic from flipping the view
let cameraHeadingMinSpeed = 1.5       // m/s; below this GPS course is noise, the last heading is held
let cameraBlendTime = 4.0             // s for the full top-down <-> behind-the-marker change
let cameraDrivingPitch = 68.0         // degrees from straight down; MapKit flattens it if the camera is far away
let cameraDrivingDistance = 260.0     // m from camera to the point it looks at, at low speed
let cameraDistancePerSpeed = 5.0      // extra metres of distance per m/s, so the view opens up when fast
let cameraLookAheadFraction = 0.25    // the camera aims this share of its distance ahead of the car; puts the marker low on screen
let cameraOverheadDistance = 650.0    // m

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
    private(set) var heading = 0.0
    private(set) var blend = 0.0 // 0 = top-down, 1 = behind the marker; moves a step per fix
    private var slowSince: Date?
    private var lastT: Date?

    mutating func update(_ p: TrackPoint) {
        let v = p.speed ?? 0
        if let c = p.course, v >= cameraHeadingMinSpeed { heading = c }
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
        // Time-based, so it behaves the same at 1 fix/s (GPS) and at 10 samples/s (replay).
        let dt = lastT.map { min(2, max(0, p.t.timeIntervalSince($0))) } ?? 0
        lastT = p.t
        let step = dt / cameraBlendTime
        blend = driving ? min(1, blend + step) : max(0, blend - step)
    }

    func spec(for p: TrackPoint) -> CameraSpec {
        let drivingDistance = cameraDrivingDistance + (p.speed ?? 0) * cameraDistancePerSpeed
        let distance = cameraOverheadDistance + (drivingDistance - cameraOverheadDistance) * blend
        let aim = blend > 0
            ? destination(lat: p.lat, lon: p.lon, bearing: heading, distance: distance * cameraLookAheadFraction * blend)
            : (lat: p.lat, lon: p.lon)
        return CameraSpec(lat: aim.lat,
                          lon: aim.lon,
                          distance: distance,
                          heading: heading,
                          pitch: cameraDrivingPitch * blend)
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

let motionSmoothing = 0.35      // s; how quickly the shown position closes in on the predicted one
let motionMaxPrediction = 1.5   // s; without a new fix the marker coasts this long, then stops
let motionMinSpeed = 0.5        // m/s; slower than this the marker is not moved along the course
let motionSnapDistance = 200.0  // m; a fix further away than this is shown at once, without a glide

/// GPS gives one fix per second. Between fixes the car keeps its speed and course, so the shown
/// position is predicted from the last fix and eased towards that prediction every frame.
struct MotionSmoother {
    private(set) var point: TrackPoint?
    private var fix: TrackPoint?
    private var age = 0.0

    mutating func feed(_ p: TrackPoint) {
        if let shown = point, haversine(shown, p) <= motionSnapDistance {
            // keep gliding from where the marker is
        } else {
            point = p
        }
        fix = p
        age = 0
    }

    /// Advances by `dt` seconds of trip time and returns the position to show.
    mutating func step(_ dt: Double) -> TrackPoint? {
        guard let fix, var shown = point, dt > 0 else { return point }
        age = min(age + dt, motionMaxPrediction)
        let v = fix.speed ?? 0
        var target = (lat: fix.lat, lon: fix.lon)
        if let course = fix.course, v >= motionMinSpeed {
            target = destination(lat: fix.lat, lon: fix.lon, bearing: course, distance: v * age)
        }
        let k = 1 - exp(-dt / motionSmoothing)
        shown.lat += (target.lat - shown.lat) * k
        shown.lon += (target.lon - shown.lon) * k
        shown.alt += (fix.alt - shown.alt) * k
        if let speed = fix.speed {
            let from = shown.speed ?? speed
            shown.speed = from + (speed - from) * k
        } else {
            shown.speed = nil
        }
        if let course = fix.course {
            let from = shown.course ?? course
            let turn = (course - from + 540).truncatingRemainder(dividingBy: 360) - 180 // shortest way round
            shown.course = (from + turn * k + 360).truncatingRemainder(dividingBy: 360)
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
func formatLitres(_ litres: Double) -> String { String(format: "%.1f l", litres) }
func formatCost(_ zloty: Double) -> String { String(format: "%.2f zł", max(0, zloty)) }

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

/// The road the car is most likely on: nearest centre line within `roadMatchMaxDistance`
/// that runs along the course (either direction). Without a course, simply the nearest.
func matchRoad(_ ways: [RoadWay], lat: Double, lon: Double, course: Double?) -> RoadWay? {
    let mPerLat = 111_320.0, mPerLon = 111_320.0 * cos(lat * Double.pi / 180)
    var best: RoadWay?
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
            if let course, len2 > 0 {
                let bearing = atan2(dx, dy) * 180 / Double.pi
                var diff = abs((bearing - course).truncatingRemainder(dividingBy: 180))
                if diff > 90 { diff = 180 - diff }
                guard diff <= roadMatchMaxAngle else { continue }
            }
            bestDistance = distance
            best = way
        }
    }
    return best
}

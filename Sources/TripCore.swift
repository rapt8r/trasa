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
let cameraBlendStep = 0.25            // share of the view change done per GPS fix (4 fixes = full change)
let cameraDrivingPitch = 60.0         // degrees
let cameraDrivingDistance = 450.0     // m from camera to the point it looks at, at low speed
let cameraDistancePerSpeed = 10.0     // extra metres of distance per m/s, so the view opens up when fast
let cameraLookAhead = 120.0           // m ahead of the car the camera aims at; puts the marker low on screen
let cameraOverheadDistance = 900.0    // m

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
        blend = driving ? min(1, blend + cameraBlendStep) : max(0, blend - cameraBlendStep)
    }

    func spec(for p: TrackPoint) -> CameraSpec {
        let drivingDistance = cameraDrivingDistance + (p.speed ?? 0) * cameraDistancePerSpeed
        let aim = destination(lat: p.lat, lon: p.lon, bearing: heading, distance: cameraLookAhead * blend)
        return CameraSpec(lat: aim.lat,
                          lon: aim.lon,
                          distance: cameraOverheadDistance + (drivingDistance - cameraOverheadDistance) * blend,
                          heading: heading,
                          pitch: cameraDrivingPitch * blend)
    }
}

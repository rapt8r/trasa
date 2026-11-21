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
        guard let first = p.first, let last = p.last else { return }
        duration = last.t.timeIntervalSince(first.t)
        minAlt = p.map(\.alt).min() ?? 0
        maxAlt = p.map(\.alt).max() ?? 0
        maxSpeed = p.compactMap(\.speed).max() ?? 0
        for (a, b) in zip(p, p.dropFirst()) {
            let d = haversine(a, b), dt = b.t.timeIntervalSince(a.t)
            guard dt > 0 else { continue }
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

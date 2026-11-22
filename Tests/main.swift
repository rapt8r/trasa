import Foundation

// Self-check for TripCore. Run: swiftc -swift-version 5 Sources/TripCore.swift Tests/main.swift -o check && ./check

func pt(_ sec: Double, _ lat: Double, _ lon: Double, speed: Double?) -> TrackPoint {
    TrackPoint(t: Date(timeIntervalSince1970: sec), lat: lat, lon: lon, alt: 100 + sec, speed: speed, course: nil, hAcc: 5)
}

// 0.001 deg of latitude is ~111.19 m
let moving = [pt(0, 52.0, 21.0, speed: 20), pt(5, 52.001, 21.0, speed: 22), pt(10, 52.002, 21.0, speed: 21)]
var s = TripStats(moving)
precondition(abs(s.distance - 222.4) < 1, "distance \(s.distance)")
precondition(s.duration == 10 && s.movingTime == 10)
precondition(s.maxSpeed == 22 && s.minAlt == 100 && s.maxAlt == 110)
precondition(abs(s.avgSpeed - 22.24) < 0.1)

// Standing still: jitter must not add distance, but the clock keeps running
let parked = moving + [pt(20, 52.00201, 21.0, speed: 0), pt(30, 52.002, 21.0, speed: 0.1)]
s = TripStats(parked)
precondition(abs(s.distance - 222.4) < 1 && s.duration == 30 && s.movingTime == 10)

// No speed from GPS: falls back to distance/time
s = TripStats([pt(0, 52.0, 21.0, speed: nil), pt(5, 52.001, 21.0, speed: nil)])
precondition(abs(s.distance - 111.2) < 1)

precondition(TripStats([]).distance == 0 && TripStats([moving[0]]).avgSpeed == 0)

// JSONL round trip, with the last line cut off as after a crash
let enc = JSONEncoder()
var data = Data()
for p in moving { data.append(try! enc.encode(p)); data.append(0x0A) }
data.append(Data("{\"t\":12,\"la".utf8))
let back = parseJSONL(data)
precondition(back.count == 3 && back[1].lat == 52.001 && back[2].t == moving[2].t && back[0].course == nil)

let g = gpx(moving)
precondition(g.contains("<trkpt lat=\"52.001\" lon=\"21.0\">") && g.contains("<time>1970-01-01T00:00:05Z</time>"))
precondition(g.components(separatedBy: "<trkpt").count == 4)

precondition(formatDuration(3725) == "1:02:05" && formatKm(12345) == "12.35 km" && formatKmh(10) == "36 km/h")
precondition(compass(0) == "N" && compass(359) == "N" && compass(45) == "NE" && compass(180) == "S")
precondition(compass(271) == "W" && compass(-90) == "W" && compass(.nan) == "–")
let rows = csv(moving).split(separator: "\n")
precondition(rows.count == 4 && rows[0].hasPrefix("time,lat"), "csv rows")
precondition(rows[2] == "1970-01-01T00:00:05Z,52.001,21.0,105.0,79.2,,5", "csv row: \(rows[2])")
// Pause: the gap between segments adds neither distance nor time
var resumed = pt(1000, 53.0, 22.0, speed: 20); resumed.seg = 1
var resumed2 = pt(1005, 53.001, 22.0, speed: 20); resumed2.seg = 1
s = TripStats(moving + [resumed, resumed2])
precondition(abs(s.distance - 333.6) < 1.5 && s.duration == 15 && s.movingTime == 15, "pause \(s.distance) \(s.duration)")
let old = parseJSONL(Data("{\"t\":1,\"lat\":1,\"lon\":2,\"alt\":3,\"hAcc\":4}\n".utf8))
precondition(old.count == 1 && old[0].seg == nil, "old files without seg still load")

let ch = speedChunks(moving)
precondition(ch.count == 2 && ch[0].range == 0...1 && ch[1].range == 1...2 && ch[1].fraction <= 1 && ch[0].fraction > 0.9)
let many = (0..<1000).map { pt(Double($0), 52.0 + Double($0) * 0.0001, 21.0, speed: Double($0 % 30)) }
let mc = speedChunks(many)
precondition(mc.count <= 60 && mc.first!.range.lowerBound == 0 && mc.last!.range.upperBound == 999)
precondition(zip(mc, mc.dropFirst()).allSatisfy { $0.range.upperBound == $1.range.lowerBound })
precondition(speedChunks([]).isEmpty && speedChunks([moving[0]]).isEmpty)
// Follow camera
let dest = destination(lat: 52, lon: 21, bearing: 0, distance: 111.19)
precondition(abs(dest.lat - 52.001) < 1e-5 && abs(dest.lon - 21) < 1e-9, "destination north")
precondition(destination(lat: 52, lon: 21, bearing: 90, distance: 500).lon > 21.007, "destination east")

func fix(_ sec: Double, _ speed: Double?, _ course: Double?) -> TrackPoint {
    TrackPoint(t: Date(timeIntervalSince1970: sec), lat: 52, lon: 21, alt: 0, speed: speed, course: course, hAcc: 5)
}
var cs = CameraState()
cs.update(fix(0, 0, nil))
precondition(!cs.driving && cs.blend == 0)
cs.update(fix(1, 3, 90))
precondition(!cs.driving && cs.heading == 90, "between thresholds: still top-down, heading follows")
cs.update(fix(2, 10, 100))
precondition(cs.driving && cs.heading == 100 && cs.blend == 0.25, "enters driving, view changes gradually")
for i in 3..<8 { cs.update(fix(Double(i), 10, 100)) }
precondition(cs.blend == 1)
var spec = cs.spec(for: fix(8, 10, 100))
precondition(spec.pitch == cameraDrivingPitch && spec.heading == 100 && spec.lon > 21)
precondition(abs(spec.distance - (cameraDrivingDistance + 10 * cameraDistancePerSpeed)) < 1e-6)

cs.update(fix(10, 0.2, 250))
precondition(cs.driving && cs.heading == 100, "course at near-zero speed is ignored")
cs.update(fix(12, 0.2, nil))
precondition(cs.driving, "short slow-down keeps the driving view")
cs.update(fix(13, 12, 100))
cs.update(fix(14, 0, nil))
cs.update(fix(17, 0, nil))
precondition(cs.driving, "dwell restarted after speeding up")
cs.update(fix(18.5, 0, nil))
precondition(!cs.driving && cs.blend == 0.75, "drops to top-down after the dwell, gradually")
for i in 20..<25 { cs.update(fix(Double(i), 0, nil)) }
spec = cs.spec(for: fix(25, 0, nil))
precondition(cs.blend == 0 && spec.pitch == 0 && spec.lat == 52 && spec.lon == 21)
precondition(spec.heading == 100 && spec.distance == cameraOverheadDistance, "top-down keeps the heading")
print("OK")

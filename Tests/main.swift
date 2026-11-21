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
print("OK")

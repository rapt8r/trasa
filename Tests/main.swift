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

let posix = Locale(identifier: "en_US_POSIX"), polish = Locale(identifier: "pl_PL")
precondition(formatDuration(3725) == "1:02:05" && formatKmh(10) == "36 km/h")
precondition(formatKm(12346, locale: posix) == "12.35 km", formatKm(12346, locale: posix))
precondition(formatKm(9560, locale: polish) == "9,56 km", "numbers follow the region: " + formatKm(9560, locale: polish))
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
precondition(cs.driving && cs.targetHeading == 100 && cs.blend == 0.25, "enters driving, view changes gradually")
precondition(cs.heading > 90 && cs.heading < 100, "the map turns towards the new course gradually: \(cs.heading)")
for i in 3..<8 { cs.update(fix(Double(i), 10, 100)) }
precondition(cs.blend == 1)
var spec = cs.spec(for: fix(8, 10, 100))
precondition(spec.pitch == cameraDrivingPitch && abs(spec.heading - 100) < 0.01 && spec.lon > 21, "heading settles: \(spec.heading)")
precondition(abs(spec.distance - (cameraDrivingDistance + 10 * cameraDistancePerSpeed)) < 1e-6)

cs.update(fix(10, 0.2, 250))
precondition(cs.driving && cs.targetHeading == 100 && abs(cs.heading - 100) < 0.01, "course at near-zero speed is ignored")
cs.update(fix(12, 0.2, nil))
precondition(cs.driving, "short slow-down keeps the driving view")
cs.update(fix(13, 12, 100))
cs.update(fix(14, 0, nil))
cs.update(fix(17, 0, nil))
precondition(cs.driving, "dwell restarted after speeding up")
cs.update(fix(18.5, 0, nil))
precondition(!cs.driving && cs.blend == 0.625, "drops to top-down after the dwell, gradually")
for i in 20..<25 { cs.update(fix(Double(i), 0, nil)) }
spec = cs.spec(for: fix(25, 0, nil))
precondition(cs.blend == 0 && spec.pitch == 0 && spec.lat == 52 && spec.lon == 21)
precondition(abs(spec.heading - 100) < 0.01 && spec.distance == cameraOverheadDistance, "top-down keeps the heading")
// Camera blend is time-based: ten 0.1 s samples change the view as much as one 1 s fix
var fast = CameraState()
fast.update(fix(0, 10, 90))
for i in 1...10 { fast.update(fix(Double(i) / 10, 10, 90)) }
precondition(abs(fast.blend - 0.25) < 1e-9, "blend at 10 Hz: \(fast.blend)")

// Replay clock
let gapped = moving + [resumed, resumed2]
precondition(nextReplayClock(gapped, index: 2, clock: Date(timeIntervalSince1970: 10), step: 0.5) == resumed.t, "pause is skipped")
precondition(nextReplayClock(gapped, index: 0, clock: Date(timeIntervalSince1970: 1), step: 0.5) == Date(timeIntervalSince1970: 1.5))
precondition(nextReplayClock(gapped, index: 4, clock: Date(timeIntervalSince1970: 1005), step: 0.5) == Date(timeIntervalSince1970: 1005.5))

// Fuel cost
precondition(fuelUsed(distance: 50_000, per100: 8) == 4 && fuelUsed(distance: -1, per100: 8) == 0 && fuelUsed(distance: 1000, per100: -3) == 0)
precondition(formatCost(26, locale: posix) == "26.00 zł" && formatLitres(4.04, locale: posix) == "4.0 l")
precondition(formatCost(4.5, locale: polish) == "4,50 zł", formatCost(4.5, locale: polish))

// Weekly / monthly statistics
var cal = Calendar(identifier: .gregorian)
cal.timeZone = TimeZone(identifier: "UTC")!
cal.firstWeekday = 2
func tripOn(_ month: Int, _ day: Int) -> Trip {
    let t0 = cal.date(from: DateComponents(year: 2026, month: month, day: day, hour: 12))!.timeIntervalSince1970
    return Trip(url: URL(fileURLWithPath: "/t\(month)-\(day)"), points: [pt(t0, 52, 21, speed: 20), pt(t0 + 5, 52.001, 21, speed: 20)])
}
let history = [tripOn(11, 2), tripOn(11, 3), tripOn(11, 20), tripOn(12, 1)] // 2 Nov 2026 is a Monday
let months = summarize(history, by: .month, calendar: cal)
precondition(months.count == 2 && months[0].count == 1 && months[1].count == 3, "months")
precondition(abs(months[1].distance - 333.6) < 1.5 && months[1].duration == 15 && months[0].start > months[1].start)
let weeks = summarize(history, by: .weekOfYear, calendar: cal)
precondition(weeks.count == 3 && weeks.last!.count == 2, "weeks: \(weeks.map(\.count))")
precondition(summarize([], by: .month, calendar: cal).isEmpty)

// Speed limits
precondition(parseSpeedLimit(maxspeed: "50", highway: "residential") == 50 && parseSpeedLimit(maxspeed: " 70 ", highway: "primary") == 70)
precondition(parseSpeedLimit(maxspeed: "PL:urban", highway: "residential") == 50 && parseSpeedLimit(maxspeed: "PL:rural", highway: "tertiary") == 90)
precondition(parseSpeedLimit(maxspeed: nil, highway: "motorway") == 140 && parseSpeedLimit(maxspeed: nil, highway: "living_street") == 20)
precondition(parseSpeedLimit(maxspeed: nil, highway: "residential") == nil, "no guessing from the road class")
precondition(parseSpeedLimit(maxspeed: "50 mph", highway: "primary") == nil && parseSpeedLimit(maxspeed: "none", highway: "motorway") == nil)
precondition(parseSpeedLimit(maxspeed: "0", highway: "primary") == nil && parseSpeedLimit(maxspeed: "999", highway: "primary") == nil)

let osm = Data(#"{"elements":[{"type":"way","id":1,"geometry":[{"lat":52.0,"lon":20.99},{"lat":52.0,"lon":21.01}],"tags":{"highway":"primary","maxspeed":"70","name":"Wschodnia"}},{"type":"way","id":2,"geometry":[{"lat":51.99,"lon":21.0},null,{"lat":52.01,"lon":21.0}],"tags":{"highway":"residential","name":"Polnocna"}},{"type":"node","id":3},{"type":"way","id":4,"geometry":[{"lat":1,"lon":1}],"tags":{"highway":"primary"}}]}"#.utf8)
let ways = parseWays(osm)!
precondition(ways.count == 2 && ways[0].limit == 70 && ways[0].name == "Wschodnia" && ways[1].limit == nil && ways[1].lats.count == 2, "parseWays")
precondition(parseWays(Data("oops".utf8)) == nil && parseWays(Data(#"{"elements":[]}"#.utf8))!.isEmpty)
// At the crossing: 5 m north of the east-west road, 3 m east of the north-south road
let nearLat = 52.0 + 5 / 111_320.0, nearLon = 21.0 + 3 / (111_320.0 * cos(52.0 * Double.pi / 180))
let east = matchRoad(ways, lat: nearLat, lon: nearLon, course: 92)!
precondition(east.way.name == "Wschodnia" && abs(east.bearing - 90) < 1, "heading east: \(east.bearing)")
precondition(abs(east.lat - 52.0) < 1e-7 && abs(east.lon - nearLon) < 1e-7 && abs(east.distance - 5) < 0.1, "snapped onto the centre line")
let west = matchRoad(ways, lat: nearLat, lon: nearLon, course: 268)!
precondition(west.way.name == "Wschodnia" && abs(west.bearing - 270) < 1, "heading west: \(west.bearing)")
let north = matchRoad(ways, lat: nearLat, lon: nearLon, course: 5)!
precondition(north.way.name == "Polnocna" && abs(north.lon - 21.0) < 1e-7 && (north.bearing < 1 || north.bearing > 359), "heading north")
precondition(matchRoad(ways, lat: nearLat, lon: nearLon, course: nil)?.way.name == "Polnocna", "no course: nearest")
precondition(matchRoad(ways, lat: 52.005, lon: 21.005, course: 90) == nil, "500 m from any road")
precondition(matchRoad([], lat: 52, lon: 21, course: nil) == nil)

let tile = RoadTile(lat: 52.2297, lon: 21.0122)
precondition(tile.south <= 52.2297 && tile.north > 52.2297 && tile.west <= 21.0122 && tile.east > 21.0122)
precondition(abs(tile.north - tile.south - roadTileSize) < 1e-9 && tile == RoadTile(lat: 52.2101, lon: 21.0299))
precondition(RoadTile(lat: -0.01, lon: -0.01).x == -1 && RoadTile(lat: -0.01, lon: -0.01).y == -1)
let q = overpassQuery(tile)
precondition(q.contains("out tags geom;") && q.contains(String(format: "(%.4f,", tile.south)) && q.contains("living_street"), q)
// Per-frame motion
func eastMetres(_ p: TrackPoint) -> Double { (p.lon - 21) * 111_320 * cos(52 * Double.pi / 180) }
var sm = MotionSmoother()
precondition(sm.step(0.1) == nil, "nothing to show before the first fix")
sm.feed(TrackPoint(t: Date(timeIntervalSince1970: 0), lat: 52, lon: 21, alt: 0, speed: 20, course: 90, hAcc: 5))
precondition(sm.point!.lon == 21, "first fix is shown at once")
for _ in 0..<30 { _ = sm.step(1.0 / 30) }
precondition(eastMetres(sm.point!) > 10 && eastMetres(sm.point!) < 20.5, "after 1 s at 20 m/s: \(eastMetres(sm.point!))")
precondition(abs(sm.point!.lat - 52) < 1e-6 && abs(sm.point!.speed! - 20) < 1e-9)
for _ in 0..<150 { _ = sm.step(1.0 / 30) }
let coasted = eastMetres(sm.point!)
precondition(coasted > 28 && coasted < 20 * motionMaxPrediction + 0.5, "coasts, then stops without fixes: \(coasted)")
sm.feed(TrackPoint(t: Date(timeIntervalSince1970: 7), lat: 52, lon: 21.0006, alt: 0, speed: 20, course: 90, hAcc: 5))
precondition(sm.point!.lon < 21.0006, "a nearby fix is approached, not jumped to")
_ = sm.step(1.0 / 30)
precondition(eastMetres(sm.point!) > coasted, "moves on towards the new fix")
sm.feed(TrackPoint(t: Date(timeIntervalSince1970: 8), lat: 53, lon: 22, alt: 0, speed: 0, course: nil, hAcc: 5))
precondition(sm.point!.lat == 53 && sm.point!.lon == 22, "a far fix is shown at once")
var turn = MotionSmoother()
turn.feed(TrackPoint(t: Date(timeIntervalSince1970: 0), lat: 52, lon: 21, alt: 0, speed: 10, course: 350, hAcc: 5))
_ = turn.step(0.1)
turn.feed(TrackPoint(t: Date(timeIntervalSince1970: 1), lat: 52, lon: 21, alt: 0, speed: 10, course: 10, hAcc: 5))
_ = turn.step(0.1)
let turned = turn.point!.course!
precondition(turned > 350 || turned < 10, "course turns through north, not the long way: \(turned)")
// Sensors: the gyroscope carries the course on between fixes
func drive(_ sec: Double, lat: Double = 52, speed: Double?, course: Double?) -> TrackPoint {
    TrackPoint(t: Date(timeIntervalSince1970: sec), lat: lat, lon: 21, alt: 0, speed: speed, course: course, hAcc: 5)
}
var gyro = MotionSmoother()
gyro.feed(drive(0, speed: 20, course: 0))
for _ in 0..<60 { _ = gyro.step(1.0 / 60, yawRate: 10) }
precondition(abs(gyro.predictedCourse! - 10) < 0.01, "10 deg/s for 1 s: \(gyro.predictedCourse!)")
precondition(gyro.point!.lon > 21 && gyro.point!.course! > 3 && gyro.point!.course! < 10.5, "marker bends right: \(gyro.point!.course!)")
var wild = MotionSmoother()
wild.feed(drive(0, speed: 20, course: 0))
for _ in 0..<60 { _ = wild.step(1.0 / 60, yawRate: 500) }
precondition(wild.predictedCourse! <= motionMaxTurnRate + 0.01, "phone being handled is capped: \(wild.predictedCourse!)")
// Without a gyroscope, part of the turn seen between two fixes is assumed to continue
var noGyro = MotionSmoother()
noGyro.feed(drive(0, speed: 20, course: 0))
noGyro.feed(drive(1, lat: 52.00018, speed: 20, course: 20))
for _ in 0..<30 { _ = noGyro.step(1.0 / 60) }
precondition(abs(noGyro.predictedCourse! - (20 + 20 * motionGpsTurnShare * 0.5)) < 0.01, "GPS-only turn: \(noGyro.predictedCourse!)")
// A gyroscope reading of zero overrides that guess
var straight = MotionSmoother()
straight.feed(drive(0, speed: 20, course: 0))
straight.feed(drive(1, lat: 52.00018, speed: 20, course: 20))
for _ in 0..<30 { _ = straight.step(1.0 / 60, yawRate: 0) }
precondition(abs(straight.predictedCourse! - 20) < 1e-9)
// Compass: only while standing still
var parkedCar = MotionSmoother()
parkedCar.feed(drive(0, speed: 0, course: nil))
_ = parkedCar.step(0.1, compass: 90)
precondition(parkedCar.point!.course == 90 && parkedCar.point!.lat == 52, "compass gives the direction at a standstill")
parkedCar.feed(drive(1, speed: 10, course: 0))
for _ in 0..<120 { _ = parkedCar.step(1.0 / 60, yawRate: 0, compass: 90) }
precondition(parkedCar.point!.course! < 5 || parkedCar.point!.course! > 355, "moving: GPS course wins over the compass: \(parkedCar.point!.course!)")

// Speed against the limit
precondition(!isOverLimit(speed: 50 / 3.6, limit: 50) && !isOverLimit(speed: 52.9 / 3.6, limit: 50), "small excess is tolerated")
precondition(isOverLimit(speed: 54 / 3.6, limit: 50) && !isOverLimit(speed: nil, limit: 50))

// GPS status
let nowish = Date(timeIntervalSince1970: 1000)
func fixAged(_ age: Double, acc: Double) -> TrackPoint {
    TrackPoint(t: nowish.addingTimeInterval(-age), lat: 52, lon: 21, alt: 0, speed: 0, course: nil, hAcc: acc)
}
precondition(gpsStatus(fix: nil, now: nowish) == .searching && gpsStatus(fix: fixAged(6, acc: 5), now: nowish) == .searching)
precondition(gpsStatus(fix: fixAged(1, acc: 5), now: nowish) == .good && gpsStatus(fix: fixAged(1, acc: 40), now: nowish) == .weak)

// Sun: day and night at the car's position
var utc = Calendar(identifier: .gregorian)
utc.timeZone = TimeZone(identifier: "UTC")!
func at(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    utc.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
}
let midsummerNoon = solarElevation(lat: 52.23, lon: 21.01, date: at(6, 21, 10, 38))
precondition(abs(midsummerNoon - 61.2) < 1.5, "Warsaw, solar noon, 21 June: \(midsummerNoon)")
let midwinterNoon = solarElevation(lat: 52.23, lon: 21.01, date: at(12, 21, 10, 35))
precondition(abs(midwinterNoon - 14.3) < 1.5, "Warsaw, solar noon, 21 December: \(midwinterNoon)")
precondition(isNight(lat: 52.23, lon: 21.01, date: at(11, 22, 21, 0)), "a November evening is night")
precondition(!isNight(lat: 52.23, lon: 21.01, date: at(11, 22, 11, 0)), "late morning is day")
precondition(!isNight(lat: 52.23, lon: 21.01, date: at(6, 21, 17, 0)) && isNight(lat: 52.23, lon: 21.01, date: at(6, 21, 23, 0)))
precondition(isNight(lat: -33.87, lon: 151.21, date: at(6, 21, 12, 0)), "Sydney at 22:00 local")

// Spring: eases in and out, settles on the target, never overshoots
var sv = 0.0, sVel = 0.0, sPeak = 0.0, sFirst = 0.0
for i in 0..<120 {
    springStep(&sv, &sVel, to: 10, smoothTime: 0.5, dt: 1.0 / 60)
    if i == 0 { sFirst = sv }
    sPeak = max(sPeak, sv)
}
precondition(sFirst < 0.05, "starts gently: \(sFirst)")
precondition(abs(sv - 10) < 0.05 && sPeak <= 10.0001, "arrives without overshoot: \(sv) peak \(sPeak)")
precondition(shortestTurn(from: 350, to: 10) == 20 && shortestTurn(from: 10, to: 350) == -20 && wrapDegrees(-10) == 350 && wrapDegrees(370) == 10)
print("OK")

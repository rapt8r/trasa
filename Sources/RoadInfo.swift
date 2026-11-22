import Combine
import CoreLocation
import Foundation

/// Speed limit (OpenStreetMap) and street name (Apple geocoder) for the current position.
///
/// Privacy: limits are fetched per map tile (`roadTileSize`, roughly 2 x 3 km), never per position,
/// and each tile is kept on the phone for `cacheMaxAge`. The server therefore sees which tiles were
/// needed and the phone's IP address, not the track. No cookies, no identifiers.
final class RoadInfo: ObservableObject {
    static let endpoint = URL(string: "https://overpass-api.de/api/interpreter")!
    static let cacheMaxAge = 30.0 * 86_400   // s
    static let retryDelay = 60.0             // s after a failed download (the public server is often busy)
    static let limitHold = 3.0               // s the sign stays after the match is lost
    static let prefetchDistance = 1_500.0    // m ahead along the course
    static let geocodeInterval = 20.0        // s; Apple throttles reverse geocoding
    static let geocodeDistance = 150.0       // m
    static let snapMinSpeed = 2.0            // m/s; a parked car stays where GPS puts it

    @Published var speedLimit: Int?
    @Published var street: String?

    private var tiles: [RoadTile: [RoadWay]] = [:]
    private var loading: Set<RoadTile> = []
    private var retryAfter: [RoadTile: Date] = [:]
    private var lastRun = Date.distantPast
    private var lastMatch = Date.distantPast
    private var lastGeocode: (at: Date, lat: Double, lon: Double)?
    private let geocoder = CLGeocoder()
    private let session = URLSession(configuration: .ephemeral)
    private let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("osm", isDirectory: true)

    /// Call on every position update; does real work at most once a second.
    func update(_ p: TrackPoint, limitsEnabled: Bool) {
        let now = Date()
        guard now.timeIntervalSince(lastRun) >= 0.9 else { return }
        lastRun = now

        if limitsEnabled {
            let tile = RoadTile(lat: p.lat, lon: p.lon)
            load(tile)
            if let course = p.course, (p.speed ?? 0) > 5 {
                let ahead = destination(lat: p.lat, lon: p.lon, bearing: course, distance: Self.prefetchDistance)
                load(RoadTile(lat: ahead.lat, lon: ahead.lon))
            }
            if tiles.count > 9 {
                tiles = tiles.filter { abs($0.key.x - tile.x) <= 1 && abs($0.key.y - tile.y) <= 1 }
            }
            // ponytail: linear scan over every road segment of the tile once a second; add a grid index if it shows up in profiling.
            var limit: Int?
            if let ways = tiles[tile] {
                limit = matchRoad(ways, lat: p.lat, lon: p.lon, course: p.course)?.way.limit
            }
            if let limit {
                lastMatch = now
                if speedLimit != limit { speedLimit = limit }
            } else if speedLimit != nil, now.timeIntervalSince(lastMatch) > Self.limitHold {
                speedLimit = nil
            }
        } else if speedLimit != nil {
            speedLimit = nil
        }

        geocode(p, now: now)
    }

    /// The fix moved onto the road it is most likely on, facing along it. Display only: recordings
    /// keep raw GPS. Returns the fix unchanged when no road data is loaded or nothing matches.
    func snapped(_ p: TrackPoint) -> TrackPoint {
        guard let course = p.course, (p.speed ?? 0) >= Self.snapMinSpeed,
              let ways = tiles[RoadTile(lat: p.lat, lon: p.lon)],
              let match = matchRoad(ways, lat: p.lat, lon: p.lon, course: course) else { return p }
        var out = p
        out.lat = match.lat
        out.lon = match.lon
        out.course = match.bearing
        return out
    }

    private func load(_ tile: RoadTile) {
        guard tiles[tile] == nil, !loading.contains(tile), (retryAfter[tile] ?? .distantPast) < Date() else { return }
        loading.insert(tile)
        let file = cacheDir.appendingPathComponent(tile.name + ".json")
        let maxAge = Self.cacheMaxAge

        DispatchQueue.global(qos: .utility).async { [weak self] in
            var cached: [RoadWay]?
            let attrs = try? FileManager.default.attributesOfItem(atPath: file.path)
            if let modified = attrs?[.modificationDate] as? Date, Date().timeIntervalSince(modified) < maxAge,
               let data = try? Data(contentsOf: file) {
                cached = parseWays(data)
            }
            DispatchQueue.main.async {
                if let cached {
                    self?.finish(tile, ways: cached)
                } else {
                    self?.download(tile, to: file)
                }
            }
        }
    }

    private func download(_ tile: RoadTile, to file: URL) {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("Journey-iOS", forHTTPHeaderField: "User-Agent")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let query = overpassQuery(tile).addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        request.httpBody = Data(("data=" + query).utf8)
        let dir = cacheDir

        session.dataTask(with: request) { [weak self] data, response, _ in
            var ways: [RoadWay]?
            if let http = response as? HTTPURLResponse, http.statusCode == 200, let data {
                ways = parseWays(data)
                if ways != nil {
                    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    try? data.write(to: file, options: .atomic)
                }
            }
            DispatchQueue.main.async { self?.finish(tile, ways: ways) }
        }.resume()
    }

    private func finish(_ tile: RoadTile, ways: [RoadWay]?) {
        loading.remove(tile)
        if let ways {
            tiles[tile] = ways
        } else {
            retryAfter[tile] = Date().addingTimeInterval(Self.retryDelay)
        }
    }

    private func geocode(_ p: TrackPoint, now: Date) {
        let here = CLLocation(latitude: p.lat, longitude: p.lon)
        if let last = lastGeocode {
            let moved = here.distance(from: CLLocation(latitude: last.lat, longitude: last.lon))
            if now.timeIntervalSince(last.at) < Self.geocodeInterval || moved < Self.geocodeDistance { return }
        }
        guard !geocoder.isGeocoding else { return }
        lastGeocode = (now, p.lat, p.lon)
        geocoder.reverseGeocodeLocation(here) { [weak self] placemarks, _ in
            // On an error (offline, throttled) the last known name stays.
            guard let placemark = placemarks?.first else { return }
            let name = placemark.thoroughfare
            DispatchQueue.main.async { self?.street = name }
        }
    }
}

import Combine
import CoreLocation
import UIKit

extension TrackPoint {
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
}

final class Recorder: NSObject, ObservableObject, CLLocationManagerDelegate {
    /// Fixes worse than this are dropped (tunnels, cold start). Tune against real drives.
    static let maxHorizontalAccuracy = 50.0 // m
    /// Fixes older than this never move the live map.
    static let maxLiveAge = 10.0 // s

    @Published var points: [TrackPoint] = []
    /// Latest fix, recording or not: drives the map camera and the speedometer.
    @Published var live: TrackPoint?
    /// Non-nil while a saved trip is being replayed on the map (debug aid); `live` then comes from it.
    @Published var replayTrip: Trip?
    @Published var replayRate = 1.0
    var isReplaying: Bool { replayTrip != nil }
    @Published var isRecording = false
    @Published var isPaused = false
    @Published var trips: [Trip] = []
    @Published var denied = false
    @Published var error: String?

    private let manager = CLLocationManager()
    private let encoder = JSONEncoder()
    private let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    private var file: FileHandle?
    private var fileURL: URL?
    private var startedAt = Date.distantPast
    private var segment = 0
    private static let replayTick = 0.05 // s
    private var replayTimer: Timer?
    private var replayClock = Date.distantPast
    private var replayIndex = 0

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.activityType = .automotiveNavigation
        manager.pausesLocationUpdatesAutomatically = false
        manager.showsBackgroundLocationIndicator = true
        loadTrips()
    }

    /// GPS runs whenever the app is on screen so the map can follow the car.
    /// Background updates are allowed only between start() and stop().
    func requestPermission() {
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
    }

    func start() {
        stopReplay()
        let url = dir.appendingPathComponent("trip-\(Int(Date().timeIntervalSince1970)).jsonl")
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: url) else {
            error = "Nie można utworzyć pliku trasy."
            return
        }
        file = handle
        fileURL = url
        points = []
        error = nil
        startedAt = Date()
        isRecording = true
        isPaused = false
        segment = 0
        UIApplication.shared.isIdleTimerDisabled = true // keep the screen on in the car
        manager.allowsBackgroundLocationUpdates = true // needs UIBackgroundModes: location
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
    }

    func pause() {
        guard isRecording, !isPaused else { return }
        // GPS keeps running and fixes are dropped in didUpdateLocations: stopping updates
        // would let iOS suspend the app in the background mid-pause. Costs battery while paused.
        isPaused = true
    }

    func resume() {
        guard isRecording, isPaused else { return }
        segment += 1
        startedAt = Date() // again skip the cached fix from before the pause
        isPaused = false
        manager.startUpdatingLocation()
    }

    /// Ends the recording. Returns the saved trip's file, or nil when nothing was recorded.
    @discardableResult
    func stop() -> URL? {
        guard isRecording else { return nil }
        manager.allowsBackgroundLocationUpdates = false // GPS stays on for the map, but only in the foreground
        try? file?.close()
        file = nil
        isRecording = false
        isPaused = false
        UIApplication.shared.isIdleTimerDisabled = false
        let saved = points.isEmpty ? nil : fileURL
        if points.isEmpty, let fileURL { try? FileManager.default.removeItem(at: fileURL) }
        loadTrips()
        return saved
    }

    // MARK: Replay (nothing is written to disk)

    func startReplay(_ trip: Trip) {
        guard !isRecording, let first = trip.points.first else { return }
        stopReplay()
        points = []
        replayClock = first.t
        replayIndex = 0
        replayTrip = trip
        UIApplication.shared.isIdleTimerDisabled = true
        let timer = Timer(timeInterval: Self.replayTick, repeats: true) { [weak self] _ in self?.replayStep() }
        RunLoop.main.add(timer, forMode: .common)
        replayTimer = timer
    }

    func stopReplay() {
        replayTimer?.invalidate()
        replayTimer = nil
        guard replayTrip != nil else { return }
        replayTrip = nil
        points = []
        live = nil
        UIApplication.shared.isIdleTimerDisabled = false
    }

    /// Hands the recorded fixes to `live` at the pace they were recorded (times the tempo), exactly as
    /// GPS would, so the map, camera and road info behave as they do on a real drive.
    private func replayStep() {
        guard let track = replayTrip?.points else {
            stopReplay()
            return
        }
        let before = replayIndex
        while replayIndex < track.count, track[replayIndex].t <= replayClock { replayIndex += 1 }
        if replayIndex > before {
            points.append(contentsOf: track[before..<replayIndex])
            live = track[replayIndex - 1]
        }
        if replayIndex >= track.count {
            // End of the trip: keep the last frame on screen until the user taps "Zakończ".
            replayTimer?.invalidate()
            replayTimer = nil
            return
        }
        replayClock = nextReplayClock(track, index: max(0, replayIndex - 1), clock: replayClock, step: Self.replayTick * replayRate)
    }

    func delete(_ trip: Trip) {
        try? FileManager.default.removeItem(at: trip.url)
        // Export copies (GPX, CSV) made for sharing go with it.
        let exported = FileManager.default.temporaryDirectory
            .appendingPathComponent(trip.url.deletingPathExtension().lastPathComponent)
        for ext in ["gpx", "csv"] { try? FileManager.default.removeItem(at: exported.appendingPathExtension(ext)) }
        trips.removeAll { $0.id == trip.id }
    }

    // ponytail: parses every trip file at launch and after each stop; cache per-trip summaries if the list gets slow.
    private func loadTrips() {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        trips = files
            .filter { $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                let pts = parseJSONL(data)
                return pts.isEmpty ? nil : Trip(url: url, points: pts)
            }
    }

    // MARK: CLLocationManagerDelegate

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        for loc in locations where loc.horizontalAccuracy >= 0 && loc.horizontalAccuracy <= Self.maxHorizontalAccuracy {
            let p = TrackPoint(t: loc.timestamp,
                               lat: loc.coordinate.latitude,
                               lon: loc.coordinate.longitude,
                               alt: loc.altitude,
                               speed: loc.speed >= 0 ? loc.speed : nil,
                               course: loc.course >= 0 ? loc.course : nil,
                               hAcc: loc.horizontalAccuracy,
                               seg: segment == 0 ? nil : segment)
            // CoreLocation first hands over its cached fix, which can be hours old.
            if !isReplaying, loc.timestamp.timeIntervalSinceNow > -Self.maxLiveAge { live = p }
            // Recording: same rules as before - skip anything from before Start / Resume.
            guard isRecording, !isPaused, let file, loc.timestamp >= startedAt else { continue }
            // Appended to disk right away: if iOS kills the app mid-drive, the trip so far is kept.
            do {
                var line = try encoder.encode(p)
                line.append(0x0A)
                try file.write(contentsOf: line)
                points.append(p)
            } catch {
                self.error = "Błąd zapisu: \(error.localizedDescription)"
            }
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        denied = status == .denied || status == .restricted
        if status == .authorizedWhenInUse || status == .authorizedAlways {
            manager.startUpdatingLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Transient "location unknown" errors are normal; CoreLocation keeps trying.
    }
}

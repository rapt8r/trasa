import Combine
import CoreLocation
import UIKit

extension TrackPoint {
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
}

final class Recorder: NSObject, ObservableObject, CLLocationManagerDelegate {
    /// Fixes worse than this are dropped (tunnels, cold start). Tune against real drives.
    static let maxHorizontalAccuracy = 50.0 // m

    @Published var points: [TrackPoint] = []
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

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.activityType = .automotiveNavigation
        manager.pausesLocationUpdatesAutomatically = false
        manager.allowsBackgroundLocationUpdates = true // needs UIBackgroundModes: location
        manager.showsBackgroundLocationIndicator = true
        loadTrips()
    }

    func requestPermission() { manager.requestWhenInUseAuthorization() }

    func start() {
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

    func stop() {
        manager.stopUpdatingLocation()
        try? file?.close()
        file = nil
        isRecording = false
        isPaused = false
        UIApplication.shared.isIdleTimerDisabled = false
        if points.isEmpty, let fileURL { try? FileManager.default.removeItem(at: fileURL) }
        loadTrips()
    }

    func delete(_ trip: Trip) {
        try? FileManager.default.removeItem(at: trip.url)
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
        guard isRecording, !isPaused, let file else { return }
        // CoreLocation first hands over its cached fix, which can be hours old: skip anything from before Start.
        for loc in locations where loc.timestamp >= startedAt && loc.horizontalAccuracy >= 0 && loc.horizontalAccuracy <= Self.maxHorizontalAccuracy {
            let p = TrackPoint(t: loc.timestamp,
                               lat: loc.coordinate.latitude,
                               lon: loc.coordinate.longitude,
                               alt: loc.altitude,
                               speed: loc.speed >= 0 ? loc.speed : nil,
                               course: loc.course >= 0 ? loc.course : nil,
                               hAcc: loc.horizontalAccuracy,
                               seg: segment == 0 ? nil : segment)
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
        if isRecording && !isPaused && (status == .authorizedWhenInUse || status == .authorizedAlways) {
            manager.startUpdatingLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Transient "location unknown" errors are normal; CoreLocation keeps trying.
    }
}

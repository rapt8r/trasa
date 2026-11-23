import Combine
import CoreLocation
import Foundation

/// Names of the places where saved trips start and end ("Rylsk → Rawa Mazowiecka"), looked up
/// with Apple's geocoder once per trip and kept on the phone.
final class TripPlaces: ObservableObject {
    struct Name: Codable {
        var from: String?
        var to: String?
    }

    static let storeKey = "tripPlaces"
    static let pause = 1.5 // s between trips; Apple throttles reverse geocoding

    @Published private(set) var names: [String: Name] = [:]

    private let geocoder = CLGeocoder()
    private var queue: [(key: String, start: CLLocation, end: CLLocation)] = []
    private var working = false

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.storeKey),
           let saved = try? JSONDecoder().decode([String: Name].self, from: data) {
            names = saved
        }
    }

    func title(for trip: Trip) -> String? {
        names[trip.url.lastPathComponent].flatMap { tripTitle(from: $0.from, to: $0.to) }
    }

    /// Looks up the trips that have no name yet, one at a time.
    func resolve(_ trips: [Trip]) {
        for trip in trips {
            let key = trip.url.lastPathComponent
            guard names[key] == nil, !queue.contains(where: { $0.key == key }),
                  let first = trip.points.first, let last = trip.points.last else { continue }
            queue.append((key, CLLocation(latitude: first.lat, longitude: first.lon),
                          CLLocation(latitude: last.lat, longitude: last.lon)))
        }
        next()
    }

    private func next() {
        guard !working, let job = queue.first else { return }
        working = true
        place(job.start) { [weak self] from in
            guard let self else { return }
            guard let from else {
                // Offline or throttled: leave the rest for the next time the list is shown.
                self.queue.removeAll()
                self.working = false
                return
            }
            self.place(job.end) { to in
                self.names[job.key] = Name(from: from, to: to)
                if let data = try? JSONEncoder().encode(self.names) {
                    UserDefaults.standard.set(data, forKey: Self.storeKey)
                }
                self.queue.removeAll { $0.key == job.key }
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.pause) {
                    self.working = false
                    self.next()
                }
            }
        }
    }

    private func place(_ location: CLLocation, completion: @escaping (String?) -> Void) {
        geocoder.reverseGeocodeLocation(location) { placemarks, _ in
            let placemark = placemarks?.first
            let name = placemark?.locality ?? placemark?.subAdministrativeArea ?? placemark?.name
            DispatchQueue.main.async { completion(name) }
        }
    }
}

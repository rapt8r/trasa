import Combine
import CoreLocation
import Foundation

/// Names of the places where saved trips start and end ("Rylsk → Rawa Mazowiecka"), looked up
/// with Apple's geocoder once per trip and kept on the phone.
///
/// Privacy: a trip's ends are often someone's home or workplace, so the position sent is rounded
/// to about a kilometre (enough for a town's name), the lookup can be switched off in Settings,
/// and a name is forgotten as soon as its trip is deleted.
final class TripPlaces: ObservableObject {
    struct Name: Codable {
        var from: String?
        var to: String?
    }

    static let storeKey = "tripPlaces"
    static let pause = 1.5 // s between trips; Apple throttles reverse geocoding
    static let coarseness = 100.0 // positions are rounded to 1/100 of a degree, roughly 1 km

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

    private func save() {
        if let data = try? JSONEncoder().encode(names) {
            UserDefaults.standard.set(data, forKey: Self.storeKey)
        }
    }

    private func coarse(_ p: TrackPoint) -> CLLocation {
        CLLocation(latitude: (p.lat * Self.coarseness).rounded() / Self.coarseness,
                   longitude: (p.lon * Self.coarseness).rounded() / Self.coarseness)
    }

    /// Forgets the names of trips that no longer exist, then, when `enabled`, looks up the trips
    /// that have no name yet, one at a time.
    func resolve(_ trips: [Trip], enabled: Bool) {
        let existing = Set(trips.map { $0.url.lastPathComponent })
        if names.keys.contains(where: { !existing.contains($0) }) {
            names = names.filter { existing.contains($0.key) }
            save()
        }
        queue.removeAll { !existing.contains($0.key) }
        guard enabled else {
            queue.removeAll()
            return
        }
        for trip in trips {
            let key = trip.url.lastPathComponent
            guard names[key] == nil, !queue.contains(where: { $0.key == key }),
                  let first = trip.points.first, let last = trip.points.last else { continue }
            queue.append((key, coarse(first), coarse(last)))
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
                // The trip may have been deleted, or the lookup switched off, while this was under way.
                if self.queue.contains(where: { $0.key == job.key }) {
                    self.names[job.key] = Name(from: from, to: to)
                    self.save()
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

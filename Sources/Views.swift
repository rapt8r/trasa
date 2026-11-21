import SwiftUI
import MapKit
import Charts

@main
struct TrasaApp: App {
    @StateObject private var recorder = Recorder()

    var body: some Scene {
        WindowGroup {
            TabView {
                RecordView().tabItem { Label("Nagrywanie", systemImage: "record.circle") }
                TripListView().tabItem { Label("Trasy", systemImage: "list.bullet") }
            }
            .environmentObject(recorder)
        }
    }
}

struct Stat: View {
    let title: String
    let value: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value).font(.headline).monospacedDigit()
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

struct RecordView: View {
    @EnvironmentObject var recorder: Recorder
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)

    var body: some View {
        let stats = TripStats(recorder.points)
        Map(position: $camera) {
            UserAnnotation()
            if recorder.points.count > 1 {
                MapPolyline(coordinates: recorder.points.map(\.coordinate)).stroke(.blue, lineWidth: 5)
            }
        }
        .mapControls { MapUserLocationButton() }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 12) {
                if recorder.denied {
                    Text("Brak dostępu do lokalizacji. Włącz go w Ustawieniach.").foregroundStyle(.red)
                }
                if let error = recorder.error {
                    Text(error).foregroundStyle(.red)
                }
                Text(formatKmh(recorder.points.last?.speed ?? 0))
                    .font(.system(size: 56, weight: .bold, design: .rounded))
                    .monospacedDigit()
                HStack {
                    Stat(title: "Dystans", value: formatKm(stats.distance))
                    Stat(title: "Czas", value: formatDuration(stats.duration))
                    Stat(title: "Maks.", value: formatKmh(stats.maxSpeed))
                }
                Button {
                    if recorder.isRecording { recorder.stop() } else { recorder.start() }
                } label: {
                    Text(recorder.isRecording ? "Stop" : "Start")
                        .font(.title2.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(recorder.isRecording ? .red : .green)
            }
            .padding()
            .background(.regularMaterial)
        }
        .onAppear { recorder.requestPermission() }
    }
}

struct TripListView: View {
    @EnvironmentObject var recorder: Recorder

    var body: some View {
        NavigationStack {
            List {
                ForEach(recorder.trips) { trip in
                    NavigationLink {
                        TripDetailView(trip: trip)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(trip.start.formatted(date: .abbreviated, time: .shortened)).font(.headline)
                            Text("\(formatKm(trip.stats.distance)) · \(formatDuration(trip.stats.duration)) · śr. \(formatKmh(trip.stats.avgSpeed))")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { offsets in
                    for trip in offsets.map({ recorder.trips[$0] }) { recorder.delete(trip) }
                }
            }
            .navigationTitle("Trasy")
            .overlay {
                if recorder.trips.isEmpty {
                    ContentUnavailableView("Brak tras", systemImage: "car", description: Text("Nagraj pierwszą trasę w zakładce Nagrywanie."))
                }
            }
        }
    }
}

struct TripDetailView: View {
    let trip: Trip
    @State private var gpxURL: URL?

    var body: some View {
        let s = trip.stats
        // Chart gets at most ~300 samples; the map and the files keep every point.
        let samples = stride(from: 0, to: trip.points.count, by: max(1, trip.points.count / 300)).map { trip.points[$0] }
        ScrollView {
            VStack(spacing: 16) {
                Map(initialPosition: .automatic) {
                    MapPolyline(coordinates: trip.points.map(\.coordinate)).stroke(.blue, lineWidth: 4)
                    if let first = trip.points.first, let last = trip.points.last {
                        Marker("Start", coordinate: first.coordinate).tint(.green)
                        Marker("Koniec", coordinate: last.coordinate).tint(.red)
                    }
                }
                .frame(height: 320)
                .clipShape(RoundedRectangle(cornerRadius: 12))

                Grid(horizontalSpacing: 8, verticalSpacing: 16) {
                    GridRow {
                        Stat(title: "Dystans", value: formatKm(s.distance))
                        Stat(title: "Czas", value: formatDuration(s.duration))
                        Stat(title: "Czas jazdy", value: formatDuration(s.movingTime))
                    }
                    GridRow {
                        Stat(title: "Śr. prędkość", value: formatKmh(s.avgSpeed))
                        Stat(title: "Śr. w ruchu", value: formatKmh(s.avgMovingSpeed))
                        Stat(title: "Maks. prędkość", value: formatKmh(s.maxSpeed))
                    }
                    GridRow {
                        Stat(title: "Wys. min.", value: String(format: "%.0f m", s.minAlt))
                        Stat(title: "Wys. maks.", value: String(format: "%.0f m", s.maxAlt))
                        Stat(title: "Punkty GPS", value: "\(trip.points.count)")
                    }
                    GridRow {
                        Stat(title: "Start", value: trip.start.formatted(date: .omitted, time: .standard))
                        Stat(title: "Koniec", value: (trip.points.last?.t ?? trip.start).formatted(date: .omitted, time: .standard))
                        Stat(title: "Postój", value: formatDuration(s.duration - s.movingTime))
                    }
                }

                Text("Prędkość (km/h)").font(.headline).frame(maxWidth: .infinity, alignment: .leading)
                Chart(samples, id: \.t) { p in
                    LineMark(x: .value("Czas", p.t), y: .value("km/h", (p.speed ?? 0) * 3.6))
                }
                .frame(height: 180)

                Text("Wysokość (m)").font(.headline).frame(maxWidth: .infinity, alignment: .leading)
                Chart(samples, id: \.t) { p in
                    LineMark(x: .value("Czas", p.t), y: .value("m", p.alt))
                }
                .frame(height: 140)
            }
            .padding()
        }
        .navigationTitle(trip.start.formatted(date: .abbreviated, time: .shortened))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let gpxURL {
                ShareLink(item: gpxURL) { Label("Eksport GPX", systemImage: "square.and.arrow.up") }
            }
        }
        .task {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(trip.url.deletingPathExtension().lastPathComponent + ".gpx")
            if (try? gpx(trip.points).write(to: url, atomically: true, encoding: .utf8)) != nil { gpxURL = url }
        }
    }
}

import SwiftUI
import MapKit
import Charts

@main
struct TrasaApp: App {
    @StateObject private var recorder = Recorder()

    var body: some Scene {
        WindowGroup {
            RecordView().environmentObject(recorder)
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
    @State private var follow = CameraState()
    @State private var showTrips = false
    @State private var expanded = false

    var body: some View {
        Map(position: $camera) {
            UserAnnotation()
            if recorder.points.count > 1 {
                MapPolyline(coordinates: recorder.points.map(\.coordinate)).stroke(.blue, lineWidth: 6)
            }
        }
        .mapStyle(.standard(elevation: .realistic))
        .overlay(alignment: .topTrailing) { mapButtons }
        .safeAreaInset(edge: .bottom) { panel }
        .onAppear { recorder.requestPermission() }
        .onChange(of: recorder.live?.t) { moveCamera(force: false) }
        .sheet(isPresented: $showTrips) {
            TripListView()
                .environmentObject(recorder)
                .presentationDragIndicator(.visible)
        }
        .environment(\.colorScheme, .dark) // easier on the eyes at night in the car
    }

    /// Called once per GPS fix. Each move is animated over the gap to the next fix, so the map glides;
    /// the top-down <-> behind-the-marker change is spread over several fixes by CameraState.
    private func moveCamera(force: Bool) {
        guard let p = recorder.live else { return }
        follow.update(p)
        // The user dragged the map: leave it alone until they tap the recenter button.
        guard force || !camera.positionedByUser else { return }
        let spec = follow.spec(for: p)
        let target = MapCamera(centerCoordinate: CLLocationCoordinate2D(latitude: spec.lat, longitude: spec.lon),
                               distance: spec.distance,
                               heading: spec.heading,
                               pitch: spec.pitch)
        withAnimation(.linear(duration: 1)) { camera = .camera(target) }
    }

    private var mapButtons: some View {
        VStack(spacing: 12) {
            Button {
                showTrips = true
            } label: {
                Image(systemName: "list.bullet")
                    .font(.title3)
                    .frame(width: 48, height: 48)
                    .background(.regularMaterial, in: Circle())
            }
            .accessibilityLabel("Trasy")
            if camera.positionedByUser {
                Button {
                    moveCamera(force: true)
                } label: {
                    Image(systemName: "location.fill")
                        .font(.title3)
                        .frame(width: 48, height: 48)
                        .background(.regularMaterial, in: Circle())
                }
                .accessibilityLabel("Wróć do mojej pozycji")
            }
        }
        .padding(12)
    }

    private var panel: some View {
        let stats = TripStats(recorder.points)
        let live = recorder.live
        let speedText = String(format: "%.0f", (live?.speed ?? 0) * 3.6)
        let altitudeText: String = live.map { String(format: "%.0f m", $0.alt) } ?? "–"
        let courseText: String = live?.course.map { compass($0) } ?? "–"
        let accuracyText: String = live.map { String(format: "±%.0f m", $0.hAcc) } ?? "–"
        return VStack(spacing: 10) {
            if recorder.denied {
                Text("Brak dostępu do lokalizacji. Włącz go w Ustawieniach.").foregroundStyle(.red)
            }
            if let error = recorder.error {
                Text(error).foregroundStyle(.red)
            }
            HStack(alignment: .center, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(speedText)
                        .font(.system(size: 52, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("km/h").font(.subheadline).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                if recorder.isPaused {
                    Text("PAUZA").font(.caption.bold()).foregroundStyle(.orange)
                }
                Spacer(minLength: 0)
                Stat(title: "Dystans", value: formatKm(stats.distance))
                Stat(title: "Czas", value: formatDuration(stats.duration))
                Button {
                    withAnimation { expanded.toggle() }
                } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.up")
                        .font(.headline)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(expanded ? "Zwiń szczegóły" : "Rozwiń szczegóły")
            }
            if expanded {
                HStack {
                    Stat(title: "Maks.", value: formatKmh(stats.maxSpeed))
                    Stat(title: "Średnia", value: formatKmh(stats.avgSpeed))
                    Stat(title: "Wysokość", value: altitudeText)
                    Stat(title: "Kierunek", value: courseText)
                    Stat(title: "GPS", value: accuracyText)
                }
                // Reserved for car data; filled once the OBD adapter is connected.
                VStack(spacing: 6) {
                    HStack {
                        Stat(title: "Spalanie", value: "–")
                        Stat(title: "Koszt", value: "–")
                        Stat(title: "Obroty", value: "–")
                        Stat(title: "Temp. silnika", value: "–")
                    }
                    Text("Dane z auta pojawią się po podłączeniu OBD")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 12) {
                if recorder.isRecording {
                    Button {
                        if recorder.isPaused { recorder.resume() } else { recorder.pause() }
                    } label: {
                        Text(recorder.isPaused ? "Wznów" : "Pauza")
                            .font(.title3.bold())
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                }
                Button {
                    if recorder.isRecording { recorder.stop() } else { recorder.start() }
                } label: {
                    Text(recorder.isRecording ? "Stop" : "Start")
                        .font(.title3.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(recorder.isRecording ? .red : .green)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .padding(.horizontal, 8)
    }
}

struct TripListView: View {
    @EnvironmentObject var recorder: Recorder

    var body: some View {
        NavigationStack {
            List {
                if !recorder.trips.isEmpty {
                    HStack {
                        Stat(title: "Trasy", value: "\(recorder.trips.count)")
                        Stat(title: "Łącznie", value: formatKm(recorder.trips.reduce(0.0) { $0 + $1.stats.distance }))
                        Stat(title: "Czas", value: formatDuration(recorder.trips.reduce(0.0) { $0 + $1.stats.duration }))
                    }
                }
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
                    ContentUnavailableView("Brak tras", systemImage: "car", description: Text("Nagraj pierwszą trasę przyciskiem Start na mapie."))
                }
            }
        }
    }
}

struct TripDetailView: View {
    let trip: Trip
    @State private var gpxURL: URL?
    @State private var csvURL: URL?
    @State private var satellite = false

    var body: some View {
        let s = trip.stats
        let chunks = speedChunks(trip.points)
        // Chart gets at most ~300 samples; the map and the files keep every point.
        let samples = stride(from: 0, to: trip.points.count, by: max(1, trip.points.count / 300)).map { trip.points[$0] }
        ScrollView {
            VStack(spacing: 16) {
                Map(initialPosition: .automatic) {
                    ForEach(chunks) { chunk in
                        MapPolyline(coordinates: trip.points[chunk.range].map(\.coordinate))
                            .stroke(Color(hue: 0.33 * (1 - chunk.fraction), saturation: 0.9, brightness: 0.85), lineWidth: 5)
                    }
                    if let first = trip.points.first, let last = trip.points.last {
                        Marker("Start", coordinate: first.coordinate).tint(.green)
                        Marker("Koniec", coordinate: last.coordinate).tint(.red)
                    }
                }
                .mapStyle(satellite ? MapStyle.hybrid : MapStyle.standard)
                .frame(height: 320)
                .overlay(alignment: .topTrailing) {
                    Button {
                        satellite.toggle()
                    } label: {
                        Image(systemName: satellite ? "map" : "globe")
                            .padding(10)
                            .background(.regularMaterial, in: Circle())
                    }
                    .accessibilityLabel(satellite ? "Mapa" : "Satelita")
                    .padding(8)
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))

                Text("Kolor trasy: zielony – wolno, czerwony – szybko")
                    .font(.caption)
                    .foregroundStyle(.secondary)

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
            ToolbarItemGroup(placement: .topBarTrailing) {
                if let csvURL { ShareLink("CSV", item: csvURL) }
                if let gpxURL { ShareLink("GPX", item: gpxURL) }
            }
        }
        .task {
            let base = FileManager.default.temporaryDirectory
                .appendingPathComponent(trip.url.deletingPathExtension().lastPathComponent)
            let g = base.appendingPathExtension("gpx"), c = base.appendingPathExtension("csv")
            if (try? gpx(trip.points).write(to: g, atomically: true, encoding: .utf8)) != nil { gpxURL = g }
            if (try? csv(trip.points).write(to: c, atomically: true, encoding: .utf8)) != nil { csvURL = c }
        }
    }
}

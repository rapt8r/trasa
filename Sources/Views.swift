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

/// UserDefaults keys shared by the screens.
enum Prefs {
    static let fuelPer100 = "fuelPer100"     // l / 100 km
    static let fuelPrice = "fuelPrice"       // zł / l
    static let speedLimits = "showSpeedLimits"
    static let traffic = "showTraffic"
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

struct SpeedLimitSign: View {
    let limit: Int

    var body: some View {
        Text("\(limit)")
            .font(.system(size: limit >= 100 ? 24 : 30, weight: .bold, design: .rounded))
            .foregroundStyle(.black)
            .frame(width: 66, height: 66)
            .background(Circle().fill(.white))
            .overlay(Circle().strokeBorder(.red, lineWidth: 7))
            .shadow(radius: 3)
            .accessibilityLabel("Ograniczenie prędkości \(limit) kilometrów na godzinę")
    }
}

// MARK: Map screen

struct RecordView: View {
    @EnvironmentObject var recorder: Recorder
    @StateObject private var road = RoadInfo()
    @AppStorage(Prefs.speedLimits) private var showSpeedLimits = true
    @AppStorage(Prefs.traffic) private var showTraffic = true
    @AppStorage(Prefs.fuelPer100) private var fuelPer100 = 7.0
    @AppStorage(Prefs.fuelPrice) private var fuelPrice = 6.5
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var follow = CameraState()
    @State private var recenter = false
    @State private var showTrips = false
    @State private var expanded = false

    var body: some View {
        let replayPoint: TrackPoint? = recorder.isReplaying ? recorder.live : nil
        Map(position: $camera) {
            if !recorder.isReplaying {
                UserAnnotation()
            }
            if let replayPoint {
                Annotation("Pozycja", coordinate: replayPoint.coordinate, anchor: .center) {
                    Image(systemName: "location.north.circle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(.white, .blue)
                        .rotationEffect(.degrees((replayPoint.course ?? follow.heading) - follow.heading))
                }
                .annotationTitles(.hidden)
            }
            if recorder.points.count > 1 {
                MapPolyline(coordinates: recorder.points.map(\.coordinate)).stroke(.blue, lineWidth: 6)
            }
        }
        .mapStyle(.standard(elevation: .realistic, showsTraffic: showTraffic))
        // A hidden copy of the collapsed panel reserves a constant strip at the bottom, so the map
        // never resizes. The visible panel is an overlay that grows upwards over the map.
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                streetLabel(" ")
                panel(expanded: false)
            }
            .hidden()
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: 8) {
                if let street = road.street {
                    streetLabel(street).accessibilityLabel("Ulica \(street)")
                }
                panel(expanded: expanded)
            }
        }
        .overlay(alignment: .topLeading) {
            if let limit = road.speedLimit {
                SpeedLimitSign(limit: limit).padding(12)
            }
        }
        .overlay(alignment: .topTrailing) { mapButtons }
        .onAppear { recorder.requestPermission() }
        .onChange(of: recorder.live?.t) {
            moveCamera(force: recenter)
            recenter = false
            if let p = recorder.live { road.update(p, limitsEnabled: showSpeedLimits) }
        }
        .onChange(of: recorder.isReplaying) {
            if recorder.isReplaying {
                showTrips = false
                recenter = true
            }
        }
        .sheet(isPresented: $showTrips) {
            TripListView()
                .environmentObject(recorder)
                .presentationDragIndicator(.visible)
        }
        .environment(\.colorScheme, .dark) // easier on the eyes at night in the car
    }

    /// Called once per position update. Each move is animated over the gap to the next update, so the
    /// map glides; the top-down <-> behind-the-marker change is spread over time by CameraState.
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
        withAnimation(.linear(duration: recorder.liveInterval)) { camera = .camera(target) }
    }

    private func streetLabel(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
    }

    private func roundButton(_ systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3)
                .frame(width: 48, height: 48)
                .background(.regularMaterial, in: Circle())
        }
        .accessibilityLabel(label)
    }

    private var mapButtons: some View {
        VStack(spacing: 12) {
            roundButton("list.bullet", label: "Trasy") { showTrips = true }
            if camera.positionedByUser {
                roundButton("location.fill", label: "Wróć do mojej pozycji") { moveCamera(force: true) }
            }
        }
        .padding(12)
    }

    private func panel(expanded: Bool) -> some View {
        let stats = TripStats(recorder.points)
        let live = recorder.live
        let speedText = String(format: "%.0f", (live?.speed ?? 0) * 3.6)
        let altitudeText: String = live.map { String(format: "%.0f m", $0.alt) } ?? "–"
        let courseText: String = live?.course.map { compass($0) } ?? "–"
        let accuracyText: String = live.map { String(format: "±%.0f m", $0.hAcc) } ?? "–"
        let fuel = fuelUsed(distance: stats.distance, per100: fuelPer100)
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
                    withAnimation(.snappy) { self.expanded.toggle() }
                } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.up")
                        .font(.headline)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(expanded ? "Zwiń szczegóły" : "Rozwiń szczegóły")
            }
            if expanded {
                VStack(spacing: 10) {
                    HStack {
                        Stat(title: "Maks.", value: formatKmh(stats.maxSpeed))
                        Stat(title: "Średnia", value: formatKmh(stats.avgSpeed))
                        Stat(title: "Paliwo", value: formatLitres(fuel))
                        Stat(title: "Koszt", value: formatCost(fuel * fuelPrice))
                    }
                    HStack {
                        Stat(title: "Wysokość", value: altitudeText)
                        Stat(title: "Kierunek", value: courseText)
                        Stat(title: "GPS", value: accuracyText)
                    }
                }
                .transition(.opacity)
            }
            if recorder.isReplaying {
                replayControls
            } else {
                recordControls
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
    }

    private var recordControls: some View {
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

    private var replayControls: some View {
        HStack(spacing: 12) {
            Image(systemName: "play.circle.fill")
                .font(.title2)
                .foregroundStyle(.blue)
                .accessibilityLabel("Odtwarzanie zapisanej trasy")
            Picker("Tempo odtwarzania", selection: $recorder.replayRate) {
                Text("1×").tag(1.0)
                Text("2×").tag(2.0)
                Text("5×").tag(5.0)
                Text("10×").tag(10.0)
            }
            .pickerStyle(.segmented)
            Button("Zakończ") { recorder.stopReplay() }
                .buttonStyle(.borderedProminent)
                .tint(.red)
        }
    }
}

// MARK: Trips

struct TripListView: View {
    @EnvironmentObject var recorder: Recorder
    @AppStorage(Prefs.fuelPer100) private var fuelPer100 = 7.0
    @AppStorage(Prefs.fuelPrice) private var fuelPrice = 6.5

    var body: some View {
        let distance = recorder.trips.reduce(0.0) { $0 + $1.stats.distance }
        let duration = recorder.trips.reduce(0.0) { $0 + $1.stats.duration }
        let cost = fuelUsed(distance: distance, per100: fuelPer100) * fuelPrice
        NavigationStack {
            List {
                if !recorder.trips.isEmpty {
                    HStack {
                        Stat(title: "Trasy", value: "\(recorder.trips.count)")
                        Stat(title: "Łącznie", value: formatKm(distance))
                        Stat(title: "Czas", value: formatDuration(duration))
                        Stat(title: "Koszt", value: formatCost(cost))
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
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Ustawienia")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        StatsView()
                    } label: {
                        Image(systemName: "chart.bar")
                    }
                    .accessibilityLabel("Statystyki")
                }
            }
            .overlay {
                if recorder.trips.isEmpty {
                    ContentUnavailableView("Brak tras", systemImage: "car", description: Text("Nagraj pierwszą trasę przyciskiem Start na mapie."))
                }
            }
        }
    }
}

struct StatsView: View {
    @EnvironmentObject var recorder: Recorder
    @AppStorage(Prefs.fuelPer100) private var fuelPer100 = 7.0
    @AppStorage(Prefs.fuelPrice) private var fuelPrice = 6.5
    @State private var weekly = false

    var body: some View {
        let unit: Calendar.Component = weekly ? .weekOfYear : .month
        let periods: [PeriodSummary] = summarize(recorder.trips, by: unit)
        let recent: [PeriodSummary] = Array(periods.prefix(12).reversed())
        List {
            Picker("Okres", selection: $weekly) {
                Text("Miesiące").tag(false)
                Text("Tygodnie").tag(true)
            }
            .pickerStyle(.segmented)
            if !recent.isEmpty {
                Chart(recent) { period in
                    BarMark(x: .value("Okres", period.start, unit: unit),
                            y: .value("km", period.distance / 1000))
                }
                .frame(height: 180)
                .accessibilityLabel("Kilometry w kolejnych okresach")
            }
            ForEach(periods) { period in
                VStack(alignment: .leading, spacing: 2) {
                    Text(title(period.start)).font(.headline)
                    Text(summary(period))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Statystyki")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if periods.isEmpty {
                ContentUnavailableView("Brak danych", systemImage: "chart.bar", description: Text("Statystyki pojawią się po pierwszej nagranej trasie."))
            }
        }
    }

    private func title(_ start: Date) -> String {
        weekly
            ? "Tydzień od " + start.formatted(.dateTime.day().month(.abbreviated).year())
            : start.formatted(.dateTime.month(.wide).year())
    }

    private func summary(_ period: PeriodSummary) -> String {
        let cost = fuelUsed(distance: period.distance, per100: fuelPer100) * fuelPrice
        return "Przejazdy: \(period.count) · \(formatKm(period.distance)) · \(formatDuration(period.duration)) · \(formatCost(cost))"
    }
}

struct SettingsView: View {
    @AppStorage(Prefs.fuelPer100) private var fuelPer100 = 7.0
    @AppStorage(Prefs.fuelPrice) private var fuelPrice = 6.5
    @AppStorage(Prefs.speedLimits) private var showSpeedLimits = true
    @AppStorage(Prefs.traffic) private var showTraffic = true

    var body: some View {
        Form {
            Section {
                LabeledContent("Spalanie (l/100 km)") {
                    TextField("7", value: $fuelPer100, format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Cena paliwa (zł/l)") {
                    TextField("6,50", value: $fuelPrice, format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }
            } header: {
                Text("Paliwo")
            } footer: {
                Text("Koszt przejazdu to szacunek: dystans × spalanie × cena.")
            }
            Section {
                Toggle("Znaki ograniczeń prędkości", isOn: $showSpeedLimits)
            } footer: {
                Text("Źródło: OpenStreetMap. Aplikacja pobiera całe kwadraty mapy (ok. 2 × 3 km) i trzyma je w telefonie, więc serwer zna tylko przybliżoną okolicę, nie Twoją trasę.")
            }
            Section {
                Toggle("Natężenie ruchu", isOn: $showTraffic)
            } footer: {
                Text("Ruch i nazwy ulic pochodzą z Map Apple.")
            }
        }
        .navigationTitle("Ustawienia")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct TripDetailView: View {
    let trip: Trip
    @EnvironmentObject var recorder: Recorder
    @AppStorage(Prefs.fuelPer100) private var fuelPer100 = 7.0
    @AppStorage(Prefs.fuelPrice) private var fuelPrice = 6.5
    @State private var gpxURL: URL?
    @State private var csvURL: URL?
    @State private var satellite = false

    var body: some View {
        let s = trip.stats
        let chunks = speedChunks(trip.points)
        let fuel = fuelUsed(distance: s.distance, per100: fuelPer100)
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
                            .frame(width: 44, height: 44)
                            .background(.regularMaterial, in: Circle())
                    }
                    .accessibilityLabel(satellite ? "Mapa" : "Satelita")
                    .padding(8)
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))

                Text("Kolor trasy: zielony – wolno, czerwony – szybko")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    recorder.startReplay(trip)
                } label: {
                    Label("Odtwórz przejazd na mapie", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.bordered)
                .disabled(recorder.isRecording)

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
                        Stat(title: "Paliwo (szac.)", value: formatLitres(fuel))
                        Stat(title: "Koszt (szac.)", value: formatCost(fuel * fuelPrice))
                        Stat(title: "Koszt 100 km", value: formatCost(fuelPer100 * fuelPrice))
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

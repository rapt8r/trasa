import SwiftUI
import MapKit
import Charts

@main
struct TrasaApp: App {
    @StateObject private var recorder = Recorder()

    var body: some Scene {
        WindowGroup {
            RecordView()
                .environmentObject(recorder)
                .preferredColorScheme(.dark) // a dashboard: dark at all times, easier on the eyes at night
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

/// Screens pushed inside the bottom sheet.
enum Route: Hashable {
    case trip(URL)
    case stats
    case settings
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
            .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
            .accessibilityLabel("Ograniczenie prędkości \(limit) kilometrów na godzinę")
    }
}

/// Position marker in the style of Maps navigation: a blue arrow on a white disc.
struct Puck: View {
    var body: some View {
        ZStack {
            Circle().fill(.blue.opacity(0.18)).frame(width: 74, height: 74)
            Circle()
                .fill(.white)
                .frame(width: 46, height: 46)
                .shadow(color: .black.opacity(0.35), radius: 5, y: 2)
            Image(systemName: "location.north.fill")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.blue)
        }
    }
}

// MARK: Map screen

struct RecordView: View {
    @EnvironmentObject var recorder: Recorder
    @StateObject private var road = RoadInfo()
    // Not observed here on purpose: it changes every frame, and only MapLayer needs to redraw then.
    @State private var motion = Motion()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(Prefs.speedLimits) private var useRoadData = true
    @State private var detent = DriveSheet.compactDetent
    @State private var path: [Route] = []
    @State private var recenterRequests = 0

    var body: some View {
        MapLayer(motion: motion, recenterRequests: recenterRequests)
            .overlay(alignment: .topLeading) {
                if let limit = road.speedLimit {
                    SpeedLimitSign(limit: limit).padding(12)
                }
            }
            .onAppear {
                recorder.requestPermission()
                motion.setRunning(true)
            }
            .onChange(of: scenePhase) { motion.setRunning(scenePhase == .active) }
            .onChange(of: recorder.live?.t) {
                guard let p = recorder.live else {
                    motion.feed(nil)
                    return
                }
                road.update(p, limitsEnabled: useRoadData)
                motion.feed(useRoadData ? road.snapped(p) : p)
            }
            .onChange(of: recorder.replayRate) { motion.rate = recorder.isReplaying ? recorder.replayRate : 1 }
            .onChange(of: recorder.isReplaying) {
                motion.rate = recorder.isReplaying ? recorder.replayRate : 1
                if recorder.isReplaying {
                    path = []
                    detent = DriveSheet.compactDetent
                    recenterRequests += 1
                }
            }
            .sheet(isPresented: .constant(true)) {
                DriveSheet(detent: $detent, path: $path, street: road.street)
                    .environmentObject(recorder)
                    .presentationDetents([DriveSheet.compactDetent, .medium, .large], selection: $detent)
                    .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                    .presentationDragIndicator(.visible)
                    .presentationBackground(.regularMaterial)
                    .interactiveDismissDisabled()
                    .preferredColorScheme(.dark)
            }
    }
}

/// The map, the marker and the follow camera. Redraws every frame while the car moves, so it is
/// kept apart from the sheet and the rest of the screen.
struct MapLayer: View {
    @ObservedObject var motion: Motion
    /// Bumped by the parent to make the camera follow the car again.
    let recenterRequests: Int
    @EnvironmentObject var recorder: Recorder
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(Prefs.traffic) private var showTraffic = true
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var follow = CameraState()
    @State private var recenter = false

    var body: some View {
        Map(position: $camera) {
            if let p = motion.point {
                Annotation("Twoja pozycja", coordinate: p.coordinate, anchor: .center) {
                    Puck().rotationEffect(.degrees((p.course ?? follow.heading) - follow.heading))
                }
                .annotationTitles(.hidden)
            }
            if motion.point == nil {
                UserAnnotation()
            }
            if recorder.points.count > 1 {
                MapPolyline(coordinates: recorder.points.map(\.coordinate)).stroke(.blue, lineWidth: 8)
            }
        }
        // No points of interest: while driving, shops and restaurants are clutter.
        .mapStyle(.standard(elevation: .realistic, pointsOfInterest: .excludingAll, showsTraffic: showTraffic))
        // The sheet's resting height never changes, so the map is laid out once and never resizes.
        .safeAreaPadding(.bottom, DriveSheet.compactHeight)
        .overlay(alignment: .bottomTrailing) {
            if camera.positionedByUser {
                Button {
                    moveCamera(force: true)
                } label: {
                    Image(systemName: "location.fill")
                        .font(.title3)
                        .frame(width: 48, height: 48)
                        .background(.regularMaterial, in: Circle())
                        .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
                }
                .accessibilityLabel("Wróć do mojej pozycji")
                .padding(.trailing, 12)
                .padding(.bottom, DriveSheet.compactHeight + 12)
            }
        }
        .onChange(of: motion.point?.t) { moveCamera() }
        .onChange(of: recenterRequests) { recenter = true }
    }

    /// Called for every frame Motion produces; marker and camera move together, so nothing jitters.
    private func moveCamera(force: Bool = false) {
        guard let p = motion.point else { return }
        follow.update(p)
        // The user dragged the map: leave it alone until they tap the recenter button.
        guard force || recenter || !camera.positionedByUser else { return }
        recenter = false
        // Reduce Motion: keep following, but flat and north-up, without tilting or rotating the map.
        let spec = reduceMotion
            ? CameraSpec(lat: p.lat, lon: p.lon, distance: cameraOverheadDistance, heading: 0, pitch: 0)
            : follow.spec(for: p)
        camera = .camera(MapCamera(centerCoordinate: CLLocationCoordinate2D(latitude: spec.lat, longitude: spec.lon),
                                   distance: spec.distance,
                                   heading: spec.heading,
                                   pitch: spec.pitch))
    }
}

// MARK: Bottom sheet

/// One resizable sheet, as in Maps: speed and controls at rest, trip details at half height,
/// saved trips, statistics and settings at full height.
struct DriveSheet: View {
    // ponytail: fixed resting height; measure the content instead if the largest text sizes clip it.
    static let compactHeight: CGFloat = 190
    /// Height of the home-indicator strip under the resting sheet; the list must start below it,
    /// or its first rows peek out under the controls.
    static let homeIndicatorStrip: CGFloat = 40
    static let compactDetent = PresentationDetent.height(compactHeight)

    @EnvironmentObject var recorder: Recorder
    @Binding var detent: PresentationDetent
    @Binding var path: [Route]
    let street: String?
    @AppStorage(Prefs.fuelPer100) private var fuelPer100 = 7.0
    @AppStorage(Prefs.fuelPrice) private var fuelPrice = 6.5

    var body: some View {
        let stats = TripStats(recorder.points)
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                hud(stats)
                    .padding(.horizontal, 20)
                    .padding(.top, 24)
                    .frame(height: Self.compactHeight + Self.homeIndicatorStrip, alignment: .top)
                List {
                    currentTrip(stats)
                    savedTrips
                    Section {
                        NavigationLink(value: Route.stats) { Label("Statystyki", systemImage: "chart.bar") }
                        NavigationLink(value: Route.settings) { Label("Ustawienia", systemImage: "gearshape") }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .contentMargins(.top, 0, for: .scrollContent)
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Route.self) { route in
                destination(route)
            }
        }
        .onChange(of: path) {
            if !path.isEmpty { detent = .large }
        }
    }

    @ViewBuilder
    private func destination(_ route: Route) -> some View {
        switch route {
        case .trip(let url):
            if let trip = recorder.trips.first(where: { $0.url == url }) {
                TripDetailView(trip: trip)
            } else {
                ContentUnavailableView("Trasa usunięta", systemImage: "trash")
            }
        case .stats:
            StatsView()
        case .settings:
            SettingsView()
        }
    }

    private var statusTitle: String {
        if let street { return street }
        if recorder.isReplaying { return "Odtwarzanie" }
        return recorder.isRecording ? "Nagrywanie" : "Gotowy do jazdy"
    }

    /// Speedometer on the left, where you are and how far you have driven next to it, controls below.
    private func hud(_ stats: TripStats) -> some View {
        let progress = "\(formatKm(stats.distance)) · \(formatDuration(stats.duration))"
        return VStack(spacing: 14) {
            HStack(alignment: .center, spacing: 16) {
                VStack(spacing: -2) {
                    Text(String(format: "%.0f", (recorder.live?.speed ?? 0) * 3.6))
                        .font(.system(size: 60, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("km/h").font(.footnote.weight(.medium)).foregroundStyle(.secondary)
                }
                .frame(minWidth: 100)
                .accessibilityElement(children: .combine)
                VStack(alignment: .leading, spacing: 4) {
                    Text(statusTitle)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Text(recorder.isPaused ? "Pauza · " + progress : progress)
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(recorder.isPaused ? Color.orange : Color.secondary)
                }
                Spacer(minLength: 0)
            }
            if recorder.denied {
                Text("Brak dostępu do lokalizacji. Włącz go w Ustawieniach.")
                    .font(.footnote)
                    .foregroundStyle(.red)
            } else if let error = recorder.error {
                Text(error).font(.footnote).foregroundStyle(.red)
            } else if recorder.isReplaying {
                replayControls
            } else {
                recordControls
            }
        }
    }

    private func bigButton(_ title: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.headline).frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .tint(tint)
    }

    private var recordControls: some View {
        HStack(spacing: 12) {
            if recorder.isRecording {
                bigButton(recorder.isPaused ? "Wznów" : "Pauza", tint: .orange) {
                    if recorder.isPaused { recorder.resume() } else { recorder.pause() }
                }
                bigButton("Stop", tint: .red) { recorder.stop() }
            } else {
                bigButton("Start", tint: .green) { recorder.start() }
            }
        }
    }

    private var replayControls: some View {
        HStack(spacing: 8) {
            ForEach([1.0, 2.0, 5.0, 10.0], id: \.self) { rate in
                let selected = recorder.replayRate == rate
                Button {
                    recorder.replayRate = rate
                } label: {
                    Text("\(Int(rate))×")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(selected ? Color.blue : Color.white.opacity(0.12), in: Capsule())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Tempo \(Int(rate)) razy")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            Button {
                recorder.stopReplay()
            } label: {
                Text("Zakończ").font(.headline)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .tint(.red)
        }
    }

    private func currentTrip(_ stats: TripStats) -> some View {
        let live = recorder.live
        let fuel = fuelUsed(distance: stats.distance, per100: fuelPer100)
        let altitudeText: String = live.map { String(format: "%.0f m", $0.alt) } ?? "–"
        let courseText: String = live?.course.map { compass($0) } ?? "–"
        let accuracyText: String = live.map { String(format: "±%.0f m", $0.hAcc) } ?? "–"
        return Section(recorder.isReplaying ? "Odtwarzany przejazd" : "Ten przejazd") {
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
    }

    private var savedTrips: some View {
        let distance = recorder.trips.reduce(0.0) { $0 + $1.stats.distance }
        let duration = recorder.trips.reduce(0.0) { $0 + $1.stats.duration }
        let cost = fuelUsed(distance: distance, per100: fuelPer100) * fuelPrice
        return Section("Zapisane trasy") {
            if recorder.trips.isEmpty {
                Text("Nagraj pierwszą trasę przyciskiem Start.").foregroundStyle(.secondary)
            } else {
                HStack {
                    Stat(title: "Trasy", value: "\(recorder.trips.count)")
                    Stat(title: "Łącznie", value: formatKm(distance))
                    Stat(title: "Czas", value: formatDuration(duration))
                    Stat(title: "Koszt", value: formatCost(cost))
                }
            }
            ForEach(recorder.trips) { trip in
                NavigationLink(value: Route.trip(trip.url)) {
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
                Toggle("Dane o drogach", isOn: $showSpeedLimits)
            } footer: {
                Text("Znaki ograniczeń prędkości i przyciąganie pozycji do drogi. Źródło: OpenStreetMap. Aplikacja pobiera całe kwadraty mapy (ok. 2 × 3 km) i trzyma je w telefonie, więc serwer zna tylko przybliżoną okolicę, nie Twoją trasę.")
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

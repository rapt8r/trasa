import SwiftUI
import MapKit
import Charts

@main
struct TrasaApp: App {
    @StateObject private var recorder = Recorder()
    // Held, not observed: only the car screen redraws when car values change.
    @State private var obd = OBDAdapter()

    var body: some Scene {
        WindowGroup {
            RecordView(obd: obd).environmentObject(recorder)
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
    case car
    case carLog
}

/// "Dziś, 18:12", "Wczoraj, 18:12", otherwise the date and time.
func tripDateTitle(_ date: Date) -> String {
    let time = date.formatted(date: .omitted, time: .shortened)
    if Calendar.current.isDateInToday(date) { return "Dziś, " + time }
    if Calendar.current.isDateInYesterday(date) { return "Wczoraj, " + time }
    return date.formatted(.dateTime.day().month(.wide)) + ", " + time
}

/// A titled group of numbers or a chart, as in Health and Fitness.
struct Card<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct Stat: View {
    let title: String
    let value: String

    var body: some View {
        VStack(spacing: 2) {
            // Four tiles share a row on a narrow phone: shrink a little before truncating.
            Text(value).font(.headline).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// Its own view, so only this number redraws when the accelerometer reading changes.
struct GStat: View {
    @ObservedObject var meter: GMeter

    var body: some View {
        Stat(title: "Siła G", value: String(format: "%.2f g", locale: Locale.current, meter.value))
    }
}

/// A short message about the drive: no fix yet, weak signal, recording paused.
struct Notice: Equatable {
    let icon: String
    let text: String
}

/// Slides out from under the sheet's top edge; said with a symbol and words, not colour alone.
struct NoticePill: View {
    let notice: Notice

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: notice.icon).foregroundStyle(.orange)
            Text(notice.text).font(.subheadline.weight(.semibold))
        }
        .padding(.horizontal, 16)
        .frame(height: 38)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.3), radius: 4, y: 1)
        .accessibilityElement(children: .combine)
    }
}

struct SpeedLimitSign: View {
    let limit: Int
    var exceeded = false

    var body: some View {
        Text("\(limit)")
            .font(.system(size: limit >= 100 ? 24 : 30, weight: .bold, design: .rounded))
            .foregroundStyle(.black)
            .frame(width: 66, height: 66)
            .background(Circle().fill(.white))
            .overlay(Circle().strokeBorder(.red, lineWidth: 7))
            .shadow(color: exceeded ? Color.red.opacity(0.8) : Color.black.opacity(0.35), radius: exceeded ? 10 : 4, y: 2)
            .scaleEffect(exceeded ? 1.2 : 1, anchor: .topLeading)
            .animation(.easeInOut(duration: 0.3), value: exceeded)
            .accessibilityLabel(exceeded
                ? "Przekroczone ograniczenie prędkości \(limit) kilometrów na godzinę"
                : "Ograniczenie prędkości \(limit) kilometrów na godzinę")
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
    let obd: OBDAdapter
    @EnvironmentObject var recorder: Recorder
    @StateObject private var road = RoadInfo()
    // Not observed here on purpose: it changes every frame, and only MapLayer needs to redraw then.
    @State private var motion = Motion()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(Prefs.speedLimits) private var useRoadData = true
    @State private var detent = DriveSheet.compactDetent
    @State private var path: [Route] = []
    @State private var recenterRequests = 0
    /// Dark where the car is: the sun is down there. Otherwise the phone's own appearance is used.
    @State private var night = false
    @State private var gps = GPSStatus.good
    // When GPS goes quiet nothing else would notice, so the fix's age is checked on a timer.
    private let statusTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    /// The one message worth showing right now, most urgent first.
    private var notice: Notice? {
        if recorder.denied { return nil } // the sheet explains that one and offers Settings
        if !recorder.isReplaying {
            switch gps {
            case .searching: return Notice(icon: "location.slash.fill", text: "Szukam sygnału GPS")
            case .weak: return Notice(icon: "exclamationmark.triangle.fill", text: "Słaby sygnał GPS")
            case .good: break
            }
        }
        if recorder.isPaused { return Notice(icon: "pause.fill", text: "Nagrywanie wstrzymane") }
        return nil
    }

    private func refreshGPS() {
        let now = recorder.isReplaying ? GPSStatus.good : gpsStatus(fix: recorder.live, now: Date())
        if now != gps { gps = now }
    }

    var body: some View {
        let over = road.speedLimit.map { isOverLimit(speed: recorder.live?.speed, limit: $0) } ?? false
        let notice = self.notice
        MapLayer(motion: motion, recenterRequests: recenterRequests, lifted: notice != nil)
            .overlay(alignment: .bottom) {
                if let notice {
                    NoticePill(notice: notice)
                        .padding(.bottom, DriveSheet.compactHeight + 10)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.spring(duration: 0.45), value: notice)
            .onReceive(statusTimer) { _ in refreshGPS() }
            .overlay(alignment: .topLeading) {
                if let limit = road.speedLimit {
                    SpeedLimitSign(limit: limit, exceeded: over).padding(12)
                }
            }
            // Short taps for discrete events only: recording started or stopped, paused, limit crossed.
            .sensoryFeedback(.impact(weight: .medium), trigger: recorder.isRecording)
            .sensoryFeedback(.impact(weight: .light), trigger: recorder.isPaused)
            .sensoryFeedback(trigger: over) { _, isOver in isOver ? .warning : nil }
            .preferredColorScheme(night ? .dark : nil)
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
                let dark = isNight(lat: p.lat, lon: p.lon, date: p.t)
                if dark != night { night = dark }
                refreshGPS()
            }
            .onChange(of: recorder.replayRate) { motion.rate = recorder.isReplaying ? recorder.replayRate : 1 }
            .onChange(of: recorder.isReplaying) {
                motion.rate = recorder.isReplaying ? recorder.replayRate : 1
                motion.useSensors = !recorder.isReplaying
                if recorder.isReplaying {
                    path = []
                    detent = DriveSheet.compactDetent
                    recenterRequests += 1
                }
            }
            .sheet(isPresented: .constant(true)) {
                DriveSheet(detent: $detent, path: $path, street: road.street, speedLimit: road.speedLimit, gMeter: motion.gMeter)
                    .environmentObject(recorder)
                    .environmentObject(obd)
                    .presentationDetents([DriveSheet.compactDetent, .medium, .large], selection: $detent)
                    .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                    .presentationDragIndicator(.visible)
                    .presentationBackground(.regularMaterial)
                    .interactiveDismissDisabled()
                    .preferredColorScheme(night ? .dark : nil)
            }
    }
}

/// The map, the marker and the follow camera. Redraws every frame while the car moves, so it is
/// kept apart from the sheet and the rest of the screen.
struct MapLayer: View {
    @ObservedObject var motion: Motion
    /// Bumped by the parent to make the camera follow the car again.
    let recenterRequests: Int
    /// A notice sits just above the sheet: keep the marker clear of it.
    let lifted: Bool
    @EnvironmentObject var recorder: Recorder
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(Prefs.traffic) private var showTraffic = true
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var follow = CameraState()
    @State private var recenter = false
    @State private var lift = 0.0

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
        lift += ((lifted ? 1 : 0) - lift) * 0.08 // eased a little every frame
        // Reduce Motion: keep following, but flat and north-up, without tilting or rotating the map.
        let spec = reduceMotion
            ? CameraSpec(lat: p.lat, lon: p.lon, distance: cameraOverheadDistance, heading: 0, pitch: 0)
            : follow.spec(for: p, lift: lift)
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
    static let compactDetent = PresentationDetent.height(compactHeight)

    @EnvironmentObject var recorder: Recorder
    @Binding var detent: PresentationDetent
    @Binding var path: [Route]
    let street: String?
    let speedLimit: Int?
    let gMeter: GMeter
    @AppStorage(Prefs.fuelPer100) private var fuelPer100 = 7.0
    @AppStorage(Prefs.fuelPrice) private var fuelPrice = 6.5

    var body: some View {
        let stats = TripStats(recorder.points)
        NavigationStack(path: $path) {
            GeometryReader { geo in
                // As in Maps: what sits below the controls is hidden at rest and fades in as the sheet
                // is pulled up, so nothing peeks out under the buttons and no gap is left above the list.
                let rising = min(1, max(0, (geo.size.height - Self.compactHeight - 20) / 90))
                let reveal = detent == Self.compactDetent ? 0 : rising
                VStack(spacing: 0) {
                    hud(stats)
                        .padding(.horizontal, 20)
                        .padding(.top, 24)
                        .padding(.bottom, 4)
                    List {
                        currentTrip(stats)
                        savedTrips
                        Section {
                            NavigationLink(value: Route.car) { Label("Samochód", systemImage: "car.side.fill") }
                            NavigationLink(value: Route.stats) { Label("Statystyki", systemImage: "chart.bar.fill") }
                            NavigationLink(value: Route.settings) { Label("Ustawienia", systemImage: "gearshape.fill") }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .listSectionSpacing(.compact)
                    .scrollContentBackground(.hidden)
                    .contentMargins(.top, 8, for: .scrollContent)
                    .opacity(reveal)
                    .allowsHitTesting(reveal > 0.5)
                    .animation(.easeInOut(duration: 0.2), value: reveal)
                }
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
        case .car:
            CarView()
        case .carLog:
            CarLogView()
        }
    }

    private var statusTitle: String {
        if let street { return street }
        if recorder.isReplaying { return "Odtwarzanie" }
        return recorder.isRecording ? "Nagrywanie" : "Gotowy do jazdy"
    }

    /// Speedometer on the left, where you are and how far you have driven next to it, controls below.
    private func hud(_ stats: TripStats) -> some View {
        let over = speedLimit.map { isOverLimit(speed: recorder.live?.speed, limit: $0) } ?? false
        return VStack(spacing: 14) {
            HStack(alignment: .center, spacing: 16) {
                VStack(spacing: -2) {
                    Text(String(format: "%.0f", (recorder.live?.speed ?? 0) * 3.6))
                        .font(.system(size: 60, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(over ? Color.red : Color.primary) // the sign also grows: not colour alone
                    Text("km/h").font(.footnote.weight(.medium)).foregroundStyle(.secondary)
                }
                .frame(minWidth: 100)
                .accessibilityElement(children: .combine)
                VStack(alignment: .leading, spacing: 6) {
                    // A short name is set large; a long one shrinks to fit instead of being cut off.
                    Text(statusTitle)
                        .font(.title.weight(.bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.55)
                    HStack(alignment: .firstTextBaseline, spacing: 18) {
                        Text(formatKm(stats.distance)).accessibilityLabel("Dystans \(formatKm(stats.distance))")
                        Text(formatDuration(stats.duration)).accessibilityLabel("Czas \(formatDuration(stats.duration))")
                    }
                    .font(.title3.weight(.medium))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                }
                Spacer(minLength: 0)
            }
            if recorder.denied {
                HStack(spacing: 12) {
                    Text("Journey potrzebuje dostępu do lokalizacji, żeby pokazać i nagrać trasę.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("Otwórz Ustawienia") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                }
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
                bigButton("Stop", tint: .red) {
                    if let saved = recorder.stop() { path = [.trip(saved)] }
                }
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
                        .frame(height: 50)
                        .background(selected ? Color.blue : Color.primary.opacity(0.1), in: Capsule())
                        .foregroundStyle(selected ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Tempo \(Int(rate)) razy")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            Button {
                recorder.stopReplay()
            } label: {
                Text("Zakończ")
                    .font(.headline)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 18)
                    .frame(height: 50)
                    .background(Color.red, in: Capsule())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .layoutPriority(1)
        }
    }

    @ViewBuilder
    private func currentTrip(_ stats: TripStats) -> some View {
        let live = recorder.live
        let altitudeText: String = live.map { String(format: "%.0f m", $0.alt) } ?? "–"
        let courseText: String = live?.course.map { compass($0) } ?? "–"
        let accuracyText: String = live.map { String(format: "±%.0f m", $0.hAcc) } ?? "–"
        if recorder.isRecording || recorder.isReplaying {
            let fuel = fuelUsed(distance: stats.distance, per100: fuelPer100)
            Section(recorder.isReplaying ? "Odtwarzany przejazd" : "Ten przejazd") {
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
                    GStat(meter: gMeter)
                }
            }
        } else {
            Section("Teraz") {
                HStack {
                    Stat(title: "Wysokość", value: altitudeText)
                    Stat(title: "Kierunek", value: courseText)
                    Stat(title: "GPS", value: accuracyText)
                    GStat(meter: gMeter)
                }
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
                    HStack(spacing: 12) {
                        Image(systemName: "car.fill")
                            .font(.subheadline)
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(Color.blue, in: Circle())
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tripDateTitle(trip.start)).font(.headline)
                            Text("\(formatKm(trip.stats.distance)) · \(formatShortDuration(trip.stats.duration)) · śr. \(formatKmh(trip.stats.avgSpeed))")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
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
        let barWidth: MarkDimension = recent.count < 6 ? .fixed(34) : .ratio(0.6)
        List {
            Section {
                Picker("Okres", selection: $weekly) {
                    Text("Miesiące").tag(false)
                    Text("Tygodnie").tag(true)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            if let latest = periods.first {
                Section {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title(latest.start).uppercased())
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(String(format: "%.1f", locale: Locale.current, latest.distance / 1000))
                                .font(.system(size: 40, weight: .bold, design: .rounded))
                                .monospacedDigit()
                            Text("km").font(.title3.weight(.semibold)).foregroundStyle(.secondary)
                        }
                        Text(summary(latest))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    Chart(recent) { period in
                        BarMark(x: .value("Okres", label(period.start)),
                                y: .value("km", period.distance / 1000),
                                width: barWidth)
                            .foregroundStyle(period.start == latest.start ? Color.blue : Color.blue.opacity(0.45))
                            .cornerRadius(5)
                    }
                    .chartYAxisLabel("km")
                    .frame(height: 170)
                    .padding(.vertical, 6)
                    .accessibilityLabel("Kilometry w kolejnych okresach")
                }
                Section(weekly ? "Tygodnie" : "Miesiące") {
                    ForEach(periods) { period in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title(period.start)).font(.headline)
                            Text(summary(period))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .listSectionSpacing(.compact)
        .contentMargins(.top, 8, for: .scrollContent)
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
            ? "Tydzień od " + start.formatted(.dateTime.day().month(.wide))
            : start.formatted(.dateTime.month(.wide).year())
    }

    /// Short axis label: "lis" for a month, "17 lis" for a week.
    private func label(_ start: Date) -> String {
        weekly
            ? start.formatted(.dateTime.day().month(.abbreviated))
            : start.formatted(.dateTime.month(.abbreviated))
    }

    private func summary(_ period: PeriodSummary) -> String {
        let cost = fuelUsed(distance: period.distance, per100: fuelPer100) * fuelPrice
        return "\(tripsLabel(period.count)) · \(formatShortDuration(period.duration)) · \(formatCost(cost))"
    }
}

// MARK: Car (OBD adapter)

/// Finds the OBD adapter, shows what the car reports and its live values. Read-only.
struct CarView: View {
    @EnvironmentObject var obd: OBDAdapter

    var body: some View {
        List {
            Section {
                status
                switch obd.state {
                case .idle, .failed, .bluetoothOff, .unauthorized:
                    Button("Szukaj adaptera") { obd.startScan() }
                case .scanning, .connecting, .reading, .ready:
                    Button("Rozłącz", role: .destructive) { obd.disconnect() }
                }
            } footer: {
                Text("Włóż adapter w gniazdo OBD pod kierownicą i włącz zapłon. Journey tylko odczytuje dane, niczego w aucie nie zmienia.")
            }

            if obd.state == .scanning {
                Section {
                    if obd.devices.isEmpty {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Szukam…").foregroundStyle(.secondary)
                        }
                    }
                    ForEach(obd.devices) { device in
                        Button {
                            obd.connect(device)
                        } label: {
                            HStack {
                                Image(systemName: device.likely ? "car.side.fill" : "dot.radiowaves.left.and.right")
                                    .foregroundStyle(device.likely ? Color.blue : Color.secondary)
                                    .frame(width: 28)
                                    .accessibilityHidden(true)
                                Text(device.name).foregroundStyle(Color.primary)
                                Spacer()
                                if device.likely {
                                    Text("adapter OBD").font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Urządzenia w pobliżu")
                } footer: {
                    Text("Adapter Vgate zwykle nazywa się „IOS-Vlink”. Jeśli po minucie go tu nie ma, może to być wersja Bluetooth 3.0, która nie działa z iPhonem.")
                }
            }

            if !obd.info.isEmpty {
                Section("Adapter i auto") {
                    ForEach(obd.info) { row in
                        LabeledContent(row.label, value: row.value)
                    }
                }
            }

            if !obd.readings.isEmpty {
                Section {
                    ForEach(obd.readings) { reading in
                        readingRow(reading)
                    }
                } header: {
                    Text("Parametry z auta (\(obd.readings.count))")
                } footer: {
                    if obd.rate > 0 {
                        Text("Odczyt: \(String(format: "%.0f", obd.rate)) wartości na sekundę.")
                    }
                }
            }

            Section {
                NavigationLink(value: Route.carLog) { Label("Dziennik połączenia", systemImage: "doc.text") }
            } footer: {
                Text("Dziennik pokazuje rozmowę z adapterem. Wyślij go, jeśli coś nie działa.")
            }
        }
        .listSectionSpacing(.compact)
        .contentMargins(.top, 8, for: .scrollContent)
        .navigationTitle("Samochód")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var status: some View {
        switch obd.state {
        case .idle:
            Label("Nie połączono", systemImage: "car.side")
        case .bluetoothOff:
            Label("Bluetooth jest wyłączony. Włącz go w Centrum sterowania.", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .unauthorized:
            VStack(alignment: .leading, spacing: 8) {
                Label("Journey nie ma dostępu do Bluetooth.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Button("Otwórz Ustawienia") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            }
        case .scanning:
            Label("Szukam adaptera", systemImage: "dot.radiowaves.left.and.right")
        case .connecting(let name):
            HStack(spacing: 12) {
                ProgressView()
                Text("Łączę z \(name)…")
            }
        case .reading(let what):
            HStack(spacing: 12) {
                ProgressView()
                Text(what)
            }
        case .ready:
            Label("Połączono z autem", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    private func readingRow(_ reading: OBDAdapter.Reading) -> some View {
        let parameter = obdParameters[reading.pid]
        let name = parameter?.name ?? String(format: "Parametr 0x%02X", reading.pid)
        var text = "–"
        if let parameter, let value = parameter.decode(reading.data) {
            let number = String(format: "%.\(parameter.digits)f", locale: Locale.current, value)
            text = parameter.unit.isEmpty ? number : number + " " + parameter.unit
        } else if !reading.data.isEmpty {
            text = hexString(reading.data) // not decoded by this version: shown as the car sent it
        }
        return LabeledContent(name) {
            Text(text).monospacedDigit()
        }
    }
}

struct CarLogView: View {
    @EnvironmentObject var obd: OBDAdapter

    var body: some View {
        // The log is not observed (it changes with every command), so it is re-read on a timer.
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            ScrollView {
                Text(obd.logText.isEmpty ? "Dziennik jest pusty. Połącz się z adapterem." : obd.logText)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        }
        .navigationTitle("Dziennik połączenia")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: obd.logText) {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("Wyślij dziennik")
            }
        }
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

    private static func speedColor(_ fraction: Double) -> Color {
        Color(hue: 0.33 * (1 - fraction), saturation: 0.9, brightness: 0.85)
    }

    /// The whole route with room around it, so the start and end pins are never cut off.
    private var routeFrame: MapCameraPosition {
        guard let first = trip.points.first else { return .automatic }
        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
        for p in trip.points {
            let m = MKMapPoint(p.coordinate)
            minX = min(minX, m.x); maxX = max(maxX, m.x)
            minY = min(minY, m.y); maxY = max(maxY, m.y)
        }
        let margin = max(maxX - minX, maxY - minY) * 0.25 + MKMapPointsPerMeterAtLatitude(first.lat) * 150
        return .rect(MKMapRect(x: minX - margin, y: minY - margin * 1.6, // extra room on top for the pins
                               width: maxX - minX + margin * 2, height: maxY - minY + margin * 2.6))
    }

    var body: some View {
        let s = trip.stats
        let chunks = speedChunks(trip.points)
        let fuel = fuelUsed(distance: s.distance, per100: fuelPer100)
        let end = trip.points.last?.t ?? trip.start
        // Chart gets at most ~300 samples; the map and the files keep every point.
        let samples = stride(from: 0, to: trip.points.count, by: max(1, trip.points.count / 300)).map { trip.points[$0] }
        ScrollView {
            VStack(spacing: 14) {
                Map(initialPosition: routeFrame) {
                    ForEach(chunks) { chunk in
                        MapPolyline(coordinates: trip.points[chunk.range].map(\.coordinate))
                            .stroke(Self.speedColor(chunk.fraction), style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                    }
                    if let first = trip.points.first, let last = trip.points.last {
                        Marker("Start", systemImage: "flag.fill", coordinate: first.coordinate).tint(.green)
                        Marker("Koniec", systemImage: "flag.checkered", coordinate: last.coordinate).tint(.red)
                    }
                }
                .mapStyle(satellite ? .hybrid(elevation: .realistic) : .standard(elevation: .realistic, pointsOfInterest: .excludingAll))
                .frame(height: 300)
                .overlay(alignment: .bottomTrailing) {
                    Button {
                        satellite.toggle()
                    } label: {
                        Image(systemName: satellite ? "map.fill" : "globe.europe.africa.fill")
                            .font(.body)
                            .frame(width: 44, height: 44)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .accessibilityLabel(satellite ? "Mapa" : "Satelita")
                    .padding(10)
                }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                // Legend: the colour scale with the trip's own numbers at its ends.
                HStack(spacing: 8) {
                    Text("0 km/h")
                    Capsule()
                        .fill(LinearGradient(colors: [Self.speedColor(0), Self.speedColor(0.5), Self.speedColor(1)],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(height: 6)
                    Text(formatKmh(s.maxSpeed))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Kolor trasy oznacza prędkość: zielony wolno, czerwony do \(formatKmh(s.maxSpeed))")

                Button {
                    recorder.startReplay(trip)
                } label: {
                    Label("Odtwórz przejazd", systemImage: "play.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .disabled(recorder.isRecording)

                Card(title: "Przejazd") {
                    Grid(horizontalSpacing: 8, verticalSpacing: 14) {
                        GridRow {
                            Stat(title: "Dystans", value: formatKm(s.distance))
                            Stat(title: "Czas", value: formatDuration(s.duration))
                            Stat(title: "W ruchu", value: formatDuration(s.movingTime))
                        }
                        GridRow {
                            Stat(title: "Start", value: trip.start.formatted(date: .omitted, time: .shortened))
                            Stat(title: "Koniec", value: end.formatted(date: .omitted, time: .shortened))
                            Stat(title: "Postój", value: formatDuration(s.duration - s.movingTime))
                        }
                    }
                }

                Card(title: "Prędkość") {
                    Grid(horizontalSpacing: 8, verticalSpacing: 14) {
                        GridRow {
                            Stat(title: "Średnia", value: formatKmh(s.avgSpeed))
                            Stat(title: "W ruchu", value: formatKmh(s.avgMovingSpeed))
                            Stat(title: "Maks.", value: formatKmh(s.maxSpeed))
                        }
                    }
                    Chart(samples, id: \.t) { p in
                        AreaMark(x: .value("Czas", p.t), y: .value("km/h", (p.speed ?? 0) * 3.6))
                            .interpolationMethod(.monotone)
                            .foregroundStyle(LinearGradient(colors: [Color.blue.opacity(0.35), Color.blue.opacity(0.02)],
                                                            startPoint: .top, endPoint: .bottom))
                        LineMark(x: .value("Czas", p.t), y: .value("km/h", (p.speed ?? 0) * 3.6))
                            .interpolationMethod(.monotone)
                            .foregroundStyle(Color.blue)
                    }
                    .chartYAxisLabel("km/h")
                    .frame(height: 150)
                    .accessibilityLabel("Wykres prędkości w czasie przejazdu")
                }

                Card(title: "Paliwo (szacunek)") {
                    Grid(horizontalSpacing: 8, verticalSpacing: 14) {
                        GridRow {
                            Stat(title: "Paliwo", value: formatLitres(fuel))
                            Stat(title: "Koszt", value: formatCost(fuel * fuelPrice))
                            Stat(title: "Na 100 km", value: formatCost(fuelPer100 * fuelPrice))
                        }
                    }
                }

                Card(title: "Wysokość") {
                    Grid(horizontalSpacing: 8, verticalSpacing: 14) {
                        GridRow {
                            Stat(title: "Min.", value: String(format: "%.0f m", s.minAlt))
                            Stat(title: "Maks.", value: String(format: "%.0f m", s.maxAlt))
                            Stat(title: "Punkty GPS", value: "\(trip.points.count)")
                        }
                    }
                    Chart(samples, id: \.t) { p in
                        AreaMark(x: .value("Czas", p.t), yStart: .value("m", s.minAlt), yEnd: .value("m", p.alt))
                            .interpolationMethod(.monotone)
                            .foregroundStyle(LinearGradient(colors: [Color.green.opacity(0.35), Color.green.opacity(0.02)],
                                                            startPoint: .top, endPoint: .bottom))
                        LineMark(x: .value("Czas", p.t), y: .value("m", p.alt))
                            .interpolationMethod(.monotone)
                            .foregroundStyle(Color.green)
                    }
                    .chartYScale(domain: .automatic(includesZero: false))
                    .chartYAxisLabel("m")
                    .frame(height: 120)
                    .accessibilityLabel("Wykres wysokości w czasie przejazdu")
                }
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
        .navigationTitle(tripDateTitle(trip.start))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if let gpxURL { ShareLink("Eksportuj GPX", item: gpxURL) }
                    if let csvURL { ShareLink("Eksportuj CSV", item: csvURL) }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("Eksportuj trasę")
                .disabled(gpxURL == nil && csvURL == nil)
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

import SwiftUI
import MapKit
import Charts

@main
struct TrasaApp: App {
    @StateObject private var recorder = Recorder()
    // Held, not observed: only the car screen redraws when car values change.
    @State private var obd = OBDAdapter()
    @State private var places = TripPlaces()

    var body: some Scene {
        WindowGroup {
            RecordView(obd: obd, places: places).environmentObject(recorder)
        }
    }
}

/// UserDefaults keys shared by the screens.
enum Prefs {
    static let fuelPer100 = "fuelPer100"     // l / 100 km
    static let fuelPrice = "fuelPrice"       // zł / l
    static let fuelCorrection = "fuelCorrection" // multiplies the fuel the car measured
    static let speedLimits = "showSpeedLimits"
    static let traffic = "showTraffic"
    static let placeNames = "showPlaceNames"
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

/// "Dziś", "Wczoraj", otherwise "Sobota, 21 listopada".
func dayTitle(_ date: Date) -> String {
    if Calendar.current.isDateInToday(date) { return "Dziś" }
    if Calendar.current.isDateInYesterday(date) { return "Wczoraj" }
    let text = date.formatted(.dateTime.weekday(.wide).day().month(.wide))
    return text.prefix(1).uppercased() + text.dropFirst()
}

/// "18:12–18:25"
func timeRange(_ start: Date, _ end: Date) -> String {
    start.formatted(date: .omitted, time: .shortened) + "–" + end.formatted(date: .omitted, time: .shortened)
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

/// One number with its name above it, set large: the unit of a workout summary in Fitness.
struct Metric: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.title2, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// The secondary readings in one quiet line. Its own view, so only this line redraws when the
/// accelerometer reading changes.
struct LiveDetails: View {
    let text: String
    @ObservedObject var meter: GMeter

    var body: some View {
        Text(text + String(format: " · %.2f g", locale: Locale.current, meter.value))
            .font(.footnote)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }
}

/// The shape of a route drawn small: what tells one trip from another at a glance.
struct RouteGlyph: View {
    let outline: [OutlinePoint]

    var body: some View {
        GeometryReader { geo in
            Path { path in
                for (i, p) in outline.enumerated() {
                    let point = CGPoint(x: p.x * geo.size.width, y: p.y * geo.size.height)
                    if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
            }
            .stroke(Color.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
        }
        .padding(10)
        .frame(width: 44, height: 44)
        .background(Color.blue.gradient, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// A saved trip in a list: where it went, when, how far.
struct TripRow: View {
    let trip: Trip
    let title: String?

    var body: some View {
        let range = timeRange(trip.start, trip.points.last?.t ?? trip.start)
        let numbers = "\(formatKm(trip.stats.distance)) · \(formatShortDuration(trip.stats.duration))"
        HStack(spacing: 12) {
            // ponytail: the outline is recomputed whenever the row redraws; cache it per trip if lists get long.
            RouteGlyph(outline: routeOutline(trip.points))
            VStack(alignment: .leading, spacing: 3) {
                Text(title ?? range)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Text(title == nil ? numbers : range + " · " + numbers)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// The panel's main buttons: a full-width capsule that dims while pressed.
struct PillButtonStyle: ButtonStyle {
    let tint: Color
    var height: CGFloat = 56
    var font: Font = .title3.bold()

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(font)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(tint.opacity(configuration.isPressed ? 0.7 : 1), in: Capsule())
            .contentShape(Capsule())
    }
}

/// An action under a title, as on a place card in Maps: symbol over a short word.
struct ActionLabel: View {
    let title: String
    let icon: String
    var prominent = false
    var tint = Color.blue

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon).font(.body.weight(.semibold))
            Text(title).font(.caption.weight(.medium))
        }
        .frame(maxWidth: .infinity)
        .frame(height: 56)
        .foregroundStyle(prominent ? Color.white : tint)
        .background(prominent ? tint : Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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

/// What the engine is doing right now, on the map opposite the speed limit sign. Its own view,
/// so it alone redraws when a reading changes.
struct CarGauges: View {
    @EnvironmentObject var obd: OBDAdapter
    @AppStorage(Prefs.fuelCorrection) private var fuelCorrection = 1.0

    var body: some View {
        let car = obd.car.values
        let fuel = liveConsumption(car, correction: fuelCorrection)
        if obd.state == .ready, !obd.readings.isEmpty, fuel != nil || car[0x0C] != nil {
            VStack(alignment: .trailing, spacing: 2) {
                if let fuel {
                    let number = String(format: "%.1f", locale: Locale.current, fuel.value)
                    gauge(number, fuel.per100 ? "l/100 km" : "l/h")
                        .accessibilityLabel("Spalanie \(number) " + (fuel.per100 ? "litra na sto kilometrów" : "litra na godzinę"))
                }
                if let rpm = car[0x0C] {
                    // To the nearest 50: the last digits only flicker.
                    let number = String(format: "%.0f", (rpm / 50).rounded() * 50)
                    gauge(number, "obr./min")
                        .accessibilityLabel("Obroty \(number) na minutę")
                }
                if let coolant = car[0x05] {
                    let number = String(format: "%.0f", coolant)
                    gauge(number, "°C")
                        .accessibilityLabel("Temperatura silnika \(number) stopni")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.3), radius: 4, y: 1)
        }
    }

    private func gauge(_ value: String, _ unit: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value)
                .font(.system(.title2, design: .rounded).weight(.bold))
                .monospacedDigit()
            Text(unit)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
    }
}

// MARK: Map screen

struct RecordView: View {
    let obd: OBDAdapter
    let places: TripPlaces
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
    /// Coolant temperature while the engine runs cold; nil when it is warm, off or not connected.
    @State private var coldEngine: Int?
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
        if let coldEngine { return Notice(icon: "thermometer.low", text: "Silnik zimny · \(coldEngine) °C") }
        return nil
    }

    /// The car is not observed here (its values change many times a second), so it is looked at on the timer.
    private func refreshCar() {
        // A remembered adapter is retried while the app is in use; never from a suspended app.
        if scenePhase == .active || recorder.isRecording { obd.autoConnect() }
        let car = obd.car.values
        var cold: Int?
        if let rpm = car[0x0C], rpm >= engineRunningRPM, let coolant = car[0x05], coolant < engineColdBelow {
            cold = Int(coolant.rounded())
        }
        if cold != coldEngine { coldEngine = cold }
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
            .onReceive(statusTimer) { _ in
                refreshGPS()
                refreshCar()
            }
            .overlay(alignment: .topLeading) {
                if let limit = road.speedLimit {
                    SpeedLimitSign(limit: limit, exceeded: over).padding(12)
                }
            }
            .overlay(alignment: .topTrailing) {
                CarGauges().environmentObject(obd).padding(12)
            }
            // Short taps for discrete events only: recording started or stopped, paused, limit crossed.
            .sensoryFeedback(.impact(weight: .medium), trigger: recorder.isRecording)
            .sensoryFeedback(.impact(weight: .light), trigger: recorder.isPaused)
            .sensoryFeedback(trigger: over) { _, isOver in isOver ? .warning : nil }
            .preferredColorScheme(night ? .dark : nil)
            .onAppear {
                recorder.requestPermission()
                motion.setRunning(true)
                // Car values ride along with the GPS fixes of a recording.
                let adapter = obd
                recorder.carValues = { [weak adapter] in adapter?.takeCarValues() }
                obd.autoConnect()
            }
            .onChange(of: scenePhase) {
                motion.setRunning(scenePhase == .active)
                if scenePhase == .active { obd.autoConnect() }
                // Off the screen and not recording: stop asking the car, or the adapter never sleeps.
                if scenePhase == .background, !recorder.isRecording { obd.suspend() }
            }
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
                    .environmentObject(places)
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
    static let compactHeight: CGFloat = 200
    /// Parked and not recording, the panel shows the place and a large Start; from this speed up
    /// it shows the speedometer even without recording.
    static let movingSpeed = 5.0 // km/h
    /// Darker than system green, so the white label keeps 3:1 contrast.
    static let startGreen = Color(red: 0.12, green: 0.6, blue: 0.28)
    static let compactDetent = PresentationDetent.height(compactHeight)

    @EnvironmentObject var recorder: Recorder
    @EnvironmentObject var places: TripPlaces
    @Binding var detent: PresentationDetent
    @Binding var path: [Route]
    let street: String?
    let speedLimit: Int?
    let gMeter: GMeter
    @AppStorage(Prefs.fuelPer100) private var fuelPer100 = 7.0
    @AppStorage(Prefs.fuelPrice) private var fuelPrice = 6.5
    @AppStorage(Prefs.fuelCorrection) private var fuelCorrection = 1.0
    @AppStorage(Prefs.placeNames) private var showPlaceNames = true

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
                            NavigationLink(value: Route.stats) {
                                HStack {
                                    Label("Statystyki", systemImage: "chart.bar.fill")
                                    Spacer()
                                    if !recorder.trips.isEmpty {
                                        Text(tripsLabel(recorder.trips.count)).foregroundStyle(.secondary)
                                    }
                                }
                            }
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
        .task(id: "\(recorder.trips.count) \(showPlaceNames)") {
            places.resolve(recorder.trips, enabled: showPlaceNames)
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

    /// Two states. Parked and not recording: where you are, set large, and a large Start.
    /// Driving (recording, replaying, or simply moving): speedometer, place, distance and time.
    private func hud(_ stats: TripStats) -> some View {
        let kmh = (recorder.live?.speed ?? 0) * 3.6
        let driving = recorder.isRecording || recorder.isReplaying || kmh >= Self.movingSpeed
        return VStack(spacing: 14) {
            if driving {
                drivingHeader(stats, kmh: kmh)
            } else {
                parkedHeader
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

    /// Nothing is being measured yet, so no zeros: the place fills the width.
    private var parkedHeader: some View {
        VStack(alignment: .leading, spacing: 2) {
            // A short name is set large; a long one shrinks to fit instead of being cut off.
            Text(street ?? "Gotowy do jazdy")
                .font(.largeTitle.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(street == nil ? "Naciśnij Start, żeby nagrać trasę" : "Gotowy do jazdy")
                .font(.title3)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func drivingHeader(_ stats: TripStats, kmh: Double) -> some View {
        let over = speedLimit.map { isOverLimit(speed: recorder.live?.speed, limit: $0) } ?? false
        return HStack(alignment: .center, spacing: 16) {
            VStack(spacing: -2) {
                Text(String(format: "%.0f", kmh))
                    .font(.system(size: 64, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(over ? Color.red : Color.primary) // the sign also grows: not colour alone
                Text("km/h").font(.footnote.weight(.medium)).foregroundStyle(.secondary)
            }
            .frame(minWidth: 100)
            .accessibilityElement(children: .combine)
            VStack(alignment: .leading, spacing: 6) {
                Text(statusTitle)
                    .font(.largeTitle.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.45)
                HStack(alignment: .firstTextBaseline, spacing: 18) {
                    Text(formatKm(stats.distance)).accessibilityLabel("Dystans \(formatKm(stats.distance))")
                    Text(formatDuration(stats.duration)).accessibilityLabel("Czas \(formatDuration(stats.duration))")
                }
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            }
            Spacer(minLength: 0)
        }
    }

    private var recordControls: some View {
        HStack(spacing: 12) {
            if recorder.isRecording {
                Button(recorder.isPaused ? "Wznów" : "Pauza") {
                    if recorder.isPaused { recorder.resume() } else { recorder.pause() }
                }
                .buttonStyle(PillButtonStyle(tint: .orange))
                Button("Stop") {
                    if let saved = recorder.stop() { path = [.trip(saved)] }
                }
                .buttonStyle(PillButtonStyle(tint: .red))
            } else {
                Button("Start") { recorder.start() }
                    .buttonStyle(PillButtonStyle(tint: Self.startGreen, height: 64, font: .title2.bold()))
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

    /// The drive in progress: four numbers set large, the rest in one quiet line. Nothing when parked.
    @ViewBuilder
    private func currentTrip(_ stats: TripStats) -> some View {
        if recorder.isRecording || recorder.isReplaying {
            let live = recorder.live
            let car = CarStats(recorder.points)
            let fuel = tripFuel(distance: stats.distance, carLitres: car.litres, carDistance: car.distance,
                                per100: fuelPer100, correction: fuelCorrection)
            let altitude = live.map { String(format: "%.0f m", $0.alt) } ?? "–"
            let heading = live?.course.map { compass($0) } ?? "–"
            let accuracy = live.map { String(format: "±%.0f m", $0.hAcc) } ?? "–"
            Section {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                    GridRow {
                        Metric(label: "Średnia prędkość", value: formatKmh(stats.avgSpeed))
                        Metric(label: "Najwyższa prędkość", value: formatKmh(stats.maxSpeed))
                    }
                    Divider()
                    GridRow {
                        Metric(label: "Paliwo (\(fuel.source))", value: formatLitres(fuel.litres))
                        Metric(label: "Koszt (\(fuel.source))", value: formatCost(fuel.litres * fuelPrice))
                    }
                    if car.time > 0 {
                        Divider()
                        GridRow {
                            Metric(label: "Średnie spalanie", value: car.per100.map { formatPer100($0 * fuelCorrection) } ?? "–")
                            Metric(label: "Na biegu jałowym", value: formatDuration(car.idleTime))
                        }
                    }
                }
                .padding(.vertical, 4)
                LiveDetails(text: "Wysokość \(altitude) · kierunek \(heading) · GPS \(accuracy)", meter: gMeter)
            } header: {
                Text(recorder.isReplaying ? "Odtwarzany przejazd" : "Ten przejazd")
            }
            .headerProminence(.increased)
        }
    }

    /// Saved trips by day, as recent places are listed in Maps: a picture, a name, a line of detail.
    @ViewBuilder
    private var savedTrips: some View {
        if recorder.trips.isEmpty {
            Section {
                VStack(spacing: 6) {
                    Image(systemName: "road.lanes").font(.title).foregroundStyle(.secondary)
                    Text("Brak zapisanych tras").font(.headline)
                    Text("Naciśnij Start, żeby nagrać pierwszą.").font(.subheadline).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .accessibilityElement(children: .combine)
            }
        } else {
            ForEach(groupByDay(recorder.trips)) { day in
                Section {
                    ForEach(day.trips) { trip in
                        NavigationLink(value: Route.trip(trip.url)) {
                            TripRow(trip: trip, title: showPlaceNames ? places.title(for: trip) : nil)
                        }
                    }
                    .onDelete { offsets in
                        for trip in offsets.map({ day.trips[$0] }) { recorder.delete(trip) }
                    }
                } header: {
                    Text(dayTitle(day.day))
                }
                .headerProminence(.increased)
            }
        }
    }
}

struct StatsView: View {
    @EnvironmentObject var recorder: Recorder
    @AppStorage(Prefs.fuelPer100) private var fuelPer100 = 7.0
    @AppStorage(Prefs.fuelPrice) private var fuelPrice = 6.5
    @AppStorage(Prefs.fuelCorrection) private var fuelCorrection = 1.0
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
        let fuel = tripFuel(distance: period.distance, carLitres: period.carLitres, carDistance: period.carDistance,
                            per100: fuelPer100, correction: fuelCorrection)
        var text = "\(tripsLabel(period.count)) · \(formatShortDuration(period.duration)) · \(formatCost(fuel.litres * fuelPrice))"
        // Real consumption, once the car has measured enough of the period to say.
        if period.carDistance >= 1000 {
            text += " · " + formatPer100(period.carLitres * fuelCorrection / period.carDistance * 100_000)
        }
        return text
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
                case .scanning, .waiting, .connecting, .reading, .ready:
                    Button("Rozłącz", role: .destructive) { obd.disconnect() }
                }
            } footer: {
                Text("Włóż adapter w gniazdo OBD pod kierownicą i włącz zapłon. Journey tylko odczytuje dane, niczego w aucie nie zmienia.\n\nRaz połączony adapter łączy się potem sam. Podczas nagrywania dane auta zapisują się razem z trasą: spalanie, obroty i temperaturę zobaczysz w widoku przejazdu. „Rozłącz” wyłącza też automatyczne łączenie.")
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
        case .waiting(let name):
            HStack(spacing: 12) {
                ProgressView()
                Text("Czekam na adapter \(name). Połączy się sam, gdy będzie w zasięgu.")
            }
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
    @AppStorage(Prefs.fuelCorrection) private var fuelCorrection = 1.0
    @AppStorage(Prefs.speedLimits) private var showSpeedLimits = true
    @AppStorage(Prefs.traffic) private var showTraffic = true
    @AppStorage(Prefs.placeNames) private var showPlaceNames = true

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
                LabeledContent("Korekta spalania z auta (×)") {
                    TextField("1", value: $fuelCorrection, format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }
            } header: {
                Text("Paliwo")
            } footer: {
                Text("Z adapterem OBD paliwo jest liczone z danych auta; bez niego to szacunek: dystans × spalanie × cena. Jeśli po tankowaniu wyjdzie inne spalanie niż pokazuje Journey, wpisz w korekcie rzeczywiste podzielone przez pokazane (np. 1,08).")
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
            Section {
                Toggle("Nazwy miejsc na liście tras", isOn: $showPlaceNames)
            } footer: {
                Text("Trasy są podpisane miejscowościami, np. „Rylsk → Rawa Mazowiecka”. Nazwy podają Mapy Apple na podstawie początku i końca trasy zaokrąglonych do ok. 1 km. Po usunięciu trasy jej nazwa też znika.")
            }
        }
        .navigationTitle("Ustawienia")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// One saved trip, laid out like a place card in Maps with a Fitness-style summary:
/// the route, what it was and when, what you can do with it, then the numbers.
struct TripDetailView: View {
    let trip: Trip
    @EnvironmentObject var recorder: Recorder
    @EnvironmentObject var places: TripPlaces
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Prefs.fuelPer100) private var fuelPer100 = 7.0
    @AppStorage(Prefs.fuelPrice) private var fuelPrice = 6.5
    @AppStorage(Prefs.fuelCorrection) private var fuelCorrection = 1.0
    @State private var gpxURL: URL?
    @State private var csvURL: URL?
    @State private var rpmSeries: [CarPoint] = []
    @State private var fuelSeries: [CarPoint] = []
    @State private var coolantSeries: [CarPoint] = []
    @State private var satellite = false
    @State private var confirmDelete = false
    @AppStorage(Prefs.placeNames) private var showPlaceNames = true

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

    /// What the car reported during the trip: the engine's numbers, then a chart for each figure it gave.
    @ViewBuilder
    private func carCards(_ car: CarStats) -> some View {
        Card(title: "Silnik") {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                if car.time > 0 {
                    GridRow {
                        Metric(label: "Średnie spalanie", value: car.per100.map { formatPer100($0 * fuelCorrection) } ?? "–")
                        Metric(label: "Paliwo na postoju", value: formatLitres(car.idleLitres * fuelCorrection))
                    }
                    Divider()
                }
                GridRow {
                    Metric(label: "Średnie obroty", value: String(format: "%.0f obr./min", car.avgRPM))
                    Metric(label: "Najwyższe obroty", value: String(format: "%.0f obr./min", car.maxRPM))
                }
                Divider()
                GridRow {
                    Metric(label: "Na biegu jałowym", value: formatDuration(car.idleTime))
                    Metric(label: "Najwyższa temp. silnika", value: car.maxCoolant.map { String(format: "%.0f °C", $0) } ?? "–")
                }
                if let warmUp = car.warmUp {
                    Divider()
                    GridRow {
                        Metric(label: "Rozgrzewanie do \(Int(engineWarmAt)) °C", value: formatShortDuration(warmUp))
                        Color.clear.frame(height: 1)
                    }
                }
            }
            if car.time > 0, car.time < trip.stats.duration * 0.95 {
                Text("Auto podawało spalanie przez \(formatShortDuration(car.time)) z \(formatShortDuration(trip.stats.duration)) przejazdu. Resztę paliwa policzono ze spalania wpisanego w Ustawieniach.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        carChart("Spalanie chwilowe", unit: "l/h", fuelSeries.map { CarPoint(t: $0.t, value: $0.value * fuelCorrection) }, .orange)
        carChart("Obroty", unit: "obr./min", rpmSeries, .purple)
        carChart("Temperatura silnika", unit: "°C", coolantSeries, .red)
    }

    @ViewBuilder
    private func carChart(_ title: String, unit: String, _ series: [CarPoint], _ color: Color) -> some View {
        if series.count > 1 {
            Card(title: title) {
                Chart(series) { p in
                    LineMark(x: .value("Czas", p.t), y: .value(unit, p.value))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(color)
                }
                .chartYAxisLabel(unit)
                .frame(height: 140)
                .accessibilityLabel("\(title) w czasie przejazdu")
            }
        }
    }

    var body: some View {
        let s = trip.stats
        let chunks = speedChunks(trip.points)
        let car = trip.car
        let fuel = tripFuel(distance: s.distance, carLitres: car.litres, carDistance: car.distance,
                            per100: fuelPer100, correction: fuelCorrection)
        let end = trip.points.last?.t ?? trip.start
        // Charts get at most ~300 samples; the map and the files keep every point.
        let samples = stride(from: 0, to: trip.points.count, by: max(1, trip.points.count / 300)).map { trip.points[$0] }
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
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
                .frame(height: 270)
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
                .overlay(alignment: .bottomLeading) {
                    // Legend on the map it explains: the colour scale with this trip's top speed.
                    HStack(spacing: 6) {
                        Text("0")
                        Capsule()
                            .fill(LinearGradient(colors: [Self.speedColor(0), Self.speedColor(0.5), Self.speedColor(1)],
                                                 startPoint: .leading, endPoint: .trailing))
                            .frame(width: 64, height: 5)
                        Text(formatKmh(s.maxSpeed))
                    }
                    .font(.caption2.weight(.medium).monospacedDigit())
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.leading, 10)
                    .padding(.bottom, 34) // above the Maps logo
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Kolor trasy oznacza prędkość: zielony wolno, czerwony do \(formatKmh(s.maxSpeed))")
                }
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text((showPlaceNames ? places.title(for: trip) : nil) ?? "Przejazd")
                        .font(.title2.weight(.bold))
                        .lineLimit(2)
                    Text("\(dayTitle(trip.start)) · \(timeRange(trip.start, end))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)

                HStack(spacing: 10) {
                    Button {
                        recorder.startReplay(trip)
                    } label: {
                        ActionLabel(title: "Odtwórz", icon: "play.fill", prominent: true)
                    }
                    .disabled(recorder.isRecording)
                    .opacity(recorder.isRecording ? 0.4 : 1)
                    Menu {
                        if let gpxURL { ShareLink("Plik GPX", item: gpxURL) }
                        if let csvURL { ShareLink("Plik CSV", item: csvURL) }
                    } label: {
                        ActionLabel(title: "Eksportuj", icon: "square.and.arrow.up")
                    }
                    .disabled(gpxURL == nil && csvURL == nil)
                    Button {
                        confirmDelete = true
                    } label: {
                        ActionLabel(title: "Usuń", icon: "trash", tint: .red)
                    }
                }
                .buttonStyle(.plain)

                Card(title: "Podsumowanie") {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                        GridRow {
                            Metric(label: "Dystans", value: formatKm(s.distance))
                            Metric(label: "Czas", value: formatDuration(s.duration))
                        }
                        Divider()
                        GridRow {
                            Metric(label: "Średnia prędkość", value: formatKmh(s.avgSpeed))
                            Metric(label: "Najwyższa prędkość", value: formatKmh(s.maxSpeed))
                        }
                        Divider()
                        GridRow {
                            Metric(label: "W ruchu", value: formatDuration(s.movingTime))
                            Metric(label: "Postój", value: formatDuration(s.duration - s.movingTime))
                        }
                        Divider()
                        GridRow {
                            Metric(label: "Paliwo (\(fuel.source))", value: formatLitres(fuel.litres))
                            Metric(label: "Koszt (\(fuel.source))", value: formatCost(fuel.litres * fuelPrice))
                        }
                    }
                }

                if car.samples > 0 { carCards(car) }

                Card(title: "Prędkość") {
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
                    .frame(height: 160)
                    .accessibilityLabel("Wykres prędkości w czasie przejazdu")
                }

                Card(title: "Wysokość") {
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
                    .chartYAxisLabel("m n.p.m.")
                    .frame(height: 120)
                    .accessibilityLabel("Wykres wysokości w czasie przejazdu")
                    Text(String(format: "Od %.0f m do %.0f m", s.minAlt, s.maxAlt))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Text("Zapisano punktów GPS: \(trip.points.count)" + (car.samples > 0 ? ", z danymi auta: \(car.samples)" : ""))
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
        .navigationTitle(tripDateTitle(trip.start))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // Thinned once, not on every redraw.
            rpmSeries = carSeries(trip.points) { $0[0x0C] }
            fuelSeries = carSeries(trip.points, fuelRate)
            coolantSeries = carSeries(trip.points) { $0[0x05] }
        }
        .confirmationDialog("Usunąć tę trasę?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Usuń trasę", role: .destructive) {
                recorder.delete(trip)
                dismiss()
            }
            Button("Anuluj", role: .cancel) {}
        } message: {
            Text("Nagranie zostanie usunięte z telefonu. Tego nie da się cofnąć.")
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

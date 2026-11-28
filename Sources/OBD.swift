import Combine
import CoreBluetooth
import Foundation

/// Connection to an ELM327-compatible Bluetooth LE adapter in the car's OBD socket.
///
/// Read-only: it asks the car what it can report and reads those values. It never clears codes
/// and never writes anything to the car. It is separate from trip recording: whatever happens
/// here, GPS recording carries on.
final class OBDAdapter: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    enum State: Equatable {
        case idle
        case bluetoothOff
        case unauthorized
        case scanning
        case waiting(String)   // the remembered adapter is not in reach yet; it connects by itself when it appears
        case connecting(String)
        case reading(String)   // talking to the adapter / car, with what is being done
        case ready             // values are being read continuously
        case failed(String)
    }

    struct Device: Identifiable {
        let id: UUID
        let name: String
        let likely: Bool
        let peripheral: CBPeripheral
    }

    struct Reading: Identifiable {
        let pid: UInt8
        var data: [UInt8] = []
        var id: UInt8 { pid }
    }

    struct InfoRow: Identifiable {
        let label: String
        let value: String
        var id: String { label }
    }

    static let connectTimeout = 12.0   // s
    static let commandTimeout = 3.0    // s
    static let firstContactTimeout = 15.0 // s; the adapter tries every protocol on the first request
    static let maxLogLines = 1500
    static let retryInterval = 20.0    // s between automatic attempts after a failure
    static let silentLimit = 10        // requests in a row without an answer before the car counts as gone
    static let adapterIDKey = "obdAdapterID"
    static let adapterNameKey = "obdAdapterName"
    /// GATT services every Bluetooth device has; the adapter's serial channel is never one of these.
    static let standardServices: Set<String> = ["1800", "1801", "180A", "180F"]

    @Published private(set) var state: State = .idle
    @Published private(set) var devices: [Device] = []
    @Published private(set) var info: [InfoRow] = []
    @Published private(set) var readings: [Reading] = []
    /// Answers per second while values are being read.
    @Published private(set) var rate = 0.0
    /// Trouble codes the car has stored, read once per connection. Never cleared by this app.
    @Published private(set) var codes: [String] = []
    /// Everything exchanged with the adapter during set-up. Not published: it changes too often.
    private(set) var log: [String] = []
    /// Latest decoded values with the time each was read. Not published: `readings` drives the screen.
    private(set) var car = CarValues()
    var logText: String { log.joined(separator: "\n") }

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var tx: CBCharacteristic?
    private var rx: CBCharacteristic?
    private var wantsScan = false
    private var userDisconnected = false
    private var pendingDiscoveries = 0
    private var otherDevices = 0
    private var buffer = ""
    private var pending: CheckedContinuation<String?, Never>?
    private var commandID = 0
    private var logCommands = true
    private var session: Task<Void, Never>?
    private var engine = "7E8"
    private var adapterName = ""
    private var failedAt = Date.distantPast

    // MARK: Scanning and connecting

    /// Looks for adapters nearby. The Bluetooth permission question appears on the first call.
    func startScan() {
        suspend()
        devices = []
        otherDevices = 0
        log = []
        if central == nil {
            wantsScan = true
            central = CBCentralManager(delegate: self, queue: nil) // answers arrive in centralManagerDidUpdateState
        } else {
            beginScan()
        }
    }

    private func beginScan() {
        guard let central else { return }
        switch central.state {
        case .poweredOn:
            state = .scanning
            note("Szukam urządzeń Bluetooth LE")
            central.scanForPeripherals(withServices: nil, options: nil)
        case .unauthorized:
            state = .unauthorized
        case .poweredOff:
            state = .bluetoothOff
        case .unsupported:
            state = .failed("To urządzenie nie obsługuje Bluetooth LE.")
        default:
            wantsScan = true // still starting up
        }
    }

    func connect(_ device: Device) {
        guard let central else { return }
        central.stopScan()
        note("Znaleziono innych urządzeń: \(otherDevices)")
        note("Łączę z: \(device.name)")
        userDisconnected = false
        adapterName = device.name
        peripheral = device.peripheral
        device.peripheral.delegate = self
        state = .connecting(device.name)
        central.connect(device.peripheral, options: nil)
        let target = device.peripheral
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.connectTimeout) { [weak self] in
            guard let self, self.peripheral === target, case .connecting = self.state else { return }
            self.fail("Nie udało się połączyć z adapterem. Sprawdź, czy jest włożony w gniazdo i czy świeci.")
        }
    }

    /// Connects to the adapter used last time, whenever it comes into reach. Does nothing when no
    /// adapter is remembered, when something is already going on, or right after a failure.
    func autoConnect() {
        guard let id = UserDefaults.standard.string(forKey: Self.adapterIDKey).flatMap(UUID.init(uuidString:)) else { return }
        switch state {
        case .idle, .failed, .bluetoothOff: break
        default: return
        }
        guard Date().timeIntervalSince(failedAt) >= Self.retryInterval else { return }
        guard let central else {
            central = CBCentralManager(delegate: self, queue: nil) // comes back here from centralManagerDidUpdateState
            return
        }
        guard central.state == .poweredOn, let known = central.retrievePeripherals(withIdentifiers: [id]).first else { return }
        adapterName = UserDefaults.standard.string(forKey: Self.adapterNameKey) ?? known.name ?? "adapter"
        note("Łączę automatycznie z: \(adapterName)")
        userDisconnected = false
        peripheral = known
        known.delegate = self
        state = .waiting(adapterName)
        central.connect(known, options: nil) // no timeout: it stays pending until the adapter is in reach
    }

    /// The user's "Rozłącz": also forgets the adapter, so nothing reconnects by itself.
    func disconnect() {
        UserDefaults.standard.removeObject(forKey: Self.adapterIDKey)
        UserDefaults.standard.removeObject(forKey: Self.adapterNameKey)
        suspend()
    }

    /// Ends the connection but keeps the adapter remembered. Also called when the app goes to the
    /// background without recording: it would otherwise go on asking the car, which keeps the
    /// adapter awake on the car's battery.
    func suspend() {
        userDisconnected = true
        session?.cancel()
        session = nil
        central?.stopScan()
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        peripheral = nil
        tx = nil
        rx = nil
        finish(nil)
        info = []
        readings = []
        codes = []
        car.clear()
        rate = 0
        state = .idle
    }

    private func fail(_ message: String) {
        note("BŁĄD: " + message)
        session?.cancel()
        session = nil
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        userDisconnected = true
        peripheral = nil
        tx = nil
        rx = nil
        finish(nil)
        // Old values must not pass for current ones, on the screen or in a trip being recorded.
        readings = []
        codes = []
        car.clear()
        rate = 0
        failedAt = Date()
        state = .failed(message)
    }

    private func note(_ line: String) {
        log.append(line)
        if log.count > Self.maxLogLines { log.removeFirst(log.count - Self.maxLogLines) }
    }

    // MARK: CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if wantsScan {
            wantsScan = false
            beginScan()
        } else if central.state == .poweredOn {
            autoConnect()
        } else if peripheral != nil {
            fail("Bluetooth został wyłączony.")
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard !devices.contains(where: { $0.id == peripheral.identifier }) else { return }
        let advertised = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        guard let name = peripheral.name ?? advertised, !name.isEmpty else { return }
        let likely = looksLikeOBDAdapter(name)
        // Only adapter-like names go into the shareable log: other people's devices are none of its business.
        if likely { note("Urządzenie: \(name) (sygnał \(RSSI) dBm)") } else { otherDevices += 1 }
        devices.append(Device(id: peripheral.identifier, name: name, likely: likely, peripheral: peripheral))
        devices.sort { $0.likely && !$1.likely }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        note("Połączono. Odczytuję usługi adaptera")
        state = .reading("Rozpoznaję adapter…")
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        fail("Nie udało się połączyć z adapterem.")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard peripheral === self.peripheral, !userDisconnected else { return }
        // Still waiting to connect: this is the late echo of an earlier cancel, the pending request stands.
        if case .waiting = state { return }
        fail("Połączenie z adapterem zostało przerwane.")
    }

    // MARK: CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let services = peripheral.services ?? []
        guard !services.isEmpty else {
            fail("Adapter nie udostępnia żadnych usług Bluetooth LE.")
            return
        }
        pendingDiscoveries = services.count
        for service in services {
            note("Usługa \(service.uuid.uuidString)")
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for c in service.characteristics ?? [] {
            var props: [String] = []
            if c.properties.contains(.read) { props.append("odczyt") }
            if c.properties.contains(.write) { props.append("zapis") }
            if c.properties.contains(.writeWithoutResponse) { props.append("zapis bez potwierdzenia") }
            if c.properties.contains(.notify) { props.append("powiadomienia") }
            if c.properties.contains(.indicate) { props.append("wskazania") }
            note("  \(service.uuid.uuidString) / \(c.uuid.uuidString): \(props.joined(separator: ", "))")
        }
        pendingDiscoveries -= 1
        if pendingDiscoveries == 0 { chooseSerialChannel(peripheral) }
    }

    /// Adapters differ in the identifiers they use, so the serial channel is recognised by what it can
    /// do: one characteristic that notifies (adapter to phone) and one that accepts writes (phone to adapter).
    private func chooseSerialChannel(_ peripheral: CBPeripheral) {
        let candidates = (peripheral.services ?? []).filter { !Self.standardServices.contains($0.uuid.uuidString) }
        func notifying(_ s: CBService) -> CBCharacteristic? {
            s.characteristics?.first { $0.properties.contains(.notify) || $0.properties.contains(.indicate) }
        }
        func writable(_ s: CBService) -> CBCharacteristic? {
            s.characteristics?.first { $0.properties.contains(.write) || $0.properties.contains(.writeWithoutResponse) }
        }
        let paired = candidates.first { notifying($0) != nil && writable($0) != nil }
        rx = paired.flatMap(notifying) ?? candidates.compactMap(notifying).first
        tx = paired.flatMap(writable) ?? candidates.compactMap(writable).first
        guard let rx, let tx else {
            fail("To urządzenie nie wygląda na adapter OBD: brak kanału do wysyłania poleceń.")
            return
        }
        note("Kanał: zapis \(tx.uuid.uuidString), odbiór \(rx.uuid.uuidString)")
        peripheral.setNotifyValue(true, for: rx)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic === rx else { return }
        if let error {
            fail("Adapter odmówił włączenia powiadomień: \(error.localizedDescription)")
            return
        }
        guard session == nil else { return }
        session = Task { @MainActor [weak self] in
            await self?.runSession()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic === rx, let data = characteristic.value else { return }
        buffer += String(decoding: data, as: UTF8.self)
        // The adapter ends every reply with its ">" prompt; a reply can arrive in several pieces.
        if let prompt = buffer.firstIndex(of: ">") {
            let reply = String(buffer[..<prompt])
            buffer = ""
            finish(reply)
        }
    }

    // MARK: Commands (one at a time)

    private func finish(_ reply: String?) {
        let waiting = pending
        pending = nil
        waiting?.resume(returning: reply)
    }

    /// Sends one command and waits for the reply up to the adapter's prompt; nil on timeout or disconnect.
    @MainActor
    private func command(_ text: String, timeout: Double = OBDAdapter.commandTimeout) async -> String? {
        guard let peripheral, let tx, !Task.isCancelled else { return nil }
        buffer = ""
        commandID += 1
        let id = commandID
        if logCommands { note("→ " + text) }
        let reply: String? = await withCheckedContinuation { continuation in
            pending = continuation
            let type: CBCharacteristicWriteType = tx.properties.contains(.write) ? .withResponse : .withoutResponse
            peripheral.writeValue(Data((text + "\r").utf8), for: tx, type: type)
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self, self.commandID == id else { return }
                self.finish(nil)
            }
        }
        if logCommands {
            note("← " + (reply.map { elmLines($0).joined(separator: " | ") } ?? "(brak odpowiedzi)"))
        }
        if reply == nil {
            // Let a late answer drain so it cannot be taken for the answer to the next command.
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        return reply
    }

    // MARK: Session: set up the adapter, ask the car what it supports, then read

    private func message(for failure: ELMFailure) -> String {
        switch failure {
        case .unableToConnect, .noData:
            return "Adapter działa, ale auto nie odpowiada. Włącz zapłon (lub uruchom silnik) i spróbuj ponownie."
        case .busError:
            return "Błąd komunikacji z autem. Sprawdź, czy adapter jest dobrze wciśnięty w gniazdo."
        case .stopped, .unknownCommand, .bufferFull:
            return "Adapter zwrócił nieoczekiwaną odpowiedź. Wyślij dziennik połączenia."
        }
    }

    @MainActor
    private func runSession() async {
        logCommands = true
        state = .reading("Uruchamiam adapter…")
        guard let reset = await command("ATZ", timeout: 6) else {
            fail("Urządzenie nie odpowiada na polecenia adaptera OBD.")
            return
        }
        let version = elmLines(reset).first { $0.uppercased().contains("ELM") } ?? "nieznana"
        // Echo off, no line feeds, spaces and headers on (so answers show which unit sent them),
        // adaptive timing, automatic protocol.
        for setup in ["ATE0", "ATL0", "ATS1", "ATH1", "ATAT1", "ATSP0"] {
            _ = await command(setup)
        }
        let voltage = (await command("ATRV")).map { elmLines($0).joined(separator: " ") } ?? "–"

        state = .reading("Łączę się z autem…")
        guard let first = await command("0100", timeout: Self.firstContactTimeout) else {
            fail("Auto nie odpowiedziało. Włącz zapłon i spróbuj ponownie.")
            return
        }
        var frames: [OBDFrame]
        switch parseELM(first) {
        case .frames(let f):
            frames = f
        case .failure(let failure):
            fail(message(for: failure))
            return
        case .text:
            fail("Niezrozumiała odpowiedź adaptera. Wyślij dziennik połączenia.")
            return
        }
        let protocolNumber = (await command("ATDPN")).map { elmLines($0).joined(separator: " ") } ?? "–"
        let units = frames.map(\.ecu)
        engine = units.contains("7E8") ? "7E8" : (units.first ?? "7E8")

        // The car lists what it supports 32 parameters at a time; the last bit says whether to ask on.
        var supported: [UInt8] = []
        var base: UInt8 = 0
        while let bitmap = pidData(frames, pid: base, ecu: engine), bitmap.count >= 4 {
            let pids = supportedPIDs(bitmap, base: base)
            supported += pids
            guard base < 0xC0, pids.contains(base + 0x20) else { break }
            base += 0x20
            guard let reply = await command(String(format: "01%02X", base)), case .frames(let next) = parseELM(reply) else { break }
            frames = next
        }
        let dataPIDs = supported.filter { $0 % 0x20 != 0 }
        guard !dataPIDs.isEmpty else {
            fail("Auto odpowiedziało, ale nie podało listy parametrów. Wyślij dziennik połączenia.")
            return
        }

        state = .reading("Czytam parametry (\(dataPIDs.count))…")
        readings = dataPIDs.map { Reading(pid: $0) }
        for pid in dataPIDs {
            await read(pid)
        }

        var codes: [String] = []
        var codesRead = false
        if let reply = await command("03", timeout: 5) {
            switch parseELM(reply) {
            case .frames(let answer):
                codesRead = true
                codes = answer.flatMap { decodeDTCs($0.bytes) }
            case .failure(.noData):
                codesRead = true // no stored codes
            default:
                break
            }
        }

        info = [
            InfoRow(label: "Adapter", value: version),
            InfoRow(label: "Napięcie w gnieździe", value: voltage),
            InfoRow(label: "Protokół", value: protocolName(protocolNumber)),
            InfoRow(label: "Sterowniki, które odpowiedziały", value: units.joined(separator: ", ")),
            InfoRow(label: "Kody błędów", value: codesRead ? (codes.isEmpty ? "brak" : codes.joined(separator: ", ")) : "nie odczytano"),
        ]
        self.codes = codes.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
        note("Obsługiwane parametry (\(dataPIDs.count)): " + hexString(dataPIDs))
        note("Koniec rozpoznania. Dalej tylko odczyt wartości na żywo (nie jest zapisywany w dzienniku).")
        if let peripheral {
            // Remembered from here on: next time it connects by itself.
            UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: Self.adapterIDKey)
            UserDefaults.standard.set(adapterName, forKey: Self.adapterNameKey)
        }
        state = .ready
        logCommands = false

        // Live values: engine speed, road speed and fuel flow every round, the rest one per round in turn.
        let live = dataPIDs.filter { obdParameters[$0] != nil }
        var silent = 0
        var answered = 0
        var round = 0
        var windowStart = Date()
        while !Task.isCancelled, state == .ready, !live.isEmpty {
            round += 1
            for pid in pollRound(live, round: round) {
                guard !Task.isCancelled, state == .ready else { return }
                if await read(pid) {
                    silent = 0
                    answered += 1
                } else {
                    // Ended from outside (disconnect, failure): not this loop's business any more.
                    guard !Task.isCancelled else { return }
                    silent += 1
                    if silent >= Self.silentLimit {
                        fail("Auto przestało odpowiadać. Jeśli zapłon został wyłączony, to normalne.")
                        return
                    }
                }
                let elapsed = Date().timeIntervalSince(windowStart)
                if elapsed >= 2 {
                    rate = Double(answered) / elapsed
                    answered = 0
                    windowStart = Date()
                }
            }
        }
    }

    /// Reads one parameter into `readings`; false when the car did not answer it.
    @MainActor
    @discardableResult
    private func read(_ pid: UInt8) async -> Bool {
        guard let reply = await command(String(format: "01%02X", pid)),
              case .frames(let frames) = parseELM(reply),
              let data = pidData(frames, pid: pid, ecu: engine),
              let index = readings.firstIndex(where: { $0.pid == pid }) else { return false }
        if readings[index].data != data { readings[index].data = data }
        if let value = obdParameters[pid]?.decode(data) { car.set(pid, value, at: Date()) }
        return true
    }

    /// What the car reported since the last call, to be saved with a GPS fix; nil when not connected.
    func takeCarValues() -> [Int: Double]? {
        state == .ready ? car.take(at: Date()) : nil
    }

    private func protocolName(_ number: String) -> String {
        // "A6" means protocol 6 chosen automatically.
        switch number.replacingOccurrences(of: "A", with: "") {
        case "6": return "CAN 11 bitów, 500 kb/s"
        case "7": return "CAN 29 bitów, 500 kb/s"
        case "8": return "CAN 11 bitów, 250 kb/s"
        case "9": return "CAN 29 bitów, 250 kb/s"
        default: return "nr \(number) (nie CAN)"
        }
    }
}

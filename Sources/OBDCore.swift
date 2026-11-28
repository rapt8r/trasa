import Foundation

// Foundation only, like TripCore: everything here is checked by Tests/main.swift.
// Talking to the car is read-only: no command in this file or in OBD.swift changes anything in it.

// MARK: ELM327 replies

/// One diagnostic answer from one control unit, with the transport framing removed.
struct OBDFrame: Equatable {
    /// CAN identifier the answer came from, as the adapter prints it ("7E8" is the engine).
    let ecu: String
    let bytes: [UInt8]
}

enum ELMFailure: Equatable {
    case noData            // the car did not answer this request
    case unableToConnect   // the adapter found no car at all (ignition off)
    case busError          // CAN / bus errors: bad contact, wrong protocol
    case stopped           // the adapter was interrupted
    case unknownCommand    // "?": the adapter does not know the command
    case bufferFull
}

enum ELMReply: Equatable {
    case frames([OBDFrame])
    /// Answer to an adapter (AT) command: "OK", "ELM327 v2.2", "12.4V".
    case text([String])
    case failure(ELMFailure)
}

/// Lines of one reply (everything the adapter sent before its ">" prompt), cleaned up.
func elmLines(_ raw: String) -> [String] {
    raw.replacingOccurrences(of: "\0", with: "")
        .components(separatedBy: CharacterSet(charactersIn: "\r\n"))
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && !$0.uppercased().hasPrefix("SEARCHING") }
}

private func elmFailure(_ line: String) -> ELMFailure? {
    let l = line.uppercased()
    if l.contains("UNABLE TO CONNECT") { return .unableToConnect }
    if l.contains("NO DATA") { return .noData }
    if l.contains("CAN ERROR") || l.contains("BUS ERROR") || l.contains("BUS BUSY") || l.contains("FB ERROR")
        || l.contains("DATA ERROR") || (l.contains("BUS INIT") && l.contains("ERROR")) { return .busError }
    if l.contains("STOPPED") { return .stopped }
    if l.contains("BUFFER FULL") { return .bufferFull }
    if l == "?" { return .unknownCommand }
    return nil
}

/// A CAN line as printed with headers and spaces on: "7E8 06 41 00 BE 3F A8 13"
/// (29-bit identifiers come as four separate bytes: "18 DA F1 10 06 41 00 ...").
private func canLine(_ line: String) -> (ecu: String, data: [UInt8])? {
    let tokens = line.split(separator: " ").map(String.init)
    guard let first = tokens.first else { return nil }
    let headerTokens = first.count == 3 ? 1 : 4
    guard tokens.count > headerTokens, first.count == 3 || first.count == 2 else { return nil }
    guard tokens[..<headerTokens].allSatisfy({ UInt32($0, radix: 16) != nil }) else { return nil }
    var data: [UInt8] = []
    for token in tokens[headerTokens...] {
        guard token.count == 2, let byte = UInt8(token, radix: 16) else { return nil }
        data.append(byte)
    }
    return (tokens[..<headerTokens].joined(), data)
}

/// Turns one adapter reply into diagnostic frames, joining answers that span several CAN frames.
func parseELM(_ raw: String) -> ELMReply {
    let lines = elmLines(raw)
    for line in lines {
        if let failure = elmFailure(line) { return .failure(failure) }
    }
    let parsed = lines.map(canLine)
    guard !lines.isEmpty, parsed.allSatisfy({ $0 != nil }) else { return .text(lines) }

    var order: [String] = []
    var payload: [String: [UInt8]] = [:]
    var expected: [String: Int] = [:]
    for case let (ecu, data)? in parsed {
        guard let pci = data.first else { continue }
        if payload[ecu] == nil { order.append(ecu) }
        switch pci >> 4 {
        case 0: // single frame: low nibble is the length
            payload[ecu] = Array(data.dropFirst().prefix(Int(pci & 0x0F)))
        case 1: // first frame of a longer answer: 12-bit length
            guard data.count >= 2 else { continue }
            expected[ecu] = Int(pci & 0x0F) << 8 | Int(data[1])
            payload[ecu] = Array(data.dropFirst(2))
        case 2: // consecutive frame
            payload[ecu, default: []] += data.dropFirst()
        default: // flow control: nothing to read
            if payload[ecu] == nil { payload[ecu] = [] }
        }
    }
    let frames = order.map { ecu -> OBDFrame in
        var bytes = payload[ecu] ?? []
        if let total = expected[ecu], bytes.count > total { bytes = Array(bytes.prefix(total)) }
        return OBDFrame(ecu: ecu, bytes: bytes)
    }
    return .frames(frames)
}

// MARK: Which parameters the car supports

/// Decodes the four bitmap bytes answered to PID `base` (0x00, 0x20, 0x40...): bit 7 of the
/// first byte is PID base+1, bit 0 of the last is PID base+0x20.
func supportedPIDs(_ bitmap: [UInt8], base: UInt8) -> [UInt8] {
    var pids: [UInt8] = []
    for (i, byte) in bitmap.prefix(4).enumerated() {
        for bit in 0..<8 where byte & (0x80 >> UInt8(bit)) != 0 {
            let offset = i * 8 + bit + 1
            if Int(base) + offset <= 0xFF { pids.append(base + UInt8(offset)) }
        }
    }
    return pids
}

// MARK: Parameters (SAE J1979 service 01)

struct OBDParameter {
    let pid: UInt8
    let name: String
    let unit: String
    let digits: Int
    /// Value from the data bytes that follow "41 <pid>"; nil when there are too few.
    let decode: ([UInt8]) -> Double?
}

private func one(_ d: [UInt8], _ f: (Double) -> Double) -> Double? {
    d.count >= 1 ? f(Double(d[0])) : nil
}

private func two(_ d: [UInt8], _ f: (Double) -> Double) -> Double? {
    d.count >= 2 ? f(Double(Int(d[0]) << 8 | Int(d[1]))) : nil
}

private func parameter(_ pid: UInt8, _ name: String, _ unit: String, _ digits: Int,
                       _ decode: @escaping ([UInt8]) -> Double?) -> OBDParameter {
    OBDParameter(pid: pid, name: name, unit: unit, digits: digits, decode: decode)
}

private let percent: ([UInt8]) -> Double? = { one($0) { $0 * 100 / 255 } }
private let trim: ([UInt8]) -> Double? = { one($0) { ($0 - 128) * 100 / 128 } }
private let temperature: ([UInt8]) -> Double? = { one($0) { $0 - 40 } }

/// The parameters this app knows how to read. A car reports its own subset.
let obdParameters: [UInt8: OBDParameter] = {
    let list: [OBDParameter] = [
        parameter(0x04, "Obciążenie silnika", "%", 0, percent),
        parameter(0x05, "Temperatura płynu chłodzącego", "°C", 0, temperature),
        parameter(0x06, "Korekta paliwa krótka (bank 1)", "%", 1, trim),
        parameter(0x07, "Korekta paliwa długa (bank 1)", "%", 1, trim),
        parameter(0x0A, "Ciśnienie paliwa", "kPa", 0) { one($0) { $0 * 3 } },
        parameter(0x0B, "Ciśnienie w dolocie", "kPa", 0) { one($0) { $0 } },
        parameter(0x0C, "Obroty silnika", "obr./min", 0) { two($0) { $0 / 4 } },
        parameter(0x0D, "Prędkość", "km/h", 0) { one($0) { $0 } },
        parameter(0x0E, "Wyprzedzenie zapłonu", "°", 1) { one($0) { $0 / 2 - 64 } },
        parameter(0x0F, "Temperatura powietrza dolotowego", "°C", 0, temperature),
        parameter(0x10, "Przepływ powietrza (MAF)", "g/s", 2) { two($0) { $0 / 100 } },
        parameter(0x11, "Przepustnica", "%", 0, percent),
        parameter(0x14, "Sonda lambda 1 (przed katalizatorem)", "V", 3) { one($0) { $0 / 200 } },
        parameter(0x15, "Sonda lambda 2 (za katalizatorem)", "V", 3) { one($0) { $0 / 200 } },
        parameter(0x1F, "Czas pracy silnika", "s", 0) { two($0) { $0 } },
        parameter(0x21, "Dystans z zapaloną kontrolką silnika", "km", 0) { two($0) { $0 } },
        parameter(0x23, "Ciśnienie w listwie paliwowej", "kPa", 0) { two($0) { $0 * 10 } },
        parameter(0x2C, "Zadany EGR", "%", 0, percent),
        parameter(0x2E, "Odpowietrzanie zbiornika (EVAP)", "%", 0, percent),
        parameter(0x2F, "Poziom paliwa", "%", 0, percent),
        parameter(0x30, "Rozgrzania od kasowania błędów", "", 0) { one($0) { $0 } },
        parameter(0x31, "Dystans od kasowania błędów", "km", 0) { two($0) { $0 } },
        parameter(0x33, "Ciśnienie atmosferyczne", "kPa", 0) { one($0) { $0 } },
        parameter(0x3C, "Temperatura katalizatora", "°C", 0) { two($0) { $0 / 10 - 40 } },
        parameter(0x42, "Napięcie sterownika", "V", 2) { two($0) { $0 / 1000 } },
        parameter(0x43, "Obciążenie bezwzględne", "%", 0) { two($0) { $0 * 100 / 255 } },
        parameter(0x44, "Zadana lambda", "", 3) { two($0) { $0 * 2 / 65536 } },
        parameter(0x45, "Przepustnica względna", "%", 0, percent),
        parameter(0x46, "Temperatura zewnętrzna", "°C", 0, temperature),
        parameter(0x47, "Przepustnica bezwzględna B", "%", 0, percent),
        parameter(0x49, "Pedał gazu D", "%", 0, percent),
        parameter(0x4A, "Pedał gazu E", "%", 0, percent),
        parameter(0x4C, "Zadane otwarcie przepustnicy", "%", 0, percent),
        parameter(0x4D, "Czas z zapaloną kontrolką silnika", "min", 0) { two($0) { $0 } },
        parameter(0x4E, "Czas od kasowania błędów", "min", 0) { two($0) { $0 } },
        parameter(0x5A, "Pedał gazu względny", "%", 0, percent),
        parameter(0x5C, "Temperatura oleju", "°C", 0, temperature),
        parameter(0x5E, "Zużycie paliwa", "l/h", 2) { two($0) { $0 / 20 } },
    ]
    return Dictionary(uniqueKeysWithValues: list.map { ($0.pid, $0) })
}()

/// The data bytes of the answer to "01 <pid>" from `ecu`, or nil when that unit did not answer it.
func pidData(_ frames: [OBDFrame], pid: UInt8, ecu: String) -> [UInt8]? {
    guard let frame = frames.first(where: { $0.ecu == ecu && $0.bytes.count >= 2 && $0.bytes[0] == 0x41 && $0.bytes[1] == pid })
    else { return nil }
    return Array(frame.bytes.dropFirst(2))
}

// MARK: Reading while driving

/// Read every round: what the fuel figure and the gauges are made of.
let obdFastPIDs: [UInt8] = [0x0C, 0x0D, 0x10, 0x5E]

/// The parameters to read in round number `round`: the fast ones every time, the others one per round in turn.
// ponytail: one request per parameter; CAN allows six in one request if the rate turns out too low on the car.
func pollRound(_ live: [UInt8], round: Int) -> [UInt8] {
    let fast = live.filter { obdFastPIDs.contains($0) }, slow = live.filter { !obdFastPIDs.contains($0) }
    return slow.isEmpty ? fast : fast + [slow[max(0, round) % slow.count]]
}

let carValueMaxAge = 5.0 // s; an older reading is not saved with a fix any more
let carStaleAfter = 90.0 // s; a parameter not read for this long (the car stopped answering it) is not shown or warned about
let maxTroubleCodes = 32 // more than any car stores; a faulty adapter cannot make the list grow without end

/// The latest decoded value of each parameter (keyed by its number) with the time it was read.
struct CarValues {
    private(set) var values: [Int: Double] = [:]
    private var times: [Int: Date] = [:]
    private var taken = Date.distantPast

    mutating func set(_ pid: UInt8, _ value: Double, at time: Date) {
        values[Int(pid)] = value
        times[Int(pid)] = time
    }

    mutating func clear() {
        values = [:]
        times = [:]
    }

    /// When the current value of a parameter was read.
    func time(_ pid: UInt8) -> Date? { times[Int(pid)] }

    /// The values read within the last `maxAge` seconds: what signs and warnings may rely on.
    func current(at now: Date, maxAge: Double = carStaleAfter) -> [Int: Double] {
        values.filter { now.timeIntervalSince(times[$0.key] ?? .distantPast) <= maxAge }
    }

    /// Readings made since the last call, for the trip file: each is saved once, and never a stale one.
    mutating func take(at now: Date) -> [Int: Double]? {
        let since = max(taken, now.addingTimeInterval(-carValueMaxAge))
        taken = now
        let fresh = values.filter { (times[$0.key] ?? .distantPast) > since }
        return fresh.isEmpty ? nil : fresh
    }
}

// MARK: Fuel from the car

// Petrol. Both are averages; the correction factor in Settings absorbs the difference for a given car.
let petrolAirFuelRatio = 14.7 // g of air burnt per g of petrol
let petrolDensity = 745.0     // g per litre

/// Fuel flow in l/h: the car's own figure if it reports one, otherwise worked out from the air it draws.
// ponytail: on engine braking the injectors are shut but air still flows, so the air-flow path reads high;
// subtract those stretches (fuel system status, PID 0x03) if the correction factor is not enough.
func fuelRate(_ car: [Int: Double]) -> Double? {
    if let direct = car[0x5E] { return direct }
    if let maf = car[0x10] { return maf / petrolAirFuelRatio / petrolDensity * 3600 }
    return nil
}

func hexString(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
}

// MARK: Trouble codes (service 03, read only)

/// Codes from a CAN answer to service 03: "43 <count> <two bytes per code>...".
func decodeDTCs(_ bytes: [UInt8]) -> [String] {
    guard bytes.count >= 2, bytes[0] == 0x43 else { return [] }
    let letters = ["P", "C", "B", "U"]
    var codes: [String] = []
    var i = 2
    while i + 1 < bytes.count {
        let a = bytes[i], b = bytes[i + 1]
        i += 2
        if a == 0 && b == 0 { continue } // padding
        codes.append(letters[Int(a >> 6)] + String(format: "%X%X%02X", (a >> 4) & 0x3, a & 0x0F, b))
    }
    return codes
}

/// What a trouble code is about, from the standard numbering. Not a diagnosis: the code names the
/// circuit that reported, not the part that failed.
func dtcArea(_ code: String) -> String {
    let c = Array(code)
    guard c.count == 5 else { return "nieznany kod" }
    switch c[0] {
    case "C": return "podwozie (hamulce, zawieszenie, układ kierowniczy)"
    case "B": return "nadwozie (poduszki, klimatyzacja, oświetlenie)"
    case "U": return "komunikacja między sterownikami"
    default: break
    }
    if c[1] == "1" || c[1] == "3" { return "kod producenta auta (silnik lub skrzynia)" }
    switch c[2] {
    case "0", "1", "2": return "paliwo i powietrze (czujniki, wtryski, mieszanka)"
    case "3": return "zapłon, wypadanie zapłonów"
    case "4": return "emisja spalin (katalizator, EGR, odpowietrzanie zbiornika)"
    case "5": return "prędkość auta i bieg jałowy"
    case "6": return "sterownik silnika i jego wyjścia"
    default: return "skrzynia biegów"
    }
}

/// Names of Bluetooth devices that look like an OBD adapter.
func looksLikeOBDAdapter(_ name: String) -> Bool {
    let n = name.lowercased()
    return ["vlink", "v-link", "vgate", "icar", "obd", "elm", "viecar", "veepeak", "carista"].contains { n.contains($0) }
}

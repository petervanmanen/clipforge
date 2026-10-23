// Writes the sample FIT files used for App Review and manual testing:
//   docs/appstore/samples/sample-run.fit   (30 min run: heart rate, speed, distance, elevation)
//   docs/appstore/samples/sample-dive.fit  (40 min dive: depth, water temperature, heart rate)
// Usage: swift scripts/make_sample_fit.swift   (run from the repository root)
import Foundation

let fitEpochOffset: TimeInterval = 631_065_600

/// Minimal FIT encoder: little-endian definitions, one local message type per global message.
struct FITFile {
    private var body: [UInt8] = []
    private var defined: [UInt16: (local: UInt8, sizes: [Int])] = [:]

    /// Fields are (field number, size, base type, value).
    mutating func message(_ global: UInt16, _ fields: [(UInt8, Int, UInt8, UInt64)]) {
        let sizes = fields.map(\.1)
        if defined[global]?.sizes != sizes {
            let local = defined[global]?.local ?? UInt8(defined.count)
            body.append(0x40 | local)
            body += [0, 0, UInt8(global & 0xFF), UInt8(global >> 8), UInt8(fields.count)]
            for f in fields { body += [f.0, UInt8(f.1), f.2] }
            defined[global] = (local, sizes)
        }
        body.append(defined[global]!.local)
        for f in fields {
            for i in 0..<f.1 { body.append(UInt8((f.3 >> (8 * UInt64(i))) & 0xFF)) }
        }
    }

    var data: Data {
        var header: [UInt8] = [14, 0x20, 0x08, 0x08]
        let size = UInt32(body.count)
        header += [UInt8(size & 0xFF), UInt8((size >> 8) & 0xFF), UInt8((size >> 16) & 0xFF), UInt8(size >> 24)]
        header += Array(".FIT".utf8)
        let headerCRC = crc(header)
        header += [UInt8(headerCRC & 0xFF), UInt8(headerCRC >> 8)]
        let fileCRC = crc(header + body)
        return Data(header + body + [UInt8(fileCRC & 0xFF), UInt8(fileCRC >> 8)])
    }

    private func crc(_ bytes: [UInt8]) -> UInt16 {
        let table: [UInt16] = [0x0000, 0xCC01, 0xD801, 0x1400, 0xF001, 0x3C00, 0x2800, 0xE401,
                               0xA001, 0x6C00, 0x7800, 0xB401, 0x5000, 0x9C01, 0x8801, 0x4400]
        var crc: UInt16 = 0
        for byte in bytes {
            var tmp = table[Int(crc & 0xF)]
            crc = (crc >> 4) & 0x0FFF
            crc = crc ^ tmp ^ table[Int(byte & 0xF)]
            tmp = table[Int(crc & 0xF)]
            crc = (crc >> 4) & 0x0FFF
            crc = crc ^ tmp ^ table[Int((byte >> 4) & 0xF)]
        }
        return crc
    }
}

func fitTime(_ iso: String) -> UInt32 {
    UInt32(ISO8601DateFormatter().date(from: iso)!.timeIntervalSince1970 - fitEpochOffset)
}

let utcOffset: UInt32 = 2 * 3600 // local time CEST
let u32: UInt8 = 0x86, u16: UInt8 = 0x84, u8: UInt8 = 0x02, s8: UInt8 = 0x01, en: UInt8 = 0x00

func fileHeader(_ f: inout FITFile, start: UInt32) {
    // file_id: type activity, manufacturer development, time created
    f.message(0, [(0, 1, en, 4), (1, 2, u16, 255), (4, 4, u32, UInt64(start))])
}

func finish(_ f: inout FITFile, start: UInt32, end: UInt32, sport: UInt64, subSport: UInt64) {
    let elapsed = UInt64(end - start) * 1000
    f.message(18, [(253, 4, u32, UInt64(end)), (2, 4, u32, UInt64(start)), (7, 4, u32, elapsed),
                   (5, 1, en, sport), (6, 1, en, subSport)])
    f.message(34, [(253, 4, u32, UInt64(end)), (5, 4, u32, UInt64(end + utcOffset)), (1, 2, u16, 1)])
}

// Deterministic "noise" so the files are identical on every run.
func wobble(_ t: Double, _ a: Double, _ b: Double) -> Double { sin(t * a) * 0.6 + sin(t * b + 1.3) * 0.4 }

// MARK: Run — 30 min, warm-up, steady, final push.
func makeRun() -> Data {
    var f = FITFile()
    let start = fitTime("2026-10-18T07:30:00Z")
    fileHeader(&f, start: start)
    var distance = 0.0
    for i in 0...1800 {
        let t = Double(i)
        let phase = t < 300 ? t / 300 : (t > 1500 ? 1.2 : 1.0)
        let speed = 2.6 + 0.75 * min(phase, 1.2) + 0.12 * wobble(t, 0.05, 0.013) // m/s
        let hr = 105 + 50 * min(t / 420, 1) + (t > 1500 ? 14 * (t - 1500) / 300 : 0) + 3 * wobble(t, 0.03, 0.007)
        distance += speed
        let altitude = 12 + 18 * sin(t / 1800 * .pi) + 2 * wobble(t, 0.004, 0.011)
        f.message(20, [(253, 4, u32, UInt64(start) + UInt64(i)), (3, 1, u8, UInt64(hr.rounded())),
                       (73, 4, u32, UInt64(speed * 1000)), (5, 4, u32, UInt64(distance * 100)),
                       (78, 4, u32, UInt64((altitude + 500) * 5))])
    }
    finish(&f, start: start, end: start + 1800, sport: 1, subSport: 0)
    return f.data
}

// MARK: Dive — 40 min: descent to 18 m, bottom time, ascent, 3 min safety stop at 5 m.
func makeDive() -> Data {
    var f = FITFile()
    let start = fitTime("2026-10-19T09:15:00Z")
    fileHeader(&f, start: start)
    let total = 2400
    for i in 0...total {
        let t = Double(i)
        var depth: Double
        switch t {
        case ..<180: depth = 18 * t / 180                                  // descent
        case ..<1500: depth = 16.5 + 1.5 * wobble(t, 0.01, 0.0037)          // reef at 15–18 m
        case ..<1920: depth = 16.5 - 11.5 * (t - 1500) / 420                 // slow ascent to 5 m
        case ..<2100: depth = 5 + 0.3 * wobble(t, 0.05, 0.02)                // safety stop
        default: depth = max(0, 5 * (1 - (t - 2100) / 300))                  // surface
        }
        let temperature = 23 - 0.25 * depth
        let hr = 72 + 18 * min(t / 200, 1) - 6 * max(0, (t - 600) / 1800) + 2 * wobble(t, 0.02, 0.009)
        f.message(20, [(253, 4, u32, UInt64(start) + UInt64(i)), (92, 4, u32, UInt64(max(0, depth) * 1000)),
                       (13, 1, s8, UInt64(UInt8(bitPattern: Int8(temperature.rounded())))), (3, 1, u8, UInt64(hr.rounded()))])
    }
    finish(&f, start: start, end: start + UInt32(total), sport: 53, subSport: 53)
    return f.data
}

let folder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("docs/appstore/samples")
try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
try! makeRun().write(to: folder.appendingPathComponent("sample-run.fit"))
try! makeDive().write(to: folder.appendingPathComponent("sample-dive.fit"))
print("Wrote docs/appstore/samples/sample-run.fit and sample-dive.fit")

import XCTest
@testable import ClipForge

/// Builds small FIT files in memory.
struct FITWriter {
    private var body: [UInt8] = []

    mutating func define(local: UInt8, global: UInt16, fields: [(num: UInt8, size: UInt8, type: UInt8)]) {
        body.append(0x40 | local)
        body += [0, 0] // reserved, little endian
        body += [UInt8(global & 0xFF), UInt8(global >> 8)]
        body.append(UInt8(fields.count))
        for f in fields { body += [f.num, f.size, f.type] }
    }

    mutating func data(local: UInt8, values: [UInt64], sizes: [Int]) {
        body.append(local)
        append(values, sizes)
    }

    mutating func compressed(local: UInt8, offset: UInt8, values: [UInt64], sizes: [Int]) {
        body.append(0x80 | (local << 5) | (offset & 0x1F))
        append(values, sizes)
    }

    private mutating func append(_ values: [UInt64], _ sizes: [Int]) {
        for (v, size) in zip(values, sizes) {
            for i in 0..<size { body.append(UInt8((v >> (8 * UInt64(i))) & 0xFF)) }
        }
    }

    var data: Data {
        var header: [UInt8] = [14, 0x20, 0x08, 0x08]
        let size = UInt32(body.count)
        header += [UInt8(size & 0xFF), UInt8((size >> 8) & 0xFF), UInt8((size >> 16) & 0xFF), UInt8(size >> 24)]
        header += Array(".FIT".utf8) + [0, 0]
        return Data(header + body + [0, 0])
    }
}

final class FITTests: XCTestCase {
    static let start: UInt32 = 1_100_000_000 // FIT seconds

    /// A 120 s dive: depth ramps 0 → 20 m → 0, heart rate 80 → 140, water 18 °C.
    static func makeDive() -> Data {
        var w = FITWriter()
        w.define(local: 0, global: 20, fields: [(253, 4, 0x86), (3, 1, 0x02), (92, 4, 0x86), (13, 1, 0x01)])
        for i in 0...120 {
            let depth = Double(i <= 60 ? i : 120 - i) / 3 // m
            let values: [UInt64] = [UInt64(start) + UInt64(i), UInt64(80 + i / 2), UInt64(depth * 1000), 18]
            if i % 5 == 0 || i == 0 {
                w.data(local: 0, values: values, sizes: [4, 1, 4, 1])
            } else {
                // Same record via a compressed-timestamp header (no timestamp field).
                w.define(local: 1, global: 20, fields: [(3, 1, 0x02), (92, 4, 0x86), (13, 1, 0x01)])
                w.compressed(local: 1, offset: UInt8((start + UInt32(i)) & 0x1F), values: Array(values.dropFirst()), sizes: [1, 4, 1])
            }
        }
        w.define(local: 2, global: 18, fields: [(253, 4, 0x86), (5, 1, 0x00)])
        w.data(local: 2, values: [UInt64(start) + 120, 53], sizes: [4, 1])
        w.define(local: 3, global: 34, fields: [(253, 4, 0x86), (5, 4, 0x86)])
        w.data(local: 3, values: [UInt64(start) + 120, UInt64(start) + 120 + 7200], sizes: [4, 4])
        return w.data
    }

    /// A 60 s run at 3.33 m/s (5:00 /km) with heart rate 150.
    static func makeRun(start: UInt32 = start) -> Data {
        var w = FITWriter()
        w.define(local: 0, global: 20, fields: [(253, 4, 0x86), (3, 1, 0x02), (6, 2, 0x84), (5, 4, 0x86)])
        for i in 0...60 {
            w.data(local: 0, values: [UInt64(start) + UInt64(i), 150, 3333, UInt64(333 * i)], sizes: [4, 1, 2, 4])
        }
        w.define(local: 1, global: 18, fields: [(5, 1, 0x00)])
        w.data(local: 1, values: [1], sizes: [1])
        return w.data
    }

    func testDecodesDive() throws {
        let activity = try FITActivity.decode(Self.makeDive(), fileName: "dive.fit")
        XCTAssertTrue(activity.isDive)
        XCTAssertEqual(activity.sportName, "Diving")
        XCTAssertEqual(activity.utcOffset, 7200)
        XCTAssertEqual(activity.startDate, FITParser.date(fromFIT: Self.start))
        XCTAssertEqual(activity.endDate.timeIntervalSince(activity.startDate), 120, accuracy: 0.001)
        XCTAssertTrue(activity.availableMetrics.contains(.depth))
        XCTAssertTrue(activity.availableMetrics.contains(.heartRate))
        XCTAssertTrue(activity.availableMetrics.contains(.temperature))
        XCTAssertFalse(activity.availableMetrics.contains(.pace))

        let mid = activity.startDate.addingTimeInterval(60)
        XCTAssertEqual(try XCTUnwrap(activity.value(.depth, at: mid)), 20, accuracy: 0.01)
        // Compressed-timestamp records must land at the right time: 31 s → 10.33 m.
        XCTAssertEqual(try XCTUnwrap(activity.value(.depth, at: activity.startDate.addingTimeInterval(31))), 31.0 / 3, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(activity.value(.depth, at: activity.startDate.addingTimeInterval(30.5))), 30.5 / 3, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(activity.value(.temperature, at: mid)), 18)
        XCTAssertNil(activity.value(.depth, at: activity.startDate.addingTimeInterval(-60)))
    }

    func testDecodesRun() throws {
        let activity = try FITActivity.decode(Self.makeRun(), fileName: "run.fit")
        XCTAssertFalse(activity.isDive)
        XCTAssertEqual(activity.sportName, "Running")
        let t = activity.startDate.addingTimeInterval(30)
        XCTAssertEqual(try XCTUnwrap(activity.value(.heartRate, at: t)), 150)
        XCTAssertEqual(try XCTUnwrap(activity.value(.speed, at: t)), 3.333, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(activity.value(.distance, at: t)), 99.9, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(activity.value(.elapsed, at: t)), 30, accuracy: 0.001)
    }

    func testRejectsNonFIT() {
        XCTAssertThrowsError(try FITActivity.decode(Data("hello world, not a fit".utf8), fileName: "x"))
    }
}

final class TimelineTests: XCTestCase {
    func testTrimAndCuts() {
        var t = EditTimeline(sourceDuration: 100)
        t.setTrimStart(10)
        t.setTrimEnd(90)
        t.addCut(start: 40, end: 50)
        t.addCut(start: 45, end: 55) // merges
        XCTAssertEqual(t.cuts.count, 1)
        XCTAssertEqual(t.keptRanges, [10...40, 55...90])
        XCTAssertEqual(t.outputDuration, 65, accuracy: 1e-9)
        XCTAssertEqual(t.sourceTime(forOutput: 0), 10)
        XCTAssertEqual(t.sourceTime(forOutput: 35), 60, accuracy: 1e-9)
        XCTAssertEqual(t.outputTime(forSource: 60), 35, accuracy: 1e-9)
        XCTAssertEqual(t.outputTime(forSource: 47), 30, accuracy: 1e-9) // inside cut → next kept frame
        XCTAssertEqual(t.outputTime(forSource: 5), 0)
        XCTAssertTrue(t.isRemoved(source: 47))
        XCTAssertFalse(t.isRemoved(source: 20))
    }

    func testStabilizationPathStaysInsideCrop() {
        // A jittery pan.
        let n = 300
        let times = (0..<n).map { Double($0) / 30 }
        var rng = SystemRandomNumberGenerator()
        let x = (0..<n).map { Double($0) * 2 + Double.random(in: -15...15, using: &rng) }
        let y = (0..<n).map { _ in Double.random(in: -10...10, using: &rng) }
        let analysis = StabilizationAnalysis(times: times, x: x, y: y, frameSize: CGSize(width: 1920, height: 1080), frameRate: 30)
        let path = Stabilizer.path(for: analysis, settings: StabilizationSettings(enabled: true, strength: 0.6, maxCrop: 0.1))
        XCTAssertTrue(path.dx.allSatisfy { abs($0) <= 96.0001 })
        XCTAssertTrue(path.dy.allSatisfy { abs($0) <= 54.0001 })

        let corrected = zip(x, path.dx).map { $0 + $1 }
        XCTAssertLessThan(meanAcceleration(corrected), meanAcceleration(x) * 0.3)
    }
}

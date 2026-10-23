import Foundation

enum FITError: LocalizedError {
    case notAFITFile
    case truncated
    case noRecords

    var errorDescription: String? {
        switch self {
        case .notAFITFile: return "This is not a FIT file."
        case .truncated: return "The FIT file is truncated or corrupt."
        case .noRecords: return "The FIT file contains no activity records."
        }
    }
}

/// A decoded FIT data message. Only numeric fields are kept (first element of array fields).
struct FITMessage {
    let globalNumber: UInt16
    var fields: [UInt8: Double]
    /// Timestamp in FIT seconds (since 1989-12-31 00:00 UTC), from field 253 or a compressed header.
    var timestamp: UInt32?
}

/// Minimal, dependency-free decoder for the Garmin FIT protocol (used by Suunto, Garmin, Coros, ...).
enum FITParser {
    /// Seconds between the Unix epoch and the FIT epoch (1989-12-31T00:00:00Z).
    static let fitEpochOffset: TimeInterval = 631_065_600

    static func date(fromFIT seconds: UInt32) -> Date {
        Date(timeIntervalSince1970: TimeInterval(seconds) + fitEpochOffset)
    }

    private struct FieldDef {
        let number: UInt8
        let size: Int
        let baseType: UInt8
    }

    private struct MessageDef {
        let globalNumber: UInt16
        let bigEndian: Bool
        let fields: [FieldDef]
        let developerDataSize: Int
    }

    static func parse(_ data: Data) throws -> [FITMessage] {
        let bytes = [UInt8](data)
        var messages: [FITMessage] = []
        var offset = 0
        var parsedAny = false

        // A FIT file may contain several chained FIT "files"; decode each in turn.
        while offset + 12 <= bytes.count {
            let headerSize = Int(bytes[offset])
            guard headerSize >= 12, offset + headerSize <= bytes.count,
                  bytes[offset + 8] == 0x2E, bytes[offset + 9] == 0x46,
                  bytes[offset + 10] == 0x49, bytes[offset + 11] == 0x54 // ".FIT"
            else {
                if parsedAny { break }
                throw FITError.notAFITFile
            }
            let dataSize = Int(readUInt(bytes, offset + 4, 4, bigEndian: false))
            let start = offset + headerSize
            let end = min(start + dataSize, bytes.count)
            try parseRecords(bytes, from: start, to: end, into: &messages)
            parsedAny = true
            offset = end + 2 // skip CRC
        }
        return messages
    }

    private static func parseRecords(_ b: [UInt8], from start: Int, to end: Int, into messages: inout [FITMessage]) throws {
        var definitions: [UInt8: MessageDef] = [:]
        var lastTimestamp: UInt32 = 0
        var p = start

        func need(_ n: Int) throws {
            if p + n > end { throw FITError.truncated }
        }

        func readData(_ def: MessageDef, compressedTimestamp: UInt32?) throws {
            var msg = FITMessage(globalNumber: def.globalNumber, fields: [:], timestamp: compressedTimestamp)
            for field in def.fields {
                try need(field.size)
                if let value = decodeValue(b, p, size: field.size, baseType: field.baseType, bigEndian: def.bigEndian) {
                    msg.fields[field.number] = value
                    if field.number == 253 {
                        lastTimestamp = UInt32(value)
                        msg.timestamp = lastTimestamp
                    }
                }
                p += field.size
            }
            try need(def.developerDataSize)
            p += def.developerDataSize
            messages.append(msg)
        }

        while p < end {
            let header = b[p]
            p += 1

            if header & 0x80 != 0 {
                // Compressed timestamp header: data message with a 5-bit time offset.
                let local = (header >> 5) & 0x03
                let timeOffset = UInt32(header & 0x1F)
                var ts = (lastTimestamp & ~UInt32(0x1F)) + timeOffset
                if timeOffset < (lastTimestamp & 0x1F) { ts += 0x20 }
                lastTimestamp = ts
                guard let def = definitions[local] else { throw FITError.truncated }
                try readData(def, compressedTimestamp: ts)
            } else if header & 0x40 != 0 {
                // Definition message.
                let hasDeveloperData = header & 0x20 != 0
                let local = header & 0x0F
                try need(5)
                let bigEndian = b[p + 1] == 1
                let global = UInt16(readUInt(b, p + 2, 2, bigEndian: bigEndian))
                let count = Int(b[p + 4])
                p += 5
                try need(count * 3)
                var fields: [FieldDef] = []
                fields.reserveCapacity(count)
                for i in 0..<count {
                    fields.append(FieldDef(number: b[p + i * 3], size: Int(b[p + i * 3 + 1]), baseType: b[p + i * 3 + 2]))
                }
                p += count * 3
                var devSize = 0
                if hasDeveloperData {
                    try need(1)
                    let devCount = Int(b[p])
                    p += 1
                    try need(devCount * 3)
                    for i in 0..<devCount { devSize += Int(b[p + i * 3 + 1]) }
                    p += devCount * 3
                }
                definitions[local] = MessageDef(globalNumber: global, bigEndian: bigEndian, fields: fields, developerDataSize: devSize)
            } else {
                let local = header & 0x0F
                guard let def = definitions[local] else { throw FITError.truncated }
                try readData(def, compressedTimestamp: nil)
            }
        }
    }

    private static func readUInt(_ b: [UInt8], _ offset: Int, _ size: Int, bigEndian: Bool) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<size {
            let byte = UInt64(b[offset + (bigEndian ? i : size - 1 - i)])
            v = (v << 8) | byte
        }
        return v
    }

    /// Decodes the first element of a field, returning nil for strings, byte arrays and FIT "invalid" values.
    private static func decodeValue(_ b: [UInt8], _ offset: Int, size: Int, baseType: UInt8, bigEndian: Bool) -> Double? {
        let type = baseType & 0x1F
        let width: Int
        switch type {
        case 0, 1, 2, 10, 13: width = 1
        case 3, 4, 11: width = 2
        case 5, 6, 8, 12: width = 4
        case 9, 14, 15, 16: width = 8
        default: return nil // 7 = string
        }
        guard size >= width else { return nil }
        let raw = readUInt(b, offset, width, bigEndian: bigEndian)

        switch type {
        case 0, 2, 13: return raw == 0xFF ? nil : Double(raw)
        case 10: return raw == 0 ? nil : Double(raw)
        case 1: return raw == 0x7F ? nil : Double(Int8(truncatingIfNeeded: raw))
        case 3: return raw == 0x7FFF ? nil : Double(Int16(truncatingIfNeeded: raw))
        case 4: return raw == 0xFFFF ? nil : Double(raw)
        case 11: return raw == 0 ? nil : Double(raw)
        case 5: return raw == 0x7FFF_FFFF ? nil : Double(Int32(truncatingIfNeeded: raw))
        case 6: return raw == 0xFFFF_FFFF ? nil : Double(raw)
        case 12: return raw == 0 ? nil : Double(raw)
        case 8:
            guard raw != 0xFFFF_FFFF else { return nil }
            let f = Float(bitPattern: UInt32(raw))
            return f.isFinite ? Double(f) : nil
        case 9:
            guard raw != UInt64.max else { return nil }
            let d = Double(bitPattern: raw)
            return d.isFinite ? d : nil
        case 14: return raw == 0x7FFF_FFFF_FFFF_FFFF ? nil : Double(Int64(bitPattern: raw))
        case 15: return raw == UInt64.max ? nil : Double(raw)
        case 16: return raw == 0 ? nil : Double(raw)
        default: return nil
        }
    }
}

import Foundation

/// Little-endian byte writer.
struct ByteWriter {
    private(set) var data = Data()

    mutating func u8(_ v: UInt8) { data.append(v) }
    mutating func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    mutating func bytes(_ d: Data) { data.append(d) }
}

/// Little-endian byte reader over a contiguous array.
struct ByteReader {
    let bytes: [UInt8]
    private(set) var offset: Int

    init(_ bytes: [UInt8], offset: Int = 0) {
        self.bytes = bytes
        self.offset = offset
    }

    var remaining: Int { bytes.count - offset }

    mutating func u8() throws -> UInt8 {
        guard remaining >= 1 else { throw BCError.malformedHeader }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func u16() throws -> UInt16 {
        guard remaining >= 2 else { throw BCError.malformedHeader }
        defer { offset += 2 }
        return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    mutating func u32() throws -> UInt32 {
        guard remaining >= 4 else { throw BCError.malformedHeader }
        defer { offset += 4 }
        return UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }

    mutating func take(_ n: Int) throws -> ArraySlice<UInt8> {
        guard n >= 0, remaining >= n else { throw BCError.malformedHeader }
        defer { offset += n }
        return bytes[offset..<(offset + n)]
    }

    mutating func skip(_ n: Int) throws { _ = try take(n) }
}

extension Data {
    /// Reads a little-endian UInt32 at `offset` relative to the start of this Data.
    func le32(at offset: Int) -> UInt32 {
        let i = startIndex + offset
        return UInt32(self[i]) | UInt32(self[i + 1]) << 8 | UInt32(self[i + 2]) << 16 | UInt32(self[i + 3]) << 24
    }
}

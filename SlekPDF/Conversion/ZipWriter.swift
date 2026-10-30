import Compression
import Foundation

/// Minimal ZIP writer for Office Open XML packages (DOCX/XLSX): deflate via Apple's Compression framework,
/// no third-party code. Entry names are ASCII paths inside the package.
nonisolated struct ZipWriter {
    private var body = Data()
    private var central = Data()
    private var count: UInt16 = 0

    mutating func add(_ path: String, _ string: String) {
        add(path, Data(string.utf8))
    }

    mutating func add(_ path: String, _ data: Data) {
        let name = Data(path.utf8)
        let crc = CRC32.checksum(data)
        let deflated = Self.deflate(data)
        let (method, payload): (UInt16, Data) = deflated.map { $0.count < data.count ? (8, $0) : (0, data) } ?? (0, data)
        let offset = UInt32(body.count)
        let (time, date) = Self.dosTimestamp(Date())

        var local = Data()
        local.append(le: UInt32(0x0403_4b50))
        local.append(le: UInt16(20)); local.append(le: UInt16(0)); local.append(le: method)
        local.append(le: time); local.append(le: date); local.append(le: crc)
        local.append(le: UInt32(payload.count)); local.append(le: UInt32(data.count))
        local.append(le: UInt16(name.count)); local.append(le: UInt16(0))
        body.append(local); body.append(name); body.append(payload)

        var entry = Data()
        entry.append(le: UInt32(0x0201_4b50))
        entry.append(le: UInt16(20)); entry.append(le: UInt16(20)); entry.append(le: UInt16(0)); entry.append(le: method)
        entry.append(le: time); entry.append(le: date); entry.append(le: crc)
        entry.append(le: UInt32(payload.count)); entry.append(le: UInt32(data.count))
        entry.append(le: UInt16(name.count)); entry.append(le: UInt16(0)); entry.append(le: UInt16(0))
        entry.append(le: UInt16(0)); entry.append(le: UInt16(0)); entry.append(le: UInt32(0)); entry.append(le: offset)
        central.append(entry); central.append(name)
        count += 1
    }

    func finish() -> Data {
        var out = body
        out.append(central)
        var end = Data()
        end.append(le: UInt32(0x0605_4b50))
        end.append(le: UInt16(0)); end.append(le: UInt16(0)); end.append(le: count); end.append(le: count)
        end.append(le: UInt32(central.count)); end.append(le: UInt32(body.count)); end.append(le: UInt16(0))
        out.append(end)
        return out
    }

    /// Raw DEFLATE (RFC 1951), as ZIP method 8 requires; `COMPRESSION_ZLIB` emits exactly that.
    private static func deflate(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        let capacity = data.count + 1024
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                          src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        return output.prefix(written)
    }

    private static func dosTimestamp(_ date: Date) -> (UInt16, UInt16) {
        let c = Calendar(identifier: .gregorian).dateComponents(in: .current, from: date)
        let time = UInt16((c.hour ?? 0) << 11 | (c.minute ?? 0) << 5 | (c.second ?? 0) / 2)
        let day = UInt16(((c.year ?? 1980) - 1980) << 9 | (c.month ?? 1) << 5 | (c.day ?? 1))
        return (time, day)
    }
}

nonisolated enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    nonisolated mutating func append<T: FixedWidthInteger>(le value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}

nonisolated extension String {
    /// Escapes text for XML element content/attributes and drops characters XML 1.0 forbids.
    var xmlEscaped: String {
        var out = ""
        out.reserveCapacity(utf8.count)
        for scalar in unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "\t", "\n", "\r": out.unicodeScalars.append(scalar)
            case _ where scalar.value < 0x20 || (0xFFFE...0xFFFF).contains(scalar.value): continue
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}

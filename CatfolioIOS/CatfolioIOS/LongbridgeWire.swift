import Foundation
import zlib

/// The small protobuf subset used by the read-only quote protocol.
/// Field numbers and framing follow longbridge/openapi-protobufs and
/// longbridge/openapi rust/crates/wsclient/src/codec.rs.
struct LongbridgeProto {
    enum Value {
        case integer(UInt64), bytes(Data)
    }
    var fields: [Int: [Value]] = [:]

    init(_ data: Data) throws {
        let bytes = Array(data)
        var offset = 0
        func varint() throws -> UInt64 {
            var result: UInt64 = 0
            for shift in stride(from: 0, through: 63, by: 7) {
                guard offset < bytes.count else { throw ChinaMarketError.invalidData }
                let byte = bytes[offset]; offset += 1
                if shift == 63 && byte > 1 { throw ChinaMarketError.invalidData }
                result |= UInt64(byte & 127) << shift
                if byte < 128 { return result }
            }
            throw ChinaMarketError.invalidData
        }
        while offset < bytes.count {
            let key = try varint()
            guard key >> 3 > 0, key >> 3 <= 536_870_911 else { throw ChinaMarketError.invalidData }
            let field = Int(key >> 3)
            switch key & 7 {
            case 0: fields[field, default: []].append(.integer(try varint()))
            case 2:
                let count = try varint()
                guard count <= UInt64(bytes.count - offset) else { throw ChinaMarketError.invalidData }
                fields[field, default: []].append(.bytes(Data(bytes[offset..<(offset + Int(count))])))
                offset += Int(count)
            case 1, 5:
                let count = key & 7 == 1 ? 8 : 4
                guard offset + count <= bytes.count else { throw ChinaMarketError.invalidData }
                offset += count
            default: throw ChinaMarketError.invalidData
            }
        }
    }
    func messages(_ field: Int) throws -> [LongbridgeProto] {
        try (fields[field] ?? []).map {
            guard case .bytes(let data) = $0 else { throw ChinaMarketError.invalidData }
            return try LongbridgeProto(data)
        }
    }
    func string(_ field: Int) -> String? {
        guard case .bytes(let data) = fields[field]?.first else { return nil }
        return String(data: data, encoding: .utf8)
    }
    func integer(_ field: Int) -> UInt64? {
        guard case .integer(let number) = fields[field]?.first else { return nil }
        return number
    }
    func number(_ field: Int) -> Double? {
        guard let text = string(field), let value = Double(text), value.isFinite else { return nil }
        return value
    }
    static func varint(_ input: UInt64) -> Data {
        var value = input, data = Data()
        while value >= 128 { data.append(UInt8(value & 127) | 128); value >>= 7 }
        data.append(UInt8(value))
        return data
    }
    static func integer(_ field: Int, _ value: UInt64) -> Data { varint(UInt64(field << 3)) + varint(value) }
    static func bytes(_ field: Int, _ value: Data) -> Data {
        varint(UInt64(field << 3 | 2)) + varint(UInt64(value.count)) + value
    }
    static func string(_ field: Int, _ value: String) -> Data { bytes(field, Data(value.utf8)) }
}

struct LongbridgePacket {
    let type: UInt8
    let command: UInt8
    let requestID: UInt32
    let status: UInt8
    let body: Data

    static func request(command: UInt8, id: UInt32, body: Data) -> Data {
        Data([1, command]) + bigEndian(id, count: 4) + bigEndian(10_000, count: 2)
            + bigEndian(UInt32(body.count), count: 3) + body
    }
    static func bigEndian(_ number: UInt32, count: Int) -> Data {
        Data((0..<count).reversed().map { UInt8(truncatingIfNeeded: number >> ($0 * 8)) })
    }
    static func decode(_ data: Data) throws -> Self {
        let bytes = Array(data)
        guard bytes.count >= 5, bytes[0] & 0xC0 == 0 else { throw ChinaMarketError.invalidData }
        let type = bytes[0] & 15
        let header = type == 1 ? 11 : type == 2 ? 10 : type == 3 ? 5 : 0
        guard header > 0, bytes.count >= header else { throw ChinaMarketError.invalidData }
        func number(_ start: Int, _ count: Int) -> UInt32 {
            bytes[start..<(start + count)].reduce(0) { ($0 << 8) | UInt32($1) }
        }
        let length = Int(number(header - 3, 3))
        let signatureLength = bytes[0] & 16 != 0 ? 24 : 0
        guard bytes.count == header + length + signatureLength else { throw ChinaMarketError.invalidData }
        var body = Data(bytes[header..<(header + length)])
        if bytes[0] & 32 != 0 { body = try gunzip(body) }
        return .init(type: type, command: bytes[1], requestID: type == 3 ? 0 : number(2, 4),
                     status: type == 2 ? bytes[6] : 0, body: body)
    }
    private static func gunzip(_ data: Data) throws -> Data {
        var stream = z_stream()
        guard inflateInit2_(&stream, 15 + 32, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw ChinaMarketError.invalidData
        }
        defer { inflateEnd(&stream) }
        return try data.withUnsafeBytes { raw in
            stream.next_in = UnsafeMutablePointer(mutating: raw.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(data.count)
            var result = Data()
            var status: Int32 = Z_OK
            repeat {
                var buffer = [UInt8](repeating: 0, count: 16_384)
                status = buffer.withUnsafeMutableBufferPointer { output in
                    stream.next_out = output.baseAddress
                    stream.avail_out = uInt(output.count)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                guard status == Z_OK || status == Z_STREAM_END else { throw ChinaMarketError.invalidData }
                result.append(contentsOf: buffer.prefix(buffer.count - Int(stream.avail_out)))
                guard result.count <= 16 * 1024 * 1024 else { throw ChinaMarketError.invalidData }
            } while status != Z_STREAM_END
            return result
        }
    }
}

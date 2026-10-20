import Foundation

/// A compact MessagePack decoder, enough to read Lightroom's Managed Catalog revisions.
/// Decodes into plain Foundation values (Dictionary/Array/String/Int64/Double/Bool/Data/NSNull).
public enum MessagePack {
    public struct DecodeError: Error, CustomStringConvertible {
        public let message: String
        public var description: String { "MessagePack: \(message)" }
    }

    public static func decode(_ data: Data) throws -> Any {
        var reader = Reader(data: data)
        return try reader.readValue()
    }

    /// Decodes and converts to a JSON-compatible object (Data → base64 string, Int64 → NSNumber).
    public static func decodeJSONObject(_ data: Data) throws -> Any {
        try jsonify(decode(data))
    }

    static func jsonify(_ v: Any) -> Any {
        switch v {
        case let d as [String: Any]: return d.mapValues(jsonify)
        case let a as [Any]: return a.map(jsonify)
        case let data as Data: return data.base64EncodedString()
        case let dict as [AnyHashable: Any]:
            var out: [String: Any] = [:]
            for (k, val) in dict { out[String(describing: k.base)] = jsonify(val) }
            return out
        default: return v
        }
    }

    struct Reader {
        let data: Data
        var pos: Int
        init(data: Data) { self.data = data; self.pos = data.startIndex }

        mutating func byte() throws -> UInt8 {
            guard pos < data.endIndex else { throw DecodeError(message: "unexpected end") }
            let b = data[pos]; pos += 1; return b
        }
        mutating func bytes(_ n: Int) throws -> Data {
            guard n >= 0, pos + n <= data.endIndex else { throw DecodeError(message: "unexpected end reading \(n) bytes") }
            let d = data.subdata(in: pos..<(pos + n)); pos += n; return d
        }
        mutating func uint(_ n: Int) throws -> UInt64 {
            var v: UInt64 = 0
            for _ in 0..<n { v = (v << 8) | UInt64(try byte()) }
            return v
        }
        mutating func string(_ n: Int) throws -> String {
            let d = try bytes(n)
            return String(data: d, encoding: .utf8) ?? String(decoding: d, as: UTF8.self)
        }

        mutating func readValue() throws -> Any {
            let b = try byte()
            switch b {
            case 0x00...0x7f: return Int64(b)
            case 0x80...0x8f: return try readMap(Int(b & 0x0f))
            case 0x90...0x9f: return try readArray(Int(b & 0x0f))
            case 0xa0...0xbf: return try string(Int(b & 0x1f))
            case 0xc0: return NSNull()
            case 0xc2: return false
            case 0xc3: return true
            case 0xc4: return try bytes(Int(try uint(1)))
            case 0xc5: return try bytes(Int(try uint(2)))
            case 0xc6: return try bytes(Int(try uint(4)))
            case 0xc7: let n = Int(try uint(1)); _ = try byte(); return try bytes(n)
            case 0xc8: let n = Int(try uint(2)); _ = try byte(); return try bytes(n)
            case 0xc9: let n = Int(try uint(4)); _ = try byte(); return try bytes(n)
            case 0xca: return Double(Float(bitPattern: UInt32(try uint(4))))
            case 0xcb: return Double(bitPattern: try uint(8))
            case 0xcc: return Int64(try uint(1))
            case 0xcd: return Int64(try uint(2))
            case 0xce: return Int64(try uint(4))
            case 0xcf:
                let v = try uint(8)
                return v <= UInt64(Int64.max) ? Int64(v) : Double(v)
            case 0xd0: return Int64(Int8(bitPattern: UInt8(try uint(1))))
            case 0xd1: return Int64(Int16(bitPattern: UInt16(try uint(2))))
            case 0xd2: return Int64(Int32(bitPattern: UInt32(try uint(4))))
            case 0xd3: return Int64(bitPattern: try uint(8))
            case 0xd4: _ = try byte(); return try bytes(1)
            case 0xd5: _ = try byte(); return try bytes(2)
            case 0xd6: _ = try byte(); return try bytes(4)
            case 0xd7: _ = try byte(); return try bytes(8)
            case 0xd8: _ = try byte(); return try bytes(16)
            case 0xd9: return try string(Int(try uint(1)))
            case 0xda: return try string(Int(try uint(2)))
            case 0xdb: return try string(Int(try uint(4)))
            case 0xdc: return try readArray(Int(try uint(2)))
            case 0xdd: return try readArray(Int(try uint(4)))
            case 0xde: return try readMap(Int(try uint(2)))
            case 0xdf: return try readMap(Int(try uint(4)))
            case 0xe0...0xff: return Int64(Int8(bitPattern: b))
            default: throw DecodeError(message: "unknown type byte \(b)")
            }
        }

        mutating func readArray(_ n: Int) throws -> [Any] {
            var a: [Any] = []; a.reserveCapacity(n)
            for _ in 0..<n { a.append(try readValue()) }
            return a
        }

        mutating func readMap(_ n: Int) throws -> [String: Any] {
            var m: [String: Any] = [:]
            for _ in 0..<n {
                let k = try readValue()
                let v = try readValue()
                let key: String
                if let s = k as? String { key = s } else { key = String(describing: k) }
                m[key] = v
            }
            return m
        }
    }
}

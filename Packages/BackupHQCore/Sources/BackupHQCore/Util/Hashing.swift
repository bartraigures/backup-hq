import Foundation
import CryptoKit

public enum Hashing {
    public static let chunkSize = 4 * 1024 * 1024

    /// Streams a file through SHA-256. Calls `progress` with bytes hashed so far. Honours cancellation.
    public static func sha256Hex(of url: URL, progress: ((Int64) -> Void)? = nil) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var total: Int64 = 0
        while true {
            if Task.isCancelled { throw CancellationError() }
            let chunk = try handle.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
            total += Int64(chunk.count)
            progress?(total)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

import Foundation
import CryptoKit

/// Persistable state of an in-progress multipart upload, so an interrupted upload can be resumed later.
public struct S3UploadResumeState: Codable, Sendable, Equatable {
    public var uploadId: String
    public var partSize: Int
    public var completedParts: [S3MultipartPart]

    public init(uploadId: String, partSize: Int, completedParts: [S3MultipartPart]) {
        self.uploadId = uploadId; self.partSize = partSize; self.completedParts = completedParts
    }
}

public struct S3UploadResult: Sendable {
    public var info: S3ObjectInfo
    public var usedMultipart: Bool
}

public struct S3UploadError: Error, LocalizedError, Sendable {
    public var message: String
    public init(message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// High-level, resumable, checksum-verified file upload on top of `S3Client`.
public enum S3Uploader {
    public static let multipartThreshold = 64 * 1024 * 1024
    public static let defaultPartSize = 64 * 1024 * 1024
    static let maxParts = 10_000

    /// Uploads `fileURL` to `key`.
    ///
    /// - Files up to `multipartThreshold` go in a single PUT carrying the full-object SHA-256, which S3 verifies.
    /// - Larger files use multipart with a SHA-256 per part. `onStateChange` fires after each part so the caller can
    ///   persist `S3UploadResumeState`; pass it back as `resume` to continue a stopped upload (the server's part list
    ///   is treated as the truth; a vanished upload id starts over).
    /// - `progress` receives total bytes uploaded so far, including parts that were already complete on resume.
    /// - After completion the object is HEADed and its size compared to `fileSize`.
    /// - Task cancellation is honoured between parts and does NOT abort the multipart upload, so it stays resumable.
    public static func upload(client: S3Client, key: String, fileURL: URL, fileSize: Int64, sha256Hex: String, contentType: String?,
                              storageClass: S3StorageClass, metadata: [String: String], resume: S3UploadResumeState?,
                              onStateChange: @escaping @Sendable (S3UploadResumeState) async -> Void,
                              progress: @escaping @Sendable (Int64) -> Void) async throws -> S3UploadResult {
        var meta = metadata
        if meta["sha256"] == nil { meta["sha256"] = sha256Hex.lowercased() }

        if fileSize <= Int64(multipartThreshold) {
            let info = try await client.putObject(key: key, fileURL: fileURL, sha256Hex: sha256Hex, contentType: contentType,
                                                  storageClass: storageClass, metadata: meta, progress: progress)
            progress(fileSize)
            let verified = try await verifySize(client: client, key: key, expected: fileSize, fallback: info)
            return S3UploadResult(info: verified, usedMultipart: false)
        }

        // --- Multipart ---
        var partSize = resume?.partSize ?? defaultPartSize
        while Int64(partSize) * Int64(maxParts) < fileSize { partSize *= 2 }
        let partCount = Int((fileSize + Int64(partSize) - 1) / Int64(partSize))

        var uploadId: String
        var done: [Int: S3MultipartPart] = [:]
        if let resume {
            uploadId = resume.uploadId
            do {
                // Server state wins; also drop any part whose size disagrees with what we would send.
                for p in try await client.listParts(key: key, uploadId: uploadId) where expectedPartSize(p.partNumber, partSize: partSize, partCount: partCount, fileSize: fileSize) == p.size {
                    done[p.partNumber] = p
                }
            } catch let e as S3Error where e.code == "NoSuchUpload" || e.statusCode == 404 {
                uploadId = try await client.createMultipartUpload(key: key, contentType: contentType, storageClass: storageClass, metadata: meta)
                done = [:]
            }
        } else {
            uploadId = try await client.createMultipartUpload(key: key, contentType: contentType, storageClass: storageClass, metadata: meta)
        }

        var uploaded = done.values.reduce(Int64(0)) { $0 + $1.size }
        progress(uploaded)
        await onStateChange(S3UploadResumeState(uploadId: uploadId, partSize: partSize, completedParts: done.values.sorted { $0.partNumber < $1.partNumber }))

        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        for partNumber in 1...partCount where done[partNumber] == nil {
            try Task.checkCancellation()
            let offset = UInt64(partNumber - 1) * UInt64(partSize)
            let length = Int(expectedPartSize(partNumber, partSize: partSize, partCount: partCount, fileSize: fileSize))
            try handle.seek(toOffset: offset)
            guard let data = try handle.read(upToCount: length), data.count == length else {
                throw S3UploadError(message: "Short read at part \(partNumber) of \(fileURL.lastPathComponent); file changed during upload?")
            }
            let part = try await client.uploadPart(key: key, uploadId: uploadId, partNumber: partNumber, data: data)
            done[partNumber] = part
            uploaded += Int64(length)
            progress(uploaded)
            await onStateChange(S3UploadResumeState(uploadId: uploadId, partSize: partSize, completedParts: done.values.sorted { $0.partNumber < $1.partNumber }))
        }

        let parts = done.values.sorted { $0.partNumber < $1.partNumber }
        guard parts.count == partCount else {
            throw S3UploadError(message: "Expected \(partCount) parts but have \(parts.count) for \(key)")
        }
        let info = try await client.completeMultipartUpload(key: key, uploadId: uploadId, parts: parts)
        let verified = try await verifySize(client: client, key: key, expected: fileSize, fallback: info)
        return S3UploadResult(info: verified, usedMultipart: true)
    }

    static func expectedPartSize(_ partNumber: Int, partSize: Int, partCount: Int, fileSize: Int64) -> Int64 {
        partNumber < partCount ? Int64(partSize) : fileSize - Int64(partSize) * Int64(partCount - 1)
    }

    /// HEADs the object and checks the stored size; returns the HEAD info (richer than the PUT response).
    static func verifySize(client: S3Client, key: String, expected: Int64, fallback: S3ObjectInfo) async throws -> S3ObjectInfo {
        guard let head = try await client.headObject(key: key) else {
            throw S3UploadError(message: "Upload of \(key) reported success but HEAD finds no object")
        }
        guard head.size == expected else {
            throw S3UploadError(message: "Size mismatch for \(key): S3 has \(head.size) bytes, expected \(expected)")
        }
        return head
    }
}

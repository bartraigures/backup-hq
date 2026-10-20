import Foundation
import CryptoKit
import BackupHQCore

/// `backuphq-cli s3 ...` subcommands. Called with the arguments after `s3`.
func runS3Command(_ args: [String]) async throws {
    guard let sub = args.first else { printS3Usage(); return }
    let opts = parseOptions(Array(args.dropFirst()))

    func makeClient(bucket: String) throws -> S3Client {
        let profile = opts["profile"] ?? "default"
        let loaded = try AWSCredentialsFile.load(profile: profile)
        let region = opts["region"] ?? loaded.region ?? "us-east-1"
        return S3Client(config: S3Config(region: region, bucket: bucket), credentials: loaded.credentials)
    }

    switch sub {
    case "buckets":
        let client = try makeClient(bucket: "-")
        for b in try await client.listBuckets() { print(b) }

    case "head":
        guard let bucket = opts["bucket"], let key = opts["key"] else { printS3Usage(); return }
        let client = try makeClient(bucket: bucket)
        if let info = try await client.headObject(key: key) {
            print("key:          \(info.key)")
            print("size:         \(info.size)")
            print("etag:         \(info.etag ?? "-")")
            print("storageClass: \(info.storageClass?.rawValue ?? "-")")
            print("sha256:       \(info.checksumSHA256 ?? "-")")
            print("lastModified: \(info.lastModified.map { "\($0)" } ?? "-")")
            print("restore:      \(info.restoreStatus ?? "-")")
            for (k, v) in info.metadata.sorted(by: { $0.key < $1.key }) { print("meta.\(k): \(v)") }
        } else {
            print("not found")
        }

    case "selftest":
        guard let bucket = opts["bucket"] else { printS3Usage(); return }
        let client = try makeClient(bucket: bucket)
        try await runS3SelfTest(client: client, prefix: opts["prefix"] ?? "_backuphq-selftest/")

    default:
        printS3Usage()
    }
}

private func printS3Usage() {
    print("""
    usage: backuphq-cli s3 <command>
      s3 buckets [--profile p] [--region r]
      s3 head --bucket b --key k [--profile p] [--region r]
      s3 selftest --bucket b [--prefix _backuphq-selftest/] [--profile p] [--region r]
    """)
}

private func parseOptions(_ args: [String]) -> [String: String] {
    var out: [String: String] = [:]
    var i = 0
    while i < args.count {
        if args[i].hasPrefix("--") {
            let name = String(args[i].dropFirst(2))
            if i + 1 < args.count, !args[i + 1].hasPrefix("--") { out[name] = args[i + 1]; i += 2 } else { out[name] = "true"; i += 1 }
        } else { i += 1 }
    }
    return out
}

// MARK: - Self test

/// Exercises every operation the backup engine relies on against a real bucket, then cleans up.
private func runS3SelfTest(client: S3Client, prefix: String) async throws {
    final class Tally: @unchecked Sendable { var failures = 0 }
    let tally = Tally()
    func step(_ name: String, _ body: () async throws -> Void) async {
        do { try await body(); print("PASS  \(name)") } catch { tally.failures += 1; print("FAIL  \(name): \(error.localizedDescription)") }
    }

    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("backuphq-selftest-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let smallKey = prefix + "small.txt"
    let bigKey = prefix + "big.bin"
    let region = await client.config.region
    let bucket = await client.config.bucket
    print("bucket \(bucket) region \(region) prefix \(prefix)")

    await step("headBucket") { try await client.headBucket() }

    // Small object round-trip with checksum.
    let smallData = Data("Backup HQ S3 self test \(Date())\n".utf8)
    await step("putObject(small)") {
        let info = try await client.putObject(key: smallKey, data: smallData, contentType: "text/plain", metadata: ["source": "selftest", "name": "Räksmörgås.txt"])
        guard info.etag != nil else { throw S3UploadError(message: "no etag") }
    }
    await step("headObject(small) size/metadata/checksum") {
        guard let info = try await client.headObject(key: smallKey) else { throw S3UploadError(message: "missing") }
        guard info.size == Int64(smallData.count) else { throw S3UploadError(message: "size \(info.size) != \(smallData.count)") }
        guard info.metadata["source"] == "selftest" else { throw S3UploadError(message: "metadata lost: \(info.metadata)") }
        guard info.metadata["name"] == "Räksmörgås.txt" else { throw S3UploadError(message: "non-ascii metadata wrong: \(info.metadata)") }
        let expected = Data(SHA256.hash(data: smallData)).base64EncodedString()
        guard info.checksumSHA256 == expected else { throw S3UploadError(message: "checksum \(info.checksumSHA256 ?? "nil") != \(expected)") }
    }
    await step("getObject(small) bytes equal") {
        let dest = tmpDir.appendingPathComponent("small-download.txt")
        _ = try await client.getObject(key: smallKey, to: dest)
        guard try Data(contentsOf: dest) == smallData else { throw S3UploadError(message: "bytes differ") }
    }
    await step("headObject(missing) returns nil") {
        guard try await client.headObject(key: prefix + "does-not-exist-\(UUID().uuidString)") == nil else { throw S3UploadError(message: "expected nil") }
    }
    await step("putObject rejects wrong checksum") {
        let bad = String(repeating: "0", count: 64)
        let f = tmpDir.appendingPathComponent("bad.txt")
        try smallData.write(to: f)
        var accepted = false
        do {
            _ = try await client.putObject(key: prefix + "bad.txt", fileURL: f, sha256Hex: bad, contentType: "text/plain", storageClass: .standard, metadata: [:])
            accepted = true
        } catch let e as S3Error where e.statusCode == 400 {
            print("      rejected as expected: \(e.code ?? "?")")
        }
        if accepted { throw S3UploadError(message: "S3 accepted a wrong checksum") }
    }

    // Big file: 130 MB of pseudo-random bytes → 3 parts of 64 MB.
    let bigFile = tmpDir.appendingPathComponent("big.bin")
    let bigSize: Int64 = 130 * 1024 * 1024
    var bigSHA = ""
    await step("generate 130 MB test file") {
        let handle = try { try Data().write(to: bigFile); return try FileHandle(forWritingTo: bigFile) }()
        var hasher = SHA256()
        var rng = SystemRandomNumberGenerator()
        var written: Int64 = 0
        let chunk = 4 * 1024 * 1024
        while written < bigSize {
            let n = Int(min(Int64(chunk), bigSize - written))
            var bytes = [UInt8](repeating: 0, count: n)
            for i in stride(from: 0, to: n, by: 8) {
                let r = rng.next()
                for j in 0..<min(8, n - i) { bytes[i + j] = UInt8(truncatingIfNeeded: r >> (8 * j)) }
            }
            let d = Data(bytes)
            hasher.update(data: d)
            handle.write(d)
            written += Int64(n)
        }
        try handle.close()
        bigSHA = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // Phase 1: upload one part then stop (simulated interruption via cancellation).
    final class StateBox: @unchecked Sendable { var state: S3UploadResumeState?; var parts = 0; var lastProgress: Int64 = 0 }
    let box = StateBox()
    await step("multipart: upload 1 part then cancel") {
        let task = Task {
            try await S3Uploader.upload(client: client, key: bigKey, fileURL: bigFile, fileSize: bigSize, sha256Hex: bigSHA, contentType: "application/octet-stream",
                                        storageClass: .standard, metadata: ["source": "selftest"], resume: nil,
                                        onStateChange: { s in
                                            box.state = s
                                            if s.completedParts.count >= 1 { box.parts = s.completedParts.count; withUnsafeCurrentTask { $0?.cancel() } }
                                        },
                                        progress: { _ in })
        }
        var finished = false
        do { _ = try await task.value; finished = true } catch is CancellationError {}
        if finished { throw S3UploadError(message: "upload finished without being cancelled") }
        guard let s = box.state, s.completedParts.count == 1 else { throw S3UploadError(message: "expected 1 completed part, got \(box.state?.completedParts.count ?? -1)") }
        let serverParts = try await client.listParts(key: bigKey, uploadId: s.uploadId)
        guard serverParts.count == 1 else { throw S3UploadError(message: "server lists \(serverParts.count) parts") }
    }
    await step("listMultipartUploads shows in-progress upload") {
        let ups = try await client.listMultipartUploads(prefix: prefix)
        guard ups.contains(where: { $0.key == bigKey && $0.uploadId == box.state?.uploadId }) else { throw S3UploadError(message: "not listed: \(ups)") }
    }
    await step("multipart: resume and complete, HEAD size verified") {
        let result = try await S3Uploader.upload(client: client, key: bigKey, fileURL: bigFile, fileSize: bigSize, sha256Hex: bigSHA, contentType: "application/octet-stream",
                                                 storageClass: .standard, metadata: ["source": "selftest"], resume: box.state,
                                                 onStateChange: { s in box.state = s },
                                                 progress: { p in box.lastProgress = max(box.lastProgress, p) })
        guard result.usedMultipart, result.info.size == bigSize else { throw S3UploadError(message: "bad result \(result.info)") }
        guard box.state?.completedParts.count == 3 else { throw S3UploadError(message: "expected 3 parts in final state") }
        guard box.lastProgress == bigSize else { throw S3UploadError(message: "progress ended at \(box.lastProgress)") }
        print("      etag=\(result.info.etag ?? "-") checksum=\(result.info.checksumSHA256 ?? "-") meta=\(result.info.metadata)")
    }
    await step("getObject(big) sha256 matches") {
        let dest = tmpDir.appendingPathComponent("big-download.bin")
        _ = try await client.getObject(key: bigKey, to: dest)
        let h = FileHandle(forReadingAtPath: dest.path)!
        var hasher = SHA256()
        while let d = try h.read(upToCount: 4 * 1024 * 1024), !d.isEmpty { hasher.update(data: d) }
        try h.close()
        let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard hex == bigSHA else { throw S3UploadError(message: "downloaded sha \(hex) != \(bigSHA)") }
    }
    await step("listObjects(prefix) finds both") {
        let page = try await client.listObjects(prefix: prefix)
        let keys = Set(page.objects.map(\.key))
        guard keys.contains(smallKey), keys.contains(bigKey) else { throw S3UploadError(message: "keys \(keys)") }
        guard page.objects.first(where: { $0.key == bigKey })?.size == bigSize else { throw S3UploadError(message: "listed size wrong") }
    }

    // Cleanup.
    await step("cleanup: delete objects and abort stray uploads") {
        try await client.deleteObject(key: smallKey)
        try await client.deleteObject(key: bigKey)
        try await client.deleteObject(key: prefix + "bad.txt")
        for u in try await client.listMultipartUploads(prefix: prefix) { try await client.abortMultipartUpload(key: u.key, uploadId: u.uploadId) }
        let remaining = try await client.listObjects(prefix: prefix).objects
        guard remaining.isEmpty else { throw S3UploadError(message: "left behind: \(remaining.map(\.key))") }
    }

    print(tally.failures == 0 ? "ALL PASS" : "\(tally.failures) FAILED")
    if tally.failures > 0 { exit(1) }
}

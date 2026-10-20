import Foundation
import CryptoKit

// MARK: - Public value types

public enum S3StorageClass: String, Codable, CaseIterable, Sendable {
    case standard = "STANDARD"
    case standardIA = "STANDARD_IA"
    case glacierIR = "GLACIER_IR"
    case glacier = "GLACIER"
    case deepArchive = "DEEP_ARCHIVE"

    public var displayName: String {
        switch self {
        case .standard: return "S3 Standard"
        case .standardIA: return "S3 Standard-Infrequent Access"
        case .glacierIR: return "S3 Glacier Instant Retrieval"
        case .glacier: return "S3 Glacier Flexible Retrieval"
        case .deepArchive: return "S3 Glacier Deep Archive"
        }
    }

    /// Short label for tight UI, with the trade-off in two words.
    /// Storage price in eu-west-1, US dollars per GB-month (list prices, Oct 2026; the first-50-TB Standard tier).
    public var usdPerGBMonth: Double {
        switch self {
        case .standard: return 0.023
        case .standardIA: return 0.0125
        case .glacierIR: return 0.004
        case .glacier: return 0.0036
        case .deepArchive: return 0.00099
        }
    }
    /// Glacier classes bill 32 KB of index per object at the class rate plus 8 KB at Standard; IA classes bill a 128 KB minimum.
    public var perObjectOverheadBytes: (atClass: Int64, atStandard: Int64) {
        switch self {
        case .glacier, .deepArchive: return (32 * 1024, 8 * 1024)
        default: return (0, 0)
        }
    }
    public var minimumBillableBytes: Int64 {
        switch self { case .standardIA, .glacierIR: return 128 * 1024; default: return 0 }
    }
    /// Monthly cost of `count` objects totalling `bytes` in this class.
    public func monthlyUSD(count: Int, bytes: Int64) -> Double {
        let billable = max(bytes, Int64(count) * minimumBillableBytes)
        let gb = 1e9
        let overhead = perObjectOverheadBytes
        return Double(billable) / gb * usdPerGBMonth
             + Double(Int64(count) * overhead.atClass) / gb * usdPerGBMonth
             + Double(Int64(count) * overhead.atStandard) / gb * S3StorageClass.standard.usdPerGBMonth
    }

    /// Just the class name, for running text.
    public var plainName: String {
        switch self {
        case .standard: return "Standard"
        case .standardIA: return "Infrequent Access"
        case .glacierIR: return "Glacier Instant"
        case .glacier: return "Glacier Flexible"
        case .deepArchive: return "Deep Archive"
        }
    }

    public var shortName: String {
        switch self {
        case .standard: return "Standard · instant"
        case .standardIA: return "Infrequent · instant"
        case .glacierIR: return "Glacier Instant · instant"
        case .glacier: return "Glacier · hours"
        case .deepArchive: return "Deep Archive · 12 h"
        }
    }

    /// True for classes whose objects must be restored before they can be downloaded.
    public var isArchived: Bool { self == .glacier || self == .deepArchive }
}

public struct S3Config: Sendable, Codable, Equatable {
    public var region: String
    public var bucket: String
    /// nil → virtual-hosted `https://{bucket}.s3.{region}.amazonaws.com`; set for S3-compatible services (path-style `{endpoint}/{bucket}/key`).
    public var endpoint: URL?

    public init(region: String, bucket: String, endpoint: URL? = nil) {
        self.region = region
        self.bucket = bucket
        self.endpoint = endpoint
    }
}

public struct S3ObjectInfo: Sendable, Equatable {
    public var key: String
    public var size: Int64
    public var etag: String?
    public var lastModified: Date?
    public var storageClass: S3StorageClass?
    /// Base64 as S3 returns it (composite `base64-N` form for multipart objects).
    public var checksumSHA256: String?
    /// User metadata with the `x-amz-meta-` prefix stripped.
    public var metadata: [String: String]
    /// Raw `x-amz-restore` header, e.g. `ongoing-request="false", expiry-date="..."`.
    public var restoreStatus: String?

    public init(key: String, size: Int64, etag: String? = nil, lastModified: Date? = nil, storageClass: S3StorageClass? = nil,
                checksumSHA256: String? = nil, metadata: [String: String] = [:], restoreStatus: String? = nil) {
        self.key = key; self.size = size; self.etag = etag; self.lastModified = lastModified
        self.storageClass = storageClass; self.checksumSHA256 = checksumSHA256; self.metadata = metadata; self.restoreStatus = restoreStatus
    }
}

public struct S3Error: Error, LocalizedError, Sendable {
    public var statusCode: Int
    public var code: String?
    public var message: String?
    public var requestId: String?

    public init(statusCode: Int, code: String? = nil, message: String? = nil, requestId: String? = nil) {
        self.statusCode = statusCode; self.code = code; self.message = message; self.requestId = requestId
    }

    public var errorDescription: String? {
        var s = "S3 error \(statusCode)"
        if let code { s += " \(code)" }
        if let message { s += ": \(message)" }
        if let requestId { s += " (request \(requestId))" }
        return s
    }

    /// Transient failures worth retrying.
    var isRetryable: Bool {
        if statusCode >= 500 || statusCode == 429 { return true }
        switch code {
        case "SlowDown", "RequestTimeout", "InternalError", "ServiceUnavailable", "Throttling", "RequestTimeTooSkewed": return true
        default: return false
        }
    }
}

public struct S3MultipartPart: Sendable, Codable, Equatable {
    public var partNumber: Int
    public var etag: String
    public var size: Int64
    public var checksumSHA256: String?

    public init(partNumber: Int, etag: String, size: Int64, checksumSHA256: String? = nil) {
        self.partNumber = partNumber; self.etag = etag; self.size = size; self.checksumSHA256 = checksumSHA256
    }
}

// MARK: - Client

/// Minimal, dependency-free S3 REST client with SigV4 signing, retries and checksum verification.
public actor S3Client {
    public let config: S3Config
    private let credentials: AWSCredentials
    private let session: URLSession
    private let signer: AWSSigV4Signer

    public static let maxAttempts = 5

    public init(config: S3Config, credentials: AWSCredentials, session: URLSession = S3Client.makeSession()) {
        self.config = config
        self.credentials = credentials
        self.session = session
        self.signer = AWSSigV4Signer(credentials: credentials)
    }

    /// Ephemeral session with long timeouts suited to multi-GB uploads.
    public static func makeSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 120
        cfg.timeoutIntervalForResource = 3600
        cfg.waitsForConnectivity = true
        cfg.httpMaximumConnectionsPerHost = 8
        cfg.urlCache = nil
        cfg.httpShouldSetCookies = false
        return URLSession(configuration: cfg)
    }

    // MARK: Buckets

    public func headBucket() async throws {
        _ = try await send(method: "HEAD", key: nil, query: [])
    }

    public func createBucket() async throws {
        var body = Data()
        if config.region != "us-east-1" {
            body = Data("<CreateBucketConfiguration xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\"><LocationConstraint>\(s3XMLEscape(config.region))</LocationConstraint></CreateBucketConfiguration>".utf8)
        }
        _ = try await send(method: "PUT", key: nil, query: [], body: body, contentType: body.isEmpty ? nil : "application/xml")
    }

    /// Lists all buckets in the account (uses the regional service endpoint, not the bucket host).
    public func listBuckets() async throws -> [String] {
        let url = config.endpoint ?? URL(string: "https://s3.\(config.region).amazonaws.com/")!
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        signer.sign(request: &req, payloadHash: AWSSigV4Signer.emptyPayloadHash, region: config.region)
        let (data, _) = try await perform(req, body: .none)
        guard let root = S3XMLNode.parse(data), let buckets = root["Buckets"] else { return [] }
        return buckets.all("Bucket").compactMap { $0.string("Name") }
    }

    // MARK: Objects

    /// Returns nil when the object does not exist.
    public func headObject(key: String) async throws -> S3ObjectInfo? {
        do {
            let (_, response) = try await send(method: "HEAD", key: key, query: [], headers: ["x-amz-checksum-mode": "ENABLED"])
            return Self.objectInfo(key: key, from: response)
        } catch let e as S3Error where e.statusCode == 404 {
            return nil
        }
    }

    public func listObjects(prefix: String, startAfter: String? = nil, maxKeys: Int = 1000) async throws -> (objects: [S3ObjectInfo], isTruncated: Bool, nextContinuationToken: String?) {
        try await listObjectsV2(prefix: prefix, startAfter: startAfter, continuationToken: nil, maxKeys: maxKeys)
    }

    public func listObjects(prefix: String, continuationToken: String?, maxKeys: Int = 1000) async throws -> (objects: [S3ObjectInfo], isTruncated: Bool, nextContinuationToken: String?) {
        try await listObjectsV2(prefix: prefix, startAfter: nil, continuationToken: continuationToken, maxKeys: maxKeys)
    }

    private func listObjectsV2(prefix: String, startAfter: String?, continuationToken: String?, maxKeys: Int) async throws -> (objects: [S3ObjectInfo], isTruncated: Bool, nextContinuationToken: String?) {
        var query: [URLQueryItem] = [
            URLQueryItem(name: "list-type", value: "2"),
            URLQueryItem(name: "max-keys", value: String(maxKeys)),
        ]
        if !prefix.isEmpty { query.append(URLQueryItem(name: "prefix", value: prefix)) }
        if let startAfter { query.append(URLQueryItem(name: "start-after", value: startAfter)) }
        if let continuationToken { query.append(URLQueryItem(name: "continuation-token", value: continuationToken)) }
        let (data, _) = try await send(method: "GET", key: nil, query: query)
        guard let root = S3XMLNode.parse(data) else { throw S3Error(statusCode: 200, code: "BadXML", message: "Unparseable ListObjectsV2 response") }
        let objects = root.all("Contents").compactMap { node -> S3ObjectInfo? in
            guard let key = node.string("Key") else { return nil }
            return S3ObjectInfo(
                key: key,
                size: Int64(node.string("Size") ?? "") ?? 0,
                etag: node.string("ETag"),
                lastModified: Self.parseISODate(node.string("LastModified")),
                storageClass: node.string("StorageClass").flatMap(S3StorageClass.init(rawValue:)))
        }
        let truncated = root.string("IsTruncated") == "true"
        return (objects, truncated, root.string("NextContinuationToken"))
    }

    public func putObject(key: String, data: Data, contentType: String?, storageClass: S3StorageClass = .standard, metadata: [String: String] = [:]) async throws -> S3ObjectInfo {
        let digest = SHA256.hash(data: data)
        var headers = Self.metadataHeaders(metadata)
        headers["x-amz-storage-class"] = storageClass.rawValue
        headers["x-amz-checksum-sha256"] = Data(digest).base64EncodedString()
        let payloadHash = digest.map { String(format: "%02x", $0) }.joined()
        let (_, response) = try await send(method: "PUT", key: key, query: [], headers: headers, body: .data(data), contentType: contentType, payloadHash: payloadHash)
        var info = Self.objectInfo(key: key, from: response)
        info.size = Int64(data.count)
        info.storageClass = storageClass
        info.metadata = metadata
        return info
    }

    /// Single-request upload of a file. `sha256Hex` is sent as `x-amz-checksum-sha256`, so S3 rejects any corrupted transfer.
    public func putObject(key: String, fileURL: URL, sha256Hex: String, contentType: String?, storageClass: S3StorageClass,
                          metadata: [String: String], progress: (@Sendable (Int64) -> Void)? = nil) async throws -> S3ObjectInfo {
        guard let digest = Data(hexString: sha256Hex) else { throw S3Error(statusCode: 0, code: "BadChecksum", message: "sha256Hex is not valid hex") }
        var headers = Self.metadataHeaders(metadata)
        headers["x-amz-storage-class"] = storageClass.rawValue
        headers["x-amz-checksum-sha256"] = digest.base64EncodedString()
        let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        let (_, response) = try await send(method: "PUT", key: key, query: [], headers: headers, body: .file(fileURL), contentType: contentType, payloadHash: sha256Hex.lowercased(), progress: progress)
        var info = Self.objectInfo(key: key, from: response)
        info.size = size
        info.storageClass = storageClass
        info.metadata = metadata
        return info
    }

    public func deleteObject(key: String) async throws {
        _ = try await send(method: "DELETE", key: key, query: [])
    }

    /// Downloads an object to `fileURL` (replacing any existing file). Archived, un-restored objects fail with `InvalidObjectState`.
    public func getObject(key: String, to fileURL: URL) async throws -> S3ObjectInfo {
        var req = try makeRequest(method: "GET", key: key, query: [], headers: ["x-amz-checksum-mode": "ENABLED"], contentType: nil)
        signer.sign(request: &req, payloadHash: AWSSigV4Signer.emptyPayloadHash, region: config.region)
        let request = req
        return try await withRetry {
            let delegate = TaskDelegate(progress: nil)
            let (tmp, response) = try await self.session.download(for: request, delegate: delegate)
            guard let http = response as? HTTPURLResponse else { throw S3Error(statusCode: 0, message: "Non-HTTP response") }
            if http.statusCode >= 300 {
                let body = (try? Data(contentsOf: tmp)) ?? Data()
                try? FileManager.default.removeItem(at: tmp)
                throw Self.error(from: http, body: body)
            }
            try? FileManager.default.removeItem(at: fileURL)
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: tmp, to: fileURL)
            return Self.objectInfo(key: key, from: http)
        }
    }

    /// Initiates a restore of an archived object. Treats "restore already in progress" as success.
    /// Rewrites the object in place with a new storage class, keeping its user metadata (and so its sha256 tag).
    /// S3 refuses single-request copies over 5 GB; those would need a multipart copy and are reported as an error.
    public func changeStorageClass(key: String, to storageClass: S3StorageClass) async throws -> S3ObjectInfo {
        let source = "/" + AWSSigV4Signer.awsEncode(config.bucket) + "/" + AWSSigV4Signer.awsEncode(key, keepSlash: true)
        let headers = ["x-amz-copy-source": source, "x-amz-storage-class": storageClass.rawValue,
                       "x-amz-metadata-directive": "COPY", "x-amz-checksum-algorithm": "SHA256"]
        let (data, response) = try await send(method: "PUT", key: key, query: [], headers: headers)
        let body = String(decoding: data, as: UTF8.self)
        // CopyObject can answer 200 and still fail inside the body.
        if body.contains("<Error>") { throw S3Error(statusCode: response.statusCode, code: "CopyFailed", message: body) }
        var info = Self.objectInfo(key: key, from: response)
        info.storageClass = storageClass
        if let a = body.range(of: "<ETag>"), let b = body.range(of: "</ETag>"), a.upperBound <= b.lowerBound {
            info.etag = String(body[a.upperBound..<b.lowerBound]).replacingOccurrences(of: "&quot;", with: "\"")
        }
        return info
    }

    public func restoreObject(key: String, days: Int, tier: String) async throws {
        let body = Data("<RestoreRequest xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\"><Days>\(days)</Days><GlacierJobParameters><Tier>\(s3XMLEscape(tier))</Tier></GlacierJobParameters></RestoreRequest>".utf8)
        do {
            _ = try await send(method: "POST", key: key, query: [URLQueryItem(name: "restore", value: nil)], body: .data(body), contentType: "application/xml", payloadHash: AWSSigV4Signer.hexSHA256(body))
        } catch let e as S3Error where e.statusCode == 409 && e.code == "RestoreAlreadyInProgress" {
            return
        }
    }

    // MARK: Multipart

    public func createMultipartUpload(key: String, contentType: String?, storageClass: S3StorageClass, metadata: [String: String]) async throws -> String {
        var headers = Self.metadataHeaders(metadata)
        headers["x-amz-storage-class"] = storageClass.rawValue
        headers["x-amz-checksum-algorithm"] = "SHA256"
        let (data, _) = try await send(method: "POST", key: key, query: [URLQueryItem(name: "uploads", value: nil)], headers: headers, contentType: contentType)
        guard let root = S3XMLNode.parse(data), let id = root.string("UploadId") else {
            throw S3Error(statusCode: 200, code: "BadXML", message: "No UploadId in CreateMultipartUpload response")
        }
        return id
    }

    /// Uploads one part; S3 verifies the per-part SHA-256 we send.
    public func uploadPart(key: String, uploadId: String, partNumber: Int, data: Data) async throws -> S3MultipartPart {
        let digest = SHA256.hash(data: data)
        let checksum = Data(digest).base64EncodedString()
        let payloadHash = digest.map { String(format: "%02x", $0) }.joined()
        let query = [URLQueryItem(name: "partNumber", value: String(partNumber)), URLQueryItem(name: "uploadId", value: uploadId)]
        let (_, response) = try await send(method: "PUT", key: key, query: query, headers: ["x-amz-checksum-sha256": checksum], body: .data(data), payloadHash: payloadHash)
        guard let etag = response.value(forHTTPHeaderField: "ETag") else {
            throw S3Error(statusCode: response.statusCode, code: "NoETag", message: "UploadPart response had no ETag")
        }
        return S3MultipartPart(partNumber: partNumber, etag: etag, size: Int64(data.count), checksumSHA256: response.value(forHTTPHeaderField: "x-amz-checksum-sha256") ?? checksum)
    }

    /// All parts uploaded so far for `uploadId` (follows pagination).
    public func listParts(key: String, uploadId: String) async throws -> [S3MultipartPart] {
        var parts: [S3MultipartPart] = []
        var marker: String?
        repeat {
            var query = [URLQueryItem(name: "uploadId", value: uploadId), URLQueryItem(name: "max-parts", value: "1000")]
            if let marker { query.append(URLQueryItem(name: "part-number-marker", value: marker)) }
            let (data, _) = try await send(method: "GET", key: key, query: query)
            guard let root = S3XMLNode.parse(data) else { throw S3Error(statusCode: 200, code: "BadXML", message: "Unparseable ListParts response") }
            for node in root.all("Part") {
                guard let n = node.string("PartNumber").flatMap(Int.init), let etag = node.string("ETag") else { continue }
                parts.append(S3MultipartPart(partNumber: n, etag: etag, size: Int64(node.string("Size") ?? "") ?? 0, checksumSHA256: node.string("ChecksumSHA256")))
            }
            marker = root.string("IsTruncated") == "true" ? root.string("NextPartNumberMarker") : nil
        } while marker != nil
        return parts.sorted { $0.partNumber < $1.partNumber }
    }

    public func completeMultipartUpload(key: String, uploadId: String, parts: [S3MultipartPart]) async throws -> S3ObjectInfo {
        var xml = "<CompleteMultipartUpload xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">"
        for p in parts.sorted(by: { $0.partNumber < $1.partNumber }) {
            xml += "<Part>"
            if let c = p.checksumSHA256 { xml += "<ChecksumSHA256>\(s3XMLEscape(c))</ChecksumSHA256>" }
            xml += "<ETag>\(s3XMLEscape(p.etag))</ETag><PartNumber>\(p.partNumber)</PartNumber></Part>"
        }
        xml += "</CompleteMultipartUpload>"
        let body = Data(xml.utf8)
        let (data, response) = try await send(method: "POST", key: key, query: [URLQueryItem(name: "uploadId", value: uploadId)], body: .data(body), contentType: "application/xml", payloadHash: AWSSigV4Signer.hexSHA256(body))
        // S3 may return 200 with an <Error> body for Complete; check.
        if let root = S3XMLNode.parse(data), root.name == "Error" {
            throw S3Error(statusCode: response.statusCode, code: root.string("Code"), message: root.string("Message"), requestId: root.string("RequestId"))
        }
        var info = Self.objectInfo(key: key, from: response)
        if let root = S3XMLNode.parse(data) {
            if info.etag == nil { info.etag = root.string("ETag") }
            if info.checksumSHA256 == nil { info.checksumSHA256 = root.string("ChecksumSHA256") }
        }
        info.size = parts.reduce(0) { $0 + $1.size }
        return info
    }

    public func abortMultipartUpload(key: String, uploadId: String) async throws {
        _ = try await send(method: "DELETE", key: key, query: [URLQueryItem(name: "uploadId", value: uploadId)])
    }

    /// In-progress multipart uploads under `prefix` (follows pagination).
    public func listMultipartUploads(prefix: String) async throws -> [(key: String, uploadId: String, initiated: Date?)] {
        var result: [(key: String, uploadId: String, initiated: Date?)] = []
        var keyMarker: String?
        var idMarker: String?
        repeat {
            var query = [URLQueryItem(name: "uploads", value: nil), URLQueryItem(name: "max-uploads", value: "1000")]
            if !prefix.isEmpty { query.append(URLQueryItem(name: "prefix", value: prefix)) }
            if let keyMarker { query.append(URLQueryItem(name: "key-marker", value: keyMarker)) }
            if let idMarker { query.append(URLQueryItem(name: "upload-id-marker", value: idMarker)) }
            let (data, _) = try await send(method: "GET", key: nil, query: query)
            guard let root = S3XMLNode.parse(data) else { throw S3Error(statusCode: 200, code: "BadXML", message: "Unparseable ListMultipartUploads response") }
            for node in root.all("Upload") {
                guard let key = node.string("Key"), let id = node.string("UploadId") else { continue }
                result.append((key, id, Self.parseISODate(node.string("Initiated"))))
            }
            if root.string("IsTruncated") == "true" {
                keyMarker = root.string("NextKeyMarker"); idMarker = root.string("NextUploadIdMarker")
            } else {
                keyMarker = nil; idMarker = nil
            }
        } while keyMarker != nil
        return result
    }

    // MARK: - Request plumbing

    enum Body {
        case none
        case data(Data)
        case file(URL)
    }

    /// Builds, signs, sends with retries, and checks the status of a bucket-scoped request.
    private func send(method: String, key: String?, query: [URLQueryItem], headers: [String: String] = [:], body: Body = .none,
                      contentType: String? = nil, payloadHash: String? = nil, progress: (@Sendable (Int64) -> Void)? = nil) async throws -> (Data, HTTPURLResponse) {
        var req = try makeRequest(method: method, key: key, query: query, headers: headers, contentType: contentType)
        let hash: String
        switch body {
        case .none: hash = AWSSigV4Signer.emptyPayloadHash
        case .data(let d): hash = payloadHash ?? AWSSigV4Signer.hexSHA256(d)
        case .file: hash = payloadHash ?? AWSSigV4Signer.unsignedPayload
        }
        signer.sign(request: &req, payloadHash: hash, region: config.region)
        let request = req
        return try await perform(request, body: body, progress: progress)
    }

    private func send(method: String, key: String?, query: [URLQueryItem], headers: [String: String] = [:], body: Data, contentType: String?) async throws -> (Data, HTTPURLResponse) {
        try await send(method: method, key: key, query: query, headers: headers, body: body.isEmpty ? .none : .data(body), contentType: contentType)
    }

    func makeRequest(method: String, key: String?, query: [URLQueryItem], headers: [String: String], contentType: String?) throws -> URLRequest {
        var components: URLComponents
        if let endpoint = config.endpoint {
            components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) ?? URLComponents()
            components.percentEncodedPath = "/" + AWSSigV4Signer.awsEncode(config.bucket) + (key.map { "/" + AWSSigV4Signer.awsEncode($0, keepSlash: true) } ?? "")
        } else {
            components = URLComponents()
            components.scheme = "https"
            components.host = "\(config.bucket).s3.\(config.region).amazonaws.com"
            components.percentEncodedPath = "/" + (key.map { AWSSigV4Signer.awsEncode($0, keepSlash: true) } ?? "")
        }
        if !query.isEmpty {
            // Encode ourselves so the wire form matches the canonical form exactly.
            components.percentEncodedQuery = query.map { item in
                let name = AWSSigV4Signer.awsEncode(item.name)
                return item.value.map { "\(name)=\(AWSSigV4Signer.awsEncode($0))" } ?? name
            }.joined(separator: "&")
        }
        guard let url = components.url else { throw S3Error(statusCode: 0, code: "BadURL", message: "Could not build URL for key \(key ?? "")") }
        var req = URLRequest(url: url)
        req.httpMethod = method
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if let contentType { req.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        return req
    }

    /// Executes a signed request with retry/backoff and S3 error decoding.
    private func perform(_ request: URLRequest, body: Body, progress: (@Sendable (Int64) -> Void)? = nil) async throws -> (Data, HTTPURLResponse) {
        try await withRetry {
            let delegate = TaskDelegate(progress: progress)
            let data: Data
            let response: URLResponse
            switch body {
            case .none:
                (data, response) = try await self.session.data(for: request, delegate: delegate)
            case .data(let d):
                (data, response) = try await self.session.upload(for: request, from: d, delegate: delegate)
            case .file(let url):
                (data, response) = try await self.session.upload(for: request, fromFile: url, delegate: delegate)
            }
            guard let http = response as? HTTPURLResponse else { throw S3Error(statusCode: 0, message: "Non-HTTP response") }
            if http.statusCode >= 300 { throw Self.error(from: http, body: data) }
            return (data, http)
        }
    }

    /// Up to `maxAttempts` tries with exponential backoff on transient failures. Never retries after cancellation.
    func withRetry<T>(_ op: @escaping () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            attempt += 1
            try Task.checkCancellation()
            do {
                return try await op()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard attempt < Self.maxAttempts, Self.isRetryable(error) else { throw error }
                let delay = UInt64(1 << (attempt - 1)) // 1,2,4,8 s
                try await Task.sleep(nanoseconds: delay * 1_000_000_000)
            }
        }
    }

    static func isRetryable(_ error: Error) -> Bool {
        if let e = error as? S3Error { return e.isRetryable }
        if let e = error as? URLError {
            switch e.code {
            case .timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost,
                 .dnsLookupFailed, .secureConnectionFailed, .resourceUnavailable, .internationalRoamingOff, .dataNotAllowed,
                 .backgroundSessionWasDisconnected:
                return true
            default:
                return false
            }
        }
        return false
    }

    /// Decodes an S3 error response; redirects get an explicit wrong-region explanation.
    static func error(from http: HTTPURLResponse, body: Data) -> S3Error {
        var err = S3Error(statusCode: http.statusCode, requestId: http.value(forHTTPHeaderField: "x-amz-request-id"))
        if let root = S3XMLNode.parse(body), root.name == "Error" {
            err.code = root.string("Code")
            err.message = root.string("Message")
            if let endpoint = root.string("Endpoint"), err.code == "PermanentRedirect" || err.code == "TemporaryRedirect" {
                err.message = (err.message ?? "") + " The bucket lives at \(endpoint); check the configured region."
            }
            if let region = root.string("Region"), err.code == "AuthorizationHeaderMalformed" || err.code == "IllegalLocationConstraintException" {
                err.message = (err.message ?? "") + " Expected region: \(region)."
            }
            if err.requestId == nil { err.requestId = root.string("RequestId") }
        } else if http.statusCode == 301 || http.statusCode == 307 || http.statusCode == 308 {
            err.code = "Redirect"
            err.message = "S3 redirected the request (status \(http.statusCode)); the bucket is probably in a different region than '\(http.url?.host ?? "")' implies."
            if let region = http.value(forHTTPHeaderField: "x-amz-bucket-region") { err.message! += " Bucket region: \(region)." }
        } else if let region = http.value(forHTTPHeaderField: "x-amz-bucket-region"), http.statusCode == 400 {
            err.code = "WrongRegion"
            err.message = "Bucket region is \(region)."
        }
        return err
    }

    /// Builds object info from response headers (HEAD / PUT / GET).
    static func objectInfo(key: String, from http: HTTPURLResponse) -> S3ObjectInfo {
        var metadata: [String: String] = [:]
        for (k, v) in http.allHeaderFields {
            guard let name = (k as? String)?.lowercased(), name.hasPrefix("x-amz-meta-"), let value = v as? String else { continue }
            metadata[String(name.dropFirst("x-amz-meta-".count))] = value
        }
        // Undo the percent-encoding applied by `metadataHeaders` for non-ASCII values.
        for (k, v) in metadata where k.hasSuffix("-encoding") && v == "url" {
            let base = String(k.dropLast("-encoding".count))
            if let raw = metadata[base] { metadata[base] = raw.removingPercentEncoding ?? raw }
            metadata.removeValue(forKey: k)
        }
        let length = http.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init) ?? 0
        return S3ObjectInfo(
            key: key,
            size: length,
            etag: http.value(forHTTPHeaderField: "ETag"),
            lastModified: http.value(forHTTPHeaderField: "Last-Modified").flatMap(parseHTTPDate),
            storageClass: http.value(forHTTPHeaderField: "x-amz-storage-class").flatMap(S3StorageClass.init(rawValue:)) ?? .standard,
            checksumSHA256: http.value(forHTTPHeaderField: "x-amz-checksum-sha256"),
            metadata: metadata,
            restoreStatus: http.value(forHTTPHeaderField: "x-amz-restore"))
    }

    /// Turns user metadata into `x-amz-meta-*` headers. S3 only accepts US-ASCII header values, so non-ASCII
    /// values are percent-encoded and flagged with a sibling `<key>-encoding: url` entry.
    static func metadataHeaders(_ metadata: [String: String]) -> [String: String] {
        var headers: [String: String] = [:]
        for (k, v) in metadata {
            let key = "x-amz-meta-\(k.lowercased())"
            if v.unicodeScalars.allSatisfy({ $0.isASCII && $0.value >= 0x20 && $0.value < 0x7f }) {
                headers[key] = v
            } else {
                headers[key] = AWSSigV4Signer.awsEncode(v)
                headers["\(key)-encoding"] = "url"
            }
        }
        return headers
    }

    // MARK: Dates

    static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static let isoFormatterNoFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    static let httpDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f
    }()

    static func parseISODate(_ s: String?) -> Date? {
        guard let s else { return nil }
        return isoFormatter.date(from: s) ?? isoFormatterNoFraction.date(from: s)
    }

    static func parseHTTPDate(_ s: String) -> Date? { httpDateFormatter.date(from: s) }
}

// MARK: - URLSession task delegate

/// Blocks automatic redirect following (so wrong-region redirects surface as errors) and reports upload progress.
final class TaskDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let progress: (@Sendable (Int64) -> Void)?

    init(progress: (@Sendable (Int64) -> Void)?) {
        self.progress = progress
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        progress?(totalBytesSent)
    }
}

// MARK: - Hex helper

extension Data {
    /// Decodes a lowercase/uppercase hex string; nil if malformed.
    init?(hexString: String) {
        let chars = Array(hexString.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let hi = Data.hexValue(chars[i]), let lo = Data.hexValue(chars[i + 1]) else { return nil }
            bytes.append(hi << 4 | lo)
            i += 2
        }
        self.init(bytes)
    }

    private static func hexValue(_ c: UInt8) -> UInt8? {
        switch c {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return c - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return c - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return c - UInt8(ascii: "A") + 10
        default: return nil
        }
    }
}

import Foundation
import CryptoKit

/// Static AWS credentials (access key / secret / optional STS session token).
public struct AWSCredentials: Sendable, Codable, Equatable {
    public var accessKeyId: String
    public var secretAccessKey: String
    public var sessionToken: String?

    public init(accessKeyId: String, secretAccessKey: String, sessionToken: String? = nil) {
        self.accessKeyId = accessKeyId
        self.secretAccessKey = secretAccessKey
        self.sessionToken = sessionToken
    }
}

/// AWS Signature Version 4 signer for REST requests (S3 flavour: single-chunk payload hash).
/// See https://docs.aws.amazon.com/AmazonS3/latest/API/sig-v4-header-based-auth.html
struct AWSSigV4Signer: Sendable {
    static let unsignedPayload = "UNSIGNED-PAYLOAD"
    static let emptyPayloadHash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    let credentials: AWSCredentials

    /// Headers never included in the signature (hop-by-hop / set by the transport, so we cannot
    /// guarantee they reach the wire unchanged).
    private static let excludedHeaders: Set<String> = [
        "connection", "user-agent", "content-length", "expect", "authorization",
        "accept-encoding", "transfer-encoding", "keep-alive", "proxy-connection", "te", "trailer", "upgrade",
    ]

    /// Signs `request` in place. `payloadHash` is the lowercase hex SHA-256 of the body, or `UNSIGNED-PAYLOAD`.
    func sign(request: inout URLRequest, payloadHash: String, region: String, service: String = "s3", date: Date = Date()) {
        guard let url = request.url, let host = url.host else { return }

        let amzDate = Self.amzDateFormatter.string(from: date)
        let dateStamp = String(amzDate.prefix(8))

        // Host header must carry a non-default port if present.
        var hostHeader = host
        if let port = url.port, !((url.scheme == "https" && port == 443) || (url.scheme == "http" && port == 80)) {
            hostHeader += ":\(port)"
        }
        request.setValue(hostHeader, forHTTPHeaderField: "Host")
        request.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
        request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")
        if let token = credentials.sessionToken, !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: "x-amz-security-token")
        }

        // Canonical headers: lowercase names, trimmed values with internal whitespace collapsed, sorted by name.
        var canonicalHeaders: [(String, String)] = []
        for (name, value) in request.allHTTPHeaderFields ?? [:] {
            let lower = name.lowercased()
            if Self.excludedHeaders.contains(lower) { continue }
            canonicalHeaders.append((lower, Self.collapseWhitespace(value)))
        }
        canonicalHeaders.sort { $0.0 < $1.0 }
        let signedHeaders = canonicalHeaders.map { $0.0 }.joined(separator: ";")
        let canonicalHeaderString = canonicalHeaders.map { "\($0.0):\($0.1)\n" }.joined()

        let canonicalRequest = [
            request.httpMethod ?? "GET",
            Self.canonicalURI(url),
            Self.canonicalQuery(url),
            canonicalHeaderString,
            signedHeaders,
            payloadHash,
        ].joined(separator: "\n")

        let scope = "\(dateStamp)/\(region)/\(service)/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            scope,
            Self.hexSHA256(Data(canonicalRequest.utf8)),
        ].joined(separator: "\n")

        let signingKey = Self.signingKey(secret: credentials.secretAccessKey, dateStamp: dateStamp, region: region, service: service)
        let signature = Self.hmacHex(key: signingKey, data: Data(stringToSign.utf8))

        request.setValue(
            "AWS4-HMAC-SHA256 Credential=\(credentials.accessKeyId)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)",
            forHTTPHeaderField: "Authorization")
    }

    // MARK: - Canonicalisation helpers

    /// Characters AWS leaves unencoded.
    static let unreserved: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-_.~")
        return set
    }()

    /// Percent-encodes per RFC 3986 with AWS rules (uppercase hex, `/` encoded unless `keepSlash`).
    static func awsEncode(_ string: String, keepSlash: Bool = false) -> String {
        var allowed = unreserved
        if keepSlash { allowed.insert("/") }
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }

    /// Canonical URI: the already-decoded path re-encoded segment by segment (S3 wants a single encoding pass).
    static func canonicalURI(_ url: URL) -> String {
        // `url.path` gives the decoded path; re-encode every segment but keep separators.
        var path = url.path
        if path.isEmpty { path = "/" }
        let encoded = awsEncode(path, keepSlash: true)
        // Preserve trailing slash that URL.path drops.
        if url.absoluteString.contains("://"), let raw = url.absoluteString.split(separator: "?").first,
           raw.hasSuffix("/"), !encoded.hasSuffix("/") {
            return encoded + "/"
        }
        return encoded
    }

    /// Canonical query: decoded key/value pairs re-encoded, sorted by key then value.
    static func canonicalQuery(_ url: URL) -> String {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems, !items.isEmpty else { return "" }
        var pairs: [(key: String, value: String)] = items.map { item in
            (key: awsEncode(item.name), value: awsEncode(item.value ?? ""))
        }
        pairs.sort { a, b in a.key == b.key ? a.value < b.value : a.key < b.key }
        let encoded: [String] = pairs.map { pair in pair.key + "=" + pair.value }
        return encoded.joined(separator: "&")
    }

    static func collapseWhitespace(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        let parts: [Substring] = trimmed.split(whereSeparator: { (c: Character) -> Bool in c == " " || c == "\t" })
        return parts.joined(separator: " ")
    }

    // MARK: - Crypto

    static func hexSHA256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func hmac(key: Data, data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    static func hmacHex(key: Data, data: Data) -> String {
        hmac(key: key, data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func signingKey(secret: String, dateStamp: String, region: String, service: String) -> Data {
        let kDate = hmac(key: Data("AWS4\(secret)".utf8), data: Data(dateStamp.utf8))
        let kRegion = hmac(key: kDate, data: Data(region.utf8))
        let kService = hmac(key: kRegion, data: Data(service.utf8))
        return hmac(key: kService, data: Data("aws4_request".utf8))
    }

    static let amzDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f
    }()
}

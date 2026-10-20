import Foundation
import Security

/// AWS credentials for an S3 location: first the Keychain (entered in the app), then the named profile in ~/.aws.
public enum CredentialStore {
    static let service = "BackupHQ.s3"

    public static func account(for locationId: Int64) -> String { "s3-location-\(locationId)" }

    public static func save(_ creds: AWSCredentials, for locationId: Int64) throws {
        let data = try JSONEncoder().encode(creds)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account(for: locationId)]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Keychain save failed (\(status))"]) }
    }

    public static func delete(for locationId: Int64) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account(for: locationId)]
        SecItemDelete(query as CFDictionary)
    }

    public static func keychainCredentials(for locationId: Int64) -> AWSCredentials? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account(for: locationId), kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(AWSCredentials.self, from: data)
    }

    /// Resolves credentials for a location, and the region to use.
    public static func resolve(for location: Location) throws -> (AWSCredentials, String) {
        let region = location.s3Region ?? "eu-west-1"
        if let kc = keychainCredentials(for: location.id) { return (kc, region) }
        let profile = location.s3Profile ?? "default"
        let loaded = try AWSCredentialsFile.load(profile: profile)
        return (loaded.credentials, location.s3Region ?? loaded.region ?? region)
    }

    public static func client(for location: Location) throws -> S3Client {
        guard location.kind == .s3, let bucket = location.s3Bucket else {
            throw EngineError.invalidLocation("Location \(location.name) is not an S3 location")
        }
        let (creds, region) = try resolve(for: location)
        return S3Client(config: S3Config(region: region, bucket: bucket, endpoint: nil), credentials: creds)
    }
}

public enum EngineError: Error, LocalizedError {
    case invalidLocation(String)
    case sourceMissing(String)
    case hashMismatch(expected: String, actual: String, path: String)
    case notReachable(String)
    case noLocalCopy(String)
    case sourceChanged(String)
    case cancelled
    /// Not a failure: the job must wait (an S3 restore is in progress) and should be tried again after the delay.
    case parked(seconds: TimeInterval, reason: String)

    public var errorDescription: String? {
        switch self {
        case .invalidLocation(let s): return s
        case .sourceChanged(let p): return "\(p) changed since it was scanned; re-scanning it"
        case .sourceMissing(let p): return "Source file is missing: \(p)"
        case .hashMismatch(let e, let a, let p): return "Checksum mismatch for \(p): expected \(e.prefix(12))…, got \(a.prefix(12))…"
        case .notReachable(let s): return "Location not reachable: \(s)"
        case .noLocalCopy(let s): return "No local copy available to upload for \(s.prefix(12))…"
        case .cancelled: return "Cancelled"
        case .parked(_, let r): return r
        }
    }
}

import Foundation

/// Reads static credentials and the default region from the AWS CLI's `~/.aws/credentials` and `~/.aws/config`.
public enum AWSCredentialsFile {
    public struct LoadError: Error, LocalizedError, Sendable {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// Loads `profile`. Credentials are looked up in `credentials` first, then `config`; `region` only in `config`.
    /// A `source_profile` key is followed one level for the keys.
    public static func load(profile: String = "default", home: URL = AWSCredentialsFile.homeDirectory) throws -> (credentials: AWSCredentials, region: String?) {
        let creds = parseINI(at: home.appendingPathComponent(".aws/credentials"))
        let config = parseINI(at: home.appendingPathComponent(".aws/config"))

        func configSection(_ name: String) -> [String: String] {
            name == "default" ? (config["default"] ?? [:]) : (config["profile \(name)"] ?? config[name] ?? [:])
        }

        var merged = configSection(profile)
        for (k, v) in creds[profile] ?? [:] { merged[k] = v }

        if merged["aws_access_key_id"] == nil, let source = merged["source_profile"], source != profile {
            var src = configSection(source)
            for (k, v) in creds[source] ?? [:] { src[k] = v }
            for key in ["aws_access_key_id", "aws_secret_access_key", "aws_session_token"] where merged[key] == nil {
                merged[key] = src[key]
            }
            if merged["region"] == nil { merged["region"] = src["region"] }
        }

        guard let id = merged["aws_access_key_id"], let secret = merged["aws_secret_access_key"] else {
            throw LoadError(message: "No static credentials found for AWS profile '\(profile)' in \(home.path)/.aws")
        }
        return (AWSCredentials(accessKeyId: id, secretAccessKey: secret, sessionToken: merged["aws_session_token"]), merged["region"])
    }

    /// Profile names present in either file.
    public static func listProfiles(home: URL = AWSCredentialsFile.homeDirectory) -> [String] {
        var names = Set(parseINI(at: home.appendingPathComponent(".aws/credentials")).keys)
        for key in parseINI(at: home.appendingPathComponent(".aws/config")).keys {
            names.insert(key.hasPrefix("profile ") ? String(key.dropFirst("profile ".count)) : key)
        }
        return names.sorted { $0 == "default" ? true : ($1 == "default" ? false : $0 < $1) }
    }

    /// Minimal INI parser: `[section]` headers, `key = value` lines, `#`/`;` comments. Section/key names are lowercased.
    static func parseINI(at url: URL) -> [String: [String: String]] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var result: [String: [String: String]] = [:]
        var section: String?
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                section = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                result[section!, default: [:]] = result[section!] ?? [:]
                continue
            }
            // Nested blocks (e.g. `s3 =` followed by indented keys) are skipped: indented lines never reach here
            // because we trimmed, so only treat `key = value` with a value.
            guard let section, let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if key.isEmpty || value.isEmpty { continue }
            result[section, default: [:]][key] = value
        }
        return result
    }
}

extension AWSCredentialsFile {
    /// ~/.aws exists on the Mac only; the phone keeps its keys in the Keychain.
    public static var homeDirectory: URL {
        #if os(macOS)
        return FileManager.default.homeDirectoryForCurrentUser
        #else
        return URL(fileURLWithPath: NSTemporaryDirectory())
        #endif
    }
}

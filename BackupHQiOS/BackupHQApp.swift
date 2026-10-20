import SwiftUI
import BackupHQCore

@main
struct BackupHQApp: App {
    @State private var model = PhoneModel()
    var body: some Scene {
        WindowGroup {
            RootView().environment(model)
        }
    }
}

/// Everything the phone knows comes from the status.json the Mac publishes. The phone never writes.
@MainActor
@Observable
final class PhoneModel {
    struct Settings: Codable, Equatable {
        var bucket = ""
        var region = "eu-west-1"
        var prefix = ""
        var accessKeyId = ""
    }
    var settings: Settings
    var secret: String
    var stats: CatalogStats?
    var lastFetched: Date?
    var error: String?
    var loading = false
    var configured: Bool { !settings.accessKeyId.isEmpty && !secret.isEmpty && !settings.bucket.isEmpty }

    private static let keychainSlot: Int64 = 0

    init() {
        if let data = UserDefaults.standard.data(forKey: "phone.settings"), let s = try? JSONDecoder().decode(Settings.self, from: data) { settings = s } else { settings = Settings() }
        secret = CredentialStore.keychainCredentials(for: Self.keychainSlot)?.secretAccessKey ?? ""
        // Simulator convenience: credentials can be injected through the environment instead of typed.
        let env = ProcessInfo.processInfo.environment
        if settings.accessKeyId.isEmpty, let k = env["BACKUPHQ_ACCESS_KEY"], let s = env["BACKUPHQ_SECRET"], !k.isEmpty, !s.isEmpty {
            settings.accessKeyId = k; secret = s
            if let b = env["BACKUPHQ_BUCKET"], !b.isEmpty { settings.bucket = b }
        }
    }

    func save(_ s: Settings, secret: String) {
        settings = s
        self.secret = secret
        if let data = try? JSONEncoder().encode(s) { UserDefaults.standard.set(data, forKey: "phone.settings") }
        try? CredentialStore.save(AWSCredentials(accessKeyId: s.accessKeyId, secretAccessKey: secret), for: Self.keychainSlot)
    }

    func refresh() async {
        guard configured, !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let client = S3Client(config: S3Config(region: settings.region, bucket: settings.bucket), credentials: AWSCredentials(accessKeyId: settings.accessKeyId, secretAccessKey: secret))
            let prefix = settings.prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let key = (prefix.isEmpty ? "" : prefix + "/") + "_backuphq/status.json"
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("status.json")
            _ = try await client.getObject(key: key, to: tmp)
            let data = try Data(contentsOf: tmp)
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            stats = try decoder.decode(CatalogStats.self, from: data)
            lastFetched = Date()
            error = nil
        } catch let e as S3Error {
            error = e.statusCode == 403 ? "Access denied. Check the key and secret, and that the key may read _backuphq/ in the bucket." : (e.message ?? "S3 error \(e.statusCode)")
        } catch {
            self.error = error.localizedDescription
        }
    }
}

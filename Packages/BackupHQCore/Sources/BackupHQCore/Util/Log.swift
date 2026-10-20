import Foundation
import os

public enum Log {
    /// `log show --info --predicate 'subsystem == "<bundle id>"'` reads these; the CLI logs under "BackupHQ".
    public static let subsystem = Bundle.main.bundleIdentifier ?? "BackupHQ"
    public static let engine = Logger(subsystem: subsystem, category: "engine")
    public static let db = Logger(subsystem: subsystem, category: "db")
    public static let lightroom = Logger(subsystem: subsystem, category: "lightroom")
    public static let s3 = Logger(subsystem: subsystem, category: "s3")
}

public enum Format {
    public static func bytes(_ n: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false
        return f.string(fromByteCount: n)
    }
    public static func count(_ n: Int) -> String {
        n.formatted(.number.grouping(.automatic))
    }
    public static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "—" }
        let s = Int(seconds)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        if s < 86400 { return "\(s / 3600)h \((s % 3600) / 60)m" }
        return "\(s / 86400)d \((s % 86400) / 3600)h"
    }
}

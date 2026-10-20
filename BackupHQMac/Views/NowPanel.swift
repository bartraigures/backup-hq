import SwiftUI
import BackupHQCore

/// The one panel that answers "what is it doing?". Every slot has a fixed size, so the panel never changes
/// height or shuffles as work starts and stops: empty slots stay empty rather than disappearing.
struct NowPanel: View {
    @Environment(AppModel.self) private var model
    var compact = false

    private static let queueKinds: [(kind: String, icon: String, label: String)] = [
        ("scan", "folder", "folders to look through"),
        ("hash", "number", "files to fingerprint"),
        ("backup", "externaldrive", "files to copy to disk"),
        ("upload", "icloud.and.arrow.up", "files to upload to S3"),
        ("verify", "checkmark.shield", "copies to re-check"),
    ]
    private let runningRows = 5

    var body: some View {
        let s = model.stats
        VStack(alignment: .leading, spacing: 10) {
            header(s)
            if !compact {
                HStack(alignment: .top, spacing: 18) {
                    queueColumn(s).frame(width: 340)
                    Divider().frame(height: CGFloat(runningRows) * 22 + 22)
                    runningColumn(s)
                }
            }
            footer(s)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: compact ? 92 : 236)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(s.engineRunning ? Color.green.opacity(0.35) : (s.jobsPending > 0 ? Color.orange.opacity(0.5) : Color.clear), lineWidth: 1.5))
    }

    // MARK: Pieces

    private func header(_ s: CatalogStats) -> some View {
        HStack(spacing: 10) {
            Circle().fill(s.engineRunning ? Color.green : (s.jobsPending > 0 ? Color.orange : Color.secondary)).frame(width: 10, height: 10)
            Text(headline(s)).font(.title3).bold().lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            Text(s.engineRunning && s.throughputBytesPerSecond > 0 ? "\(Format.bytes(Int64(s.throughputBytesPerSecond)))/s" : " ")
                .monospacedDigit().foregroundStyle(.secondary).frame(width: 96, alignment: .trailing)
            Button(s.engineRunning ? "Pause" : "Start") { Task { await model.toggleEngine() } }
                .buttonStyle(.borderedProminent).tint(s.engineRunning ? .orange : .green)
                .disabled(!s.engineRunning && s.jobsPending == 0)
                .frame(width: 76)
        }
        .frame(height: 28)
    }

    /// Five fixed rows, one per kind of work; a kind with nothing queued shows a dash rather than vanishing.
    private func queueColumn(_ s: CatalogStats) -> some View {
        var byKind: [String: (count: Int, bytes: Int64, targets: [String])] = [:]
        for q in s.queue {
            var e = byKind[q.kind] ?? (0, 0, [])
            e.count += q.count; e.bytes += q.bytes
            if let t = q.targetName, !e.targets.contains(t) { e.targets.append(t) }
            byKind[q.kind] = e
        }
        let other = s.queue.filter { q in !Self.queueKinds.contains { $0.kind == q.kind } }.reduce((0, Int64(0))) { ($0.0 + $1.count, $0.1 + $1.bytes) }
        return VStack(alignment: .leading, spacing: 2) {
            Text("Queue").font(.caption).foregroundStyle(.secondary).frame(height: 18)
            ForEach(Self.queueKinds, id: \.kind) { k in
                let e = byKind[k.kind]
                HStack(spacing: 8) {
                    Image(systemName: k.icon).frame(width: 16).foregroundStyle(e == nil ? .quaternary : .secondary)
                    Text(e.map { Format.count($0.count) } ?? "—").monospacedDigit().frame(width: 58, alignment: .trailing).foregroundStyle(e == nil ? .tertiary : .primary)
                    Text(k.label).font(.callout).foregroundStyle(e == nil ? .tertiary : .primary).lineLimit(1)
                    Spacer(minLength: 0)
                    Text(e.map { $0.bytes > 0 ? Format.bytes($0.bytes) : " " } ?? " ").font(.caption).monospacedDigit().foregroundStyle(.secondary).frame(width: 70, alignment: .trailing)
                }
                .frame(height: 22)
                .help(e.map { $0.targets.isEmpty ? "" : "to " + $0.targets.joined(separator: ", ") } ?? "")
            }
            HStack {
                Text(other.0 > 0 ? "+ \(Format.count(other.0)) other tasks" : " ").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Text(eta(s).map { "about \($0) left" } ?? " ").font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            .frame(height: 18)
        }
    }

    /// The same number of rows every time; rows without a job are blank.
    private func runningColumn(_ s: CatalogStats) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Working on").font(.caption).foregroundStyle(.secondary).frame(height: 18)
            ForEach(0..<runningRows, id: \.self) { i in
                let j: RunningJob? = i < s.running.count ? s.running[i] : nil
                HStack(spacing: 8) {
                    Image(systemName: j.map { icon($0.kind) } ?? "circle").frame(width: 16).foregroundStyle(j == nil ? Color.clear : Color.accentColor)
                    Text(j.map { verb($0.kind) } ?? " ").font(.caption).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
                    Text(j?.name ?? " ").lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                    Text(j?.targetName.map { "→ \($0)" } ?? " ").font(.caption).foregroundStyle(.secondary).lineLimit(1).frame(width: 110, alignment: .leading)
                    ProgressView(value: j.map { $0.bytesTotal > 0 ? min(1, Double($0.bytesDone) / Double($0.bytesTotal)) : 0 } ?? 0)
                        .frame(width: 100).opacity(j == nil ? 0 : 1)
                    Text(j.map { $0.bytesTotal > 0 ? Format.bytes($0.bytesTotal) : " " } ?? " ").font(.caption).monospacedDigit().foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
                }
                .frame(height: 22)
            }
            Text(s.running.count > runningRows ? "+ \(s.running.count - runningRows) more" : (s.jobsRunning > 0 ? "\(s.jobsRunning) running" : " "))
                .font(.caption2).foregroundStyle(.tertiary).frame(height: 18)
        }
    }

    /// One line, always present: the failure count, the paused note, or what idle means.
    private func footer(_ s: CatalogStats) -> some View {
        HStack(spacing: 8) {
            if s.jobsFailed > 0 {
                Label("\(s.jobsFailed) failed — see Activity for the reason", systemImage: "xmark.octagon").foregroundStyle(.red)
                Spacer()
                Button("Retry") { Task { await model.retryFailed() } }.controlSize(.small)
            } else if !s.engineRunning && s.jobsPending > 0 {
                Label("Nothing is happening until you press Start. The work is saved and carries on from where it stopped.", systemImage: "pause.circle").foregroundStyle(.orange)
            } else if s.engineRunning && s.queue.isEmpty && s.running.isEmpty {
                Label("Queue is empty. Watching your folders and re-checking old copies in the background.", systemImage: "eye").foregroundStyle(.secondary)
            } else if !s.engineRunning {
                Label("Everything you asked for is done.", systemImage: "checkmark").foregroundStyle(.secondary)
            } else if compact {
                Text(compactSummary(s)).foregroundStyle(.secondary).lineLimit(1)
            } else {
                Text(" ")
            }
        }
        .font(.callout)
        .frame(height: 20)
    }

    // MARK: Words

    private func headline(_ s: CatalogStats) -> String {
        if s.engineRunning {
            if s.running.isEmpty && s.queue.isEmpty { return "Idle, watching" }
            let kinds = Set(s.running.map(\.kind))
            if kinds.contains("upload") { return "Uploading to S3" }
            if kinds.contains("reclass") { return "Moving S3 copies to another storage class" }
            if kinds.contains("backup") { return "Copying to the backup disk" }
            if kinds.contains("import") { return "Bringing photos into the library" }
            if kinds.contains("hash") { return "Reading and fingerprinting files" }
            if kinds.contains("scan") { return "Looking through folders" }
            if kinds.contains("verify") { return "Checking existing copies" }
            return "Working"
        }
        return s.jobsPending > 0 ? "Paused — \(Format.count(s.jobsPending)) tasks waiting" : "Idle"
    }

    private func compactSummary(_ s: CatalogStats) -> String {
        let parts = Self.queueKinds.compactMap { k -> String? in
            let n = s.queue.filter { $0.kind == k.kind }.reduce(0) { $0 + $1.count }
            return n > 0 ? "\(Format.count(n)) \(k.label)" : nil
        }
        var line = parts.isEmpty ? "Working" : parts.joined(separator: " · ")
        if let e = eta(s) { line += " · about \(e) left" }
        return line
    }

    private func verb(_ k: String) -> String {
        switch k { case "hash": return "reading"; case "backup": return "copying"; case "upload": return "uploading"; case "import": return "importing"; case "verify": return "checking"; case "scan": return "looking"; case "reclass": return "moving"; default: return k }
    }

    private func icon(_ k: String) -> String {
        switch k { case "hash": return "number"; case "backup": return "externaldrive"; case "upload": return "icloud.and.arrow.up"; case "import": return "photo"; case "verify": return "checkmark.shield"; case "scan": return "folder"; case "reclass": return "arrow.left.arrow.right"; default: return "circle" }
    }

    private func eta(_ s: CatalogStats) -> String? {
        // Only worth saying when real data is moving; a trickle divided into a small queue gives silly numbers.
        guard s.engineRunning, s.throughputBytesPerSecond > 1_000_000 else { return nil }
        let bytes = s.queue.reduce(Int64(0)) { $0 + $1.bytes }
        guard bytes > 50_000_000 else { return nil }
        return Format.duration(Double(bytes) / s.throughputBytesPerSecond)
    }
}

/// One line per kind of outstanding work for a folder, used on its card.
struct FolderActivityView: View {
    var coverage: FolderCoverage
    var body: some View {
        ForEach(coverage.activity) { a in
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini).opacity(a.running > 0 ? 1 : 0)
                Text(text(a)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func text(_ a: FolderCoverage.Activity) -> String {
        switch a.kind {
        case "scan": return "looking through the folder…"
        case "hash": return "fingerprinting \(Format.count(a.count)) files\(a.bytesTotal > 0 ? " · " + Format.bytes(a.bytesTotal) : "")"
        case "backup": return "copying \(Format.count(a.count)) files to the backup disk · \(Format.bytes(a.bytesDone)) of \(Format.bytes(a.bytesTotal))"
        case "upload": return "uploading \(Format.count(a.count)) files · \(Format.bytes(a.bytesDone)) of \(Format.bytes(a.bytesTotal))"
        case "verify": return "re-checking \(Format.count(a.count)) copies"
        case "import": return "importing \(Format.count(a.count)) photos"
        case "reclass": return "moving \(Format.count(a.count)) S3 copies to another storage class"
        default: return "\(a.count) \(a.kind)"
        }
    }
}

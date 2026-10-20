import SwiftUI
import BackupHQCore

/// The one panel that answers "what is it doing?". Sits at the top of the Dashboard and the Folders page.
struct NowPanel: View {
    @Environment(AppModel.self) private var model
    var compact = false

    var body: some View {
        let s = model.stats
        let waiting = s.jobsPending
        // Nothing running, nothing waiting, nothing failed: say nothing. The Home banner already covers "all done".
        if !s.engineRunning && waiting == 0 && s.jobsFailed == 0 && s.running.isEmpty {
            EmptyView()
        } else {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Circle().fill(s.engineRunning ? Color.green : (waiting > 0 ? Color.orange : Color.secondary)).frame(width: 10, height: 10)
                Text(headline(s)).font(.title3).bold()
                Spacer()
                if s.engineRunning && s.throughputBytesPerSecond > 0 {
                    Text("\(Format.bytes(Int64(s.throughputBytesPerSecond)))/s").monospacedDigit().foregroundStyle(.secondary)
                }
                Button(s.engineRunning ? "Pause" : (waiting > 0 ? "Start" : "Start")) { Task { await model.toggleEngine() } }
                    .buttonStyle(.borderedProminent).tint(s.engineRunning ? .orange : .green).disabled(!s.engineRunning && waiting == 0)
            }
            if !s.engineRunning && waiting > 0 {
                Label("Nothing is happening until you press Start. The work is saved and will carry on from where it stopped.", systemImage: "pause.circle")
                    .font(.callout).foregroundStyle(.orange)
            }
            if !s.queue.isEmpty || !s.running.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(s.queue) { q in
                        HStack(spacing: 8) {
                            Image(systemName: icon(q.kind)).frame(width: 16).foregroundStyle(.secondary)
                            Text(queueText(q)).font(.callout)
                            Spacer()
                            Text(q.bytes > 0 ? Format.bytes(q.bytes) : "").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    if let eta = eta(s) { Text("About \(eta) left at the current speed.").font(.caption).foregroundStyle(.secondary) }
                }
            } else if s.engineRunning {
                Text("Queue is empty. The engine stays on and checks old copies in the background.").font(.callout).foregroundStyle(.secondary)
            } else if waiting == 0 {
                Text("Everything you asked for is done.").font(.callout).foregroundStyle(.secondary)
            }
            if !compact && !s.running.isEmpty {
                Divider()
                ForEach(s.running) { j in
                    HStack(spacing: 8) {
                        Image(systemName: icon(j.kind)).frame(width: 16).foregroundStyle(Color.accentColor)
                        Text(verb(j.kind)).font(.caption).foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
                        Text(j.name).lineLimit(1).truncationMode(.middle)
                        if let t = j.targetName { Text("→ \(t)").font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                        Spacer()
                        if j.bytesTotal > 0 {
                            ProgressView(value: min(1, Double(j.bytesDone) / Double(j.bytesTotal))).frame(width: 120)
                            Text(Format.bytes(j.bytesTotal)).font(.caption).monospacedDigit().foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
                        }
                    }
                }
            }
            if s.jobsFailed > 0 {
                HStack {
                    Label("\(s.jobsFailed) failed — see Activity for the reason", systemImage: "xmark.octagon").foregroundStyle(.red).font(.callout)
                    Spacer()
                    Button("Retry") { Task { await model.retryFailed() } }.controlSize(.small)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(s.engineRunning ? Color.green.opacity(0.35) : (s.jobsPending > 0 ? Color.orange.opacity(0.5) : Color.clear), lineWidth: 1.5))
        }
    }

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

    private func queueText(_ q: QueueLine) -> String {
        let n = Format.count(q.count)
        switch q.kind {
        case "scan": return "\(n) folder\(q.count == 1 ? "" : "s") to look through"
        case "hash": return "\(n) file\(q.count == 1 ? "" : "s") to fingerprint"
        case "import": return "\(n) photo\(q.count == 1 ? "" : "s") to bring into the library"
        case "backup": return "\(n) file\(q.count == 1 ? "" : "s") to copy to \(q.targetName ?? "the backup disk")"
        case "upload": return "\(n) file\(q.count == 1 ? "" : "s") to upload to \(q.targetName ?? "S3")"
        case "verify": return "\(n) cop\(q.count == 1 ? "y" : "ies") to re-check"
        case "reclass": return "\(n) cop\(q.count == 1 ? "y" : "ies") to move to another storage class in \(q.targetName ?? "S3") (restores from archive take hours)"
        default: return "\(n) \(q.kind)"
        }
    }

    private func verb(_ k: String) -> String {
        switch k { case "hash": return "reading"; case "backup": return "copying"; case "upload": return "uploading"; case "import": return "importing"; case "verify": return "checking"; case "scan": return "scanning"; case "reclass": return "moving"; default: return k }
    }

    private func icon(_ k: String) -> String {
        switch k { case "hash": return "number"; case "backup": return "externaldrive"; case "upload": return "icloud.and.arrow.up"; case "import": return "photo"; case "verify": return "checkmark.shield"; case "scan": return "folder"; case "reclass": return "arrow.left.arrow.right"; default: return "circle" }
    }

    private func eta(_ s: CatalogStats) -> String? {
        guard s.engineRunning, s.throughputBytesPerSecond > 0 else { return nil }
        let bytes = s.queue.reduce(Int64(0)) { $0 + $1.bytes }
        guard bytes > 0 else { return nil }
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

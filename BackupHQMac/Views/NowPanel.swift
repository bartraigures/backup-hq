import SwiftUI
import BackupHQCore

/// The one panel that answers "what is it doing?". Fixed geometry, and every slot holds something worth reading
/// in every state: four tiles that always have numbers, and a five-row list that shows live jobs while busy and
/// the most recent activity while idle.
struct NowPanel: View {
    @Environment(AppModel.self) private var model
    var compact = false
    private let rows = 5
    private let rowHeight: CGFloat = 20

    var body: some View {
        let s = model.stats
        VStack(alignment: .leading, spacing: 10) {
            header(s)
            if compact {
                Text(compactSummary(s)).font(.callout).foregroundStyle(.secondary).lineLimit(1).frame(height: 20)
            } else {
                HStack(spacing: 10) {
                    tileWatching(s)
                    tileQueue(s)
                    tileRecent(s)
                    tilePlaces(s)
                }
                .frame(height: 62)
                listArea(s)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: compact ? 86 : 28 + 10 + 62 + 10 + 18 + CGFloat(rows) * rowHeight + 28)
        .card()
        // The engine's state is a coloured accent down the left edge, not a border all the way round.
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2).fill(s.engineRunning ? Color.green : (s.jobsPending > 0 ? Color.orange : Color.secondary.opacity(0.4)))
                .frame(width: 4).padding(.vertical, 12).padding(.leading, 0)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: Header

    private func header(_ s: CatalogStats) -> some View {
        HStack(spacing: 10) {
            Text(headline(s)).font(.headline).lineLimit(1)
            if s.jobsFailed > 0 {
                Button { Task { await model.retryFailed() } } label: { Label("\(s.jobsFailed) failed · retry", systemImage: "xmark.octagon") }
                    .buttonStyle(.plain).foregroundStyle(.red).font(.callout)
            }
            Spacer()
            Text(s.engineRunning && s.throughputBytesPerSecond > 0 ? "\(Format.bytes(Int64(s.throughputBytesPerSecond)))/s" : " ")
                .monospacedDigit().foregroundStyle(.secondary).frame(width: 96, alignment: .trailing)
            // Start is the one action that matters when work is waiting, so only then does it get a filled button.
            Group {
                if s.engineRunning { Button("Pause") { Task { await model.toggleEngine() } }.buttonStyle(.bordered) }
                else { Button("Start") { Task { await model.toggleEngine() } }.buttonStyle(.borderedProminent).tint(.green).disabled(s.jobsPending == 0) }
            }
            .frame(width: 76)
        }
        .frame(height: 28)
    }

    // MARK: Tiles

    private func tile(_ title: String, _ big: String, _ small: String, icon: String, tint: Color = .secondary) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint).frame(width: 18).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text(big).font(.callout).bold().monospacedDigit().lineLimit(1)
                Text(small).font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
    }

    private func tileWatching(_ s: CatalogStats) -> some View {
        let folders = s.folders
        let bytes = folders.reduce(0) { $0 + $1.bytes }
        let files = folders.reduce(0) { $0 + $1.fileCount }
        let last = folders.compactMap(\.lastScanned).max()
        let every = model.settings.scanEveryMinutes
        var small = last.map { "last look \($0.formatted(.relative(presentation: .named)))" } ?? "not looked at yet"
        if let last, every > 0 {
            let next = last.addingTimeInterval(Double(every) * 60)
            small += next > Date() ? " · next \(next.formatted(.relative(presentation: .named)))" : " · next look due"
        }
        if model.settings.watchFolders && s.engineRunning { small += " · live" }
        return tile("Watching", "\(folders.count) folder\(folders.count == 1 ? "" : "s") · \(Format.bytes(bytes))", "\(Format.count(files)) files · " + small, icon: "eye", tint: .green)
    }

    private func tileQueue(_ s: CatalogStats) -> some View {
        let count = s.queue.reduce(0) { $0 + $1.count }
        let bytes = s.queue.reduce(Int64(0)) { $0 + $1.bytes }
        let big = count == 0 ? "Queue empty" : "\(Format.count(count)) task\(count == 1 ? "" : "s") · \(Format.bytes(bytes))"
        var small: String
        if count == 0 { small = s.engineRunning ? "watching for changes" : (s.jobsPending > 0 ? "paused" : "nothing waiting") }
        else {
            let parts = Self.kindOrder.compactMap { k -> String? in
                let n = s.queue.filter { $0.kind == k }.reduce(0) { $0 + $1.count }
                return n > 0 ? "\(Format.count(n)) \(Self.shortLabel(k))" : nil
            }
            small = parts.joined(separator: " · ")
            if let e = eta(s) { small = "about \(e) left · " + small }
        }
        return tile("Queue", big, small, icon: "tray.full", tint: count > 0 ? .orange : .secondary)
    }

    private func tileRecent(_ s: CatalogStats) -> some View {
        let by = Dictionary(uniqueKeysWithValues: s.recentWork.map { ($0.kind, $0) })
        let moved = (by["backup"]?.bytes ?? 0) + (by["upload"]?.bytes ?? 0) + (by["import"]?.bytes ?? 0)
        let parts = ["hash", "backup", "upload", "verify", "scan"].compactMap { k -> String? in
            guard let r = by[k], r.count > 0 else { return nil }
            return "\(Format.count(r.count)) \(Self.pastLabel(k))"
        }
        let big = moved > 0 ? "\(Format.bytes(moved)) moved" : (parts.isEmpty ? "Nothing yet" : "\(Format.count(s.recentWork.reduce(0) { $0 + $1.count })) tasks")
        return tile("Last 24 hours", big, parts.isEmpty ? "no work finished" : parts.joined(separator: " · "), icon: "clock.arrow.circlepath", tint: .blue)
    }

    private func tilePlaces(_ s: CatalogStats) -> some View {
        // Only the places copies go to: backup disks and archives, not the tracked folders themselves.
        let disks = s.places.filter { $0.role == "mirror" || $0.role == "library" }
        let s3 = s.places.filter { $0.role == "archive" }
        let diskBits = disks.map { p -> String in
            p.reachable ? "\(p.name) \(p.freeBytes.map { Format.bytes($0) + " free" } ?? Format.bytes(p.verifiedBytes))" : "\(p.name) not plugged in"
        }
        let s3Bits = s3.map { p -> String in
            let usd = p.monthlyUSD
            return "\(p.name) \(Format.bytes(p.verifiedBytes))" + (usd >= 0.005 ? String(format: " · $%.2f/mo", usd) : "")
        }
        let all = diskBits + s3Bits
        let big = all.first ?? "No places yet"
        let rest = all.dropFirst().joined(separator: " · ")
        return tile("Places", big, rest.isEmpty ? "\(s.places.count) place\(s.places.count == 1 ? "" : "s")" : rest, icon: "externaldrive.badge.icloud", tint: .accentColor)
    }

    // MARK: The five-row list

    private func listArea(_ s: CatalogStats) -> some View {
        let live = !s.running.isEmpty
        return VStack(alignment: .leading, spacing: 2) {
            Text(live ? "Working on" : "Recently").font(.caption).foregroundStyle(.secondary).frame(height: 18)
            ForEach(0..<rows, id: \.self) { i in
                if live { runningRow(i < s.running.count ? s.running[i] : nil) }
                else { eventRow(i < s.recentEvents.count ? s.recentEvents[i] : nil) }
            }
            Text(live ? (s.running.count > rows ? "+ \(s.running.count - rows) more" : "\(s.jobsRunning) running") : " ")
                .font(.caption2).foregroundStyle(.tertiary).frame(height: 18)
        }
    }

    private func runningRow(_ j: RunningJob?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: j.map { icon($0.kind) } ?? "circle").frame(width: 16).foregroundStyle(j == nil ? Color.clear : Color.accentColor)
            Text(j.map { verb($0.kind) } ?? " ").font(.caption).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
            Text(j?.name ?? " ").lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
            Text(j?.targetName.map { "→ \($0)" } ?? " ").font(.caption).foregroundStyle(.secondary).lineLimit(1).frame(width: 110, alignment: .leading)
            ProgressView(value: j.map { $0.bytesTotal > 0 ? min(1, Double($0.bytesDone) / Double($0.bytesTotal)) : 0 } ?? 0)
                .frame(width: 100).opacity(j == nil ? 0 : 1)
            Text(j.map { $0.bytesTotal > 0 ? Format.bytes($0.bytesTotal) : " " } ?? " ").font(.caption).monospacedDigit().foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
        }
        .frame(height: rowHeight)
    }

    private func eventRow(_ e: CatalogStats.RecentEvent?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: e.map { $0.level == "error" ? "xmark.octagon.fill" : ($0.level == "warning" ? "exclamationmark.triangle.fill" : ($0.level == "notice" ? "info.circle" : "checkmark.circle")) } ?? "circle")
                .frame(width: 16).foregroundStyle(e.map { $0.level == "error" ? Color.red : ($0.level == "warning" ? .orange : .secondary) } ?? .clear)
            Text(e.map { $0.time.formatted(date: .omitted, time: .shortened) } ?? " ").font(.caption).monospacedDigit().foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
            Text(e?.message ?? " ").font(.callout).lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading).help(e?.message ?? "")
        }
        .frame(height: rowHeight)
    }

    // MARK: Words

    private static let kindOrder = ["scan", "hash", "backup", "upload", "verify", "import", "reclass"]
    private static func shortLabel(_ k: String) -> String {
        switch k { case "scan": return "to look through"; case "hash": return "to fingerprint"; case "backup": return "to copy"; case "upload": return "to upload"; case "verify": return "to re-check"; case "import": return "to import"; case "reclass": return "to re-class"; default: return k }
    }
    private static func pastLabel(_ k: String) -> String {
        switch k { case "scan": return "looks"; case "hash": return "fingerprinted"; case "backup": return "copied"; case "upload": return "uploaded"; case "verify": return "re-checked"; case "import": return "imported"; default: return k }
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

    private func compactSummary(_ s: CatalogStats) -> String {
        if s.jobsFailed > 0 { return "\(s.jobsFailed) failed — see Activity" }
        if !s.engineRunning && s.jobsPending > 0 { return "Paused. The work is saved and carries on from where it stopped when you press Start." }
        let count = s.queue.reduce(0) { $0 + $1.count }
        if count == 0 { return s.engineRunning ? "Queue is empty. Watching your folders and re-checking old copies in the background." : "Everything you asked for is done." }
        let parts = Self.kindOrder.compactMap { k -> String? in
            let n = s.queue.filter { $0.kind == k }.reduce(0) { $0 + $1.count }
            return n > 0 ? "\(Format.count(n)) \(Self.shortLabel(k))" : nil
        }
        var line = parts.joined(separator: " · ")
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

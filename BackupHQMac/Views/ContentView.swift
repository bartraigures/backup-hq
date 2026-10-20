import SwiftUI
import BackupHQCore

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 220)
                .safeAreaInset(edge: .bottom) { EngineFooter() }
        } detail: {
            DetailView()
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) { EngineToolbarButton() }
        }
        .alert("Something went wrong", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .alert("Backup HQ", isPresented: Binding(get: { model.infoMessage != nil }, set: { if !$0 { model.infoMessage = nil } })) {
            Button("OK") { model.infoMessage = nil }
        } message: { Text(model.infoMessage ?? "") }
    }
}

/// The sidebar reads only the selection and three badge counters, so the two-second stats refresh
/// does not rebuild the list under the user's cursor. A click can never clear the selection.
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let selection = Binding<NavItem?>(get: { model.selection ?? .home }, set: { if let v = $0 { model.selection = v } })
        List(model.navItems, id: \.self, selection: selection) { item in
            Label(item.rawValue, systemImage: item.icon)
                .badge(badge(for: item))
        }
    }
    private func badge(for item: NavItem) -> Int {
        switch item {
        case .activity: return model.badgeJobs
        case .folders: return model.badgeVulnerable
        default: return 0
        }
    }
}

struct DetailView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        Group {
            switch model.selection ?? .home {
            case .home: HomeView()
            case .folders: FoldersView()
            case .lightroom: LightroomView()
            case .activity: ActivityView()
            }
        }
        .navigationTitle(model.selection?.rawValue ?? "Backup HQ")
    }
}

struct EngineToolbarButton: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        Button {
            Task { await model.toggleEngine() }
        } label: {
            Label(model.stats.engineRunning ? "Pause" : "Start", systemImage: model.stats.engineRunning ? "pause.fill" : "play.fill")
        }
        .help(model.stats.engineRunning ? "Pause all work safely. Nothing is lost; everything resumes where it stopped." : "Start working through the queue.")
    }
}

/// Sidebar footer: engine state, throughput and what is left.
struct EngineFooter: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let s = model.stats
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(s.engineRunning ? Color.green : (s.jobsPending > 0 ? Color.orange : Color.secondary)).frame(width: 8, height: 8)
                Text(s.engineRunning ? "Working" : (s.jobsPending > 0 ? "Paused — \(Format.count(s.jobsPending)) waiting" : "Idle")).font(.caption).bold()
            }
            if s.engineRunning {
                Text("\(Format.bytes(Int64(s.throughputBytesPerSecond)))/s · \(s.jobsRunning) running").font(.caption2).foregroundStyle(.secondary)
                let left = s.bytesPendingImport + s.bytesPendingUpload
                if left > 0 {
                    let eta = s.throughputBytesPerSecond > 0 ? Double(left) / s.throughputBytesPerSecond : .infinity
                    Text("\(Format.bytes(left)) left · about \(Format.duration(eta))").font(.caption2).foregroundStyle(.secondary)
                }
            }
            if s.jobsFailed > 0 {
                Text("\(s.jobsFailed) failed — see Activity").font(.caption2).foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        .padding(8)
    }
}

// MARK: - Shared bits

struct StatTile: View {
    var title: String
    var value: String
    var detail: String? = nil
    var tint: Color = .primary
    var systemImage: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let systemImage { Image(systemName: systemImage).foregroundStyle(tint) }
                Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Text(value).font(.system(.title2, design: .rounded)).bold().foregroundStyle(tint).lineLimit(1).minimumScaleFactor(0.7)
            if let detail { Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(2) }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 84, alignment: .topLeading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.06), radius: 6, x: 0, y: 3)
    }
}

/// Card surface used across the app: background contrast and a soft offset shadow do the separating; no border.
struct CardStyle: ViewModifier {
    func body(content: Self.Content) -> some View {   // Self. because the catalogue model also has a type called Content
        content
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.06), radius: 6, x: 0, y: 3)
    }
}
extension View { func card() -> some View { modifier(CardStyle()) } }

struct SectionBox<Content: View>: View {
    var title: String
    var subtitle: String? = nil
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

struct ProgressRow: View {
    var label: String
    var done: Int64
    var total: Int64
    var unitIsBytes = true
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.subheadline)
                Spacer()
                Text(unitIsBytes ? "\(Format.bytes(done)) of \(Format.bytes(total))" : "\(Format.count(Int(done))) of \(Format.count(Int(total)))")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                Text(total > 0 ? "\(Int(Double(done) / Double(total) * 100))%" : "—").font(.caption).monospacedDigit().bold().frame(width: 40, alignment: .trailing)
            }
            ProgressView(value: total > 0 ? min(1, Double(done) / Double(total)) : 0)
        }
    }
}

extension CopyStatus {
    var color: Color {
        switch self { case .verified: return .green; case .unverified: return .orange; case .missing: return .red; case .corrupt: return .red }
    }
}

extension Location {
    var icon: String {
        switch role {
        case .library: return "photo.on.rectangle"
        case .tracked: return placeKind == .mac ? "folder" : "folder.badge.gearshape"
        case .mirror: return "externaldrive.badge.checkmark"
        case .archive: return "icloud"
        case .adobe: return "cloud"
        case .source: return "tray.and.arrow.down"
        }
    }
}

extension PlaceKind {
    var icon: String {
        switch self { case .mac: return "laptopcomputer"; case .external: return "externaldrive"; case .s3: return "icloud"; case .adobe: return "cloud" }
    }
    var label: String {
        switch self { case .mac: return "this Mac"; case .external: return "external disk"; case .s3: return "S3"; case .adobe: return "Adobe" }
    }
}

/// Safety status of a folder against its own targets.
enum FolderSafety {
    case complete, queued, sweeping, belowPolicy, singleByChoice, offline
    var color: Color {
        switch self { case .complete: return .green; case .queued: return .green; case .sweeping: return .orange; case .belowPolicy: return .red; case .singleByChoice: return .gray; case .offline: return .gray }
    }
    var word: String {
        switch self { case .complete: return "safe"; case .queued: return "copies on the way"; case .sweeping: return "being fingerprinted"; case .belowPolicy: return "missing a copy"; case .singleByChoice: return "no backup by choice"; case .offline: return "disk not plugged in" }
    }
}

extension FolderCoverage {
    var safety: FolderSafety {
        if !reachable { return .offline }
        if targets.isEmpty { return .singleByChoice }
        if vulnerableCount == 0 { return .complete }
        // Still being fingerprinted: copies are queued when the sweep ends, so this is progress, not a gap.
        if activity.contains(where: { $0.kind == "hash" && $0.count > 0 }) { return .sweeping }
        // Vulnerable but every gap already has a job queued → queued.
        let allQueued = targets.allSatisfy { t in (fileCount - t.coveredCount) <= t.pendingCount }
        return allQueued ? .queued : .belowPolicy
    }
    var queuedBytes: Int64 { targets.reduce(0) { $0 + $1.pendingBytes } }
    /// Bytes with no copy at some target and nothing queued for it.
    var gapBytes: Int64 { targets.reduce(0) { $0 + max(0, bytes - $1.coveredBytes - $1.pendingBytes) } }
}

struct Pill: View {
    var text: String
    var color: Color = .secondary
    var body: some View {
        Text(text).font(.caption2).padding(.horizontal, 7).padding(.vertical, 2)
            .background(color.opacity(0.14), in: Capsule()).foregroundStyle(color)
    }
}

import SwiftUI
import BackupHQCore

/// What the engine has done and is doing, plus the plain-text log for when something went wrong.
struct ActivityView: View {
    @State private var tab: Tab = .jobs
    enum Tab: String, CaseIterable { case jobs = "Tasks", log = "Log" }
    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) { ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden().frame(width: 200).padding(.vertical, 10)
            Divider()
            switch tab {
            case .jobs: JobsView()
            case .log: LogView()
            }
        }
    }
}

struct JobsView: View {
    @Environment(AppModel.self) private var model
    @State private var jobs: [Job] = []
    @State private var stateFilter: JobState? = nil
    @State private var kindFilter: JobKind? = nil
    @State private var locationNames: [Int64: String] = [:]
    @State private var lastLoad = Date.distantPast
    @State private var lastSignature = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("State", selection: $stateFilter) {
                    Text("All").tag(JobState?.none)
                    ForEach(JobState.allCases, id: \.self) { Text($0.rawValue.capitalized).tag(JobState?.some($0)) }
                }.frame(width: 160)
                Picker("Kind", selection: $kindFilter) {
                    Text("All").tag(JobKind?.none)
                    ForEach(JobKind.allCases, id: \.self) { Text($0.rawValue.capitalized).tag(JobKind?.some($0)) }
                }.frame(width: 160)
                Spacer()
                if model.stats.jobsFailed > 0 { Button("Retry all failed") { Task { await model.retryFailed(); await load() } } }
                Button("Clear finished") { Task { await model.clearDone(); await load() } }
            }
            .padding(12)
            Table(jobs) {
                TableColumn("") { j in
                    Image(systemName: icon(j.state)).foregroundStyle(color(j.state))
                }.width(20)
                TableColumn("Kind") { Text($0.kind.rawValue.capitalized) }.width(60)
                TableColumn("File") { j in Text(j.displayName).lineLimit(1).help(j.sourcePath ?? j.sha256 ?? "") }
                TableColumn("To") { j in Text(j.targetLocationId.flatMap { locationNames[$0] } ?? "—").foregroundStyle(.secondary) }.width(140)
                TableColumn("Progress") { j in
                    if j.state == .running && j.bytesTotal > 0 {
                        ProgressView(value: Double(j.bytesDone) / Double(max(1, j.bytesTotal)))
                    } else {
                        Text(j.bytesTotal > 0 ? Format.bytes(j.bytesTotal) : "").foregroundStyle(.secondary).monospacedDigit()
                    }
                }.width(140)
                TableColumn("Tries") { Text("\($0.attempts)").monospacedDigit() }.width(40)
                TableColumn("Status") { j in
                    if let e = j.error { Text(e).foregroundStyle(j.state == .failed ? .red : .secondary).lineLimit(1).help(e) } else { Text(j.state.rawValue.capitalized).foregroundStyle(color(j.state)) }
                }
                TableColumn("Updated") { Text($0.updated.formatted(date: .omitted, time: .standard)).monospacedDigit() }.width(80)
            }
            .contextMenu(forSelectionType: Job.ID.self) { ids in
                Button("Retry") { Task { for id in ids { try? await model.db?.retryJob(id: id) }; await load() } }
                Button("Remove", role: .destructive) { Task { for id in ids { try? await model.db?.deleteJob(id: id) }; await load() } }
            }
        }
        .task { await load(force: true) }
        .onChange(of: model.stats.generatedAt) { _, _ in Task { await load() } }
        .onChange(of: stateFilter) { _, _ in Task { await load(force: true) } }
        .onChange(of: kindFilter) { _, _ in Task { await load(force: true) } }
    }

    /// Re-reads only when the queue actually changed shape, or every few seconds while something is running
    /// (for the progress bars). Uses the UI's own database connection so it never waits behind the engine.
    private func load(force: Bool = false) async {
        guard let db = model.statsDB ?? model.db else { return }
        let s = model.stats
        let signature = "\(s.jobsPending)/\(s.jobsRunning)/\(s.jobsFailed)/\(s.jobsDone)"
        let stale = Date().timeIntervalSince(lastLoad)
        guard force || (signature != lastSignature && stale > 1) || (s.jobsRunning > 0 && stale > 3) else { return }
        lastSignature = signature; lastLoad = Date()
        jobs = (try? await db.jobs(state: stateFilter, kind: kindFilter, limit: 300)) ?? []
        if locationNames.isEmpty { for l in model.locations { locationNames[l.id] = l.name } }
    }

    private func icon(_ s: JobState) -> String {
        switch s { case .pending: return "clock"; case .running: return "arrow.triangle.2.circlepath"; case .done: return "checkmark.circle.fill"; case .failed: return "xmark.octagon.fill"; case .paused: return "pause.circle" }
    }
    private func color(_ s: JobState) -> Color {
        switch s { case .pending: return .secondary; case .running: return .blue; case .done: return .green; case .failed: return .red; case .paused: return .orange }
    }
}

struct LogView: View {
    @Environment(AppModel.self) private var model
    @State private var events: [Event] = []
    @State private var level: String? = nil
    @State private var lastLoad = Date.distantPast

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Level", selection: $level) {
                    Text("Everything").tag(String?.none)
                    Text("Errors").tag(String?.some("error"))
                    Text("Warnings").tag(String?.some("warning"))
                    Text("Notices").tag(String?.some("notice"))
                }.frame(width: 180)
                Spacer()
            }.padding(12)
            Table(events) {
                TableColumn("Time") { Text($0.time.formatted(date: .abbreviated, time: .standard)).monospacedDigit() }.width(170)
                TableColumn("Level") { e in Text(e.level).foregroundStyle(e.level == "error" ? .red : (e.level == "warning" ? .orange : .secondary)) }.width(60)
                TableColumn("Message") { Text($0.message).textSelection(.enabled) }
            }
        }
        .task { await load(force: true) }
        .onChange(of: model.stats.generatedAt) { _, _ in Task { await load() } }
        .onChange(of: level) { _, _ in Task { await load(force: true) } }
    }

    private func load(force: Bool = false) async {
        guard let db = model.statsDB ?? model.db else { return }
        guard force || Date().timeIntervalSince(lastLoad) > 5 else { return }
        lastLoad = Date()
        let fresh = (try? await db.events(limit: 300, level: level)) ?? []
        if fresh.first?.id != events.first?.id || fresh.count != events.count { events = fresh }
    }
}

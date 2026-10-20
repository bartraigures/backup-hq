import SwiftUI
import BackupHQCore

/// Home answers two questions, in order: is everything safe, and what is the app doing right now.
struct HomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let s = model.stats
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                StatusBanner()
                NowPanel()
                AlertsPanel()

                if !s.folders.isEmpty {
                    SectionBox(title: "Your folders", subtitle: "Sized by bytes. Green is safe, red is missing a copy you asked for. Click one to manage it.") {
                        let total = s.folders.reduce(0) { $0 + $1.bytes }
                        Treemap(items: s.folders.map { TreemapItem(id: $0.id, value: max(Double($0.bytes), Double(total) * 0.015), folder: $0) }) { f in
                            model.coverageSelection = f.id
                            model.selection = .folders
                        }
                        .frame(height: 300)
                        Legend()
                    }
                }

                HStack(alignment: .top, spacing: 16) {
                    SectionBox(title: "Places", subtitle: "What each disk and the bucket hold.") {
                        if s.places.isEmpty { Text("No backup disk or S3 archive yet. Add one under Folders.").foregroundStyle(.secondary) }
                        ForEach(s.places) { p in PlaceRow(place: p) }
                    }
                    SectionBox(title: "Protected over time", subtitle: "Bytes with every copy their folder asks for.") {
                        TimelineChart(history: s.history).frame(height: 150)
                        HStack(spacing: 14) {
                            LegendSwatch(color: .green, text: "Fully protected")
                            LegendSwatch(color: .accentColor, text: "In S3")
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(20)
        }
    }
}

/// One sentence, one colour: the whole point of the app.
struct StatusBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let s = model.stats
        let folders = s.folders
        let gap = folders.reduce(0) { $0 + $1.gapBytes }
        let queued = folders.reduce(0) { $0 + $1.queuedBytes }
        let offline = s.places.filter { !$0.reachable }.map(\.name)
        let critical = s.alerts.contains { $0.severity == .critical && $0.acknowledgedAt == nil }
        let (icon, colour, title, detail) = line(folders: folders, gap: gap, queued: queued, critical: critical, running: s.engineRunning)
        HStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 34)).foregroundStyle(colour)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.title2).bold()
                Text(detail).font(.callout).foregroundStyle(.secondary)
                if !offline.isEmpty { Text("\(offline.joined(separator: ", ")) \(offline.count == 1 ? "is" : "are") not plugged in right now. Nothing is wrong; copies there were made already.").font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            if gap > 0 && !s.engineRunning {
                Button("Start copying") { Task { await model.toggleEngine() } }.buttonStyle(.borderedProminent).tint(.green)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(colour.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(colour.opacity(0.35)))
    }

    private func line(folders: [FolderCoverage], gap: Int64, queued: Int64, critical: Bool, running: Bool) -> (String, Color, String, String) {
        let total = folders.reduce(0) { $0 + $1.bytes }
        let summary = "\(folders.count) folder\(folders.count == 1 ? "" : "s") · \(Format.bytes(total))"
        if critical { return ("exclamationmark.octagon.fill", .red, "Something needs your attention", "See the red item below.") }
        if folders.isEmpty { return ("folder.badge.plus", .secondary, "Nothing is tracked yet", "Go to Folders and pick a folder to look after.") }
        if gap > 0 && !running { return ("exclamationmark.triangle.fill", .red, "\(Format.bytes(gap)) is only in one place", "Press Start copying and it goes where you asked. \(summary).") }
        if gap + queued > 0 { return ("arrow.triangle.2.circlepath", .orange, "Copying — \(Format.bytes(gap + queued)) still to go", "Everything else is where you said it should be. \(summary).") }
        let chosen = folders.filter { $0.safety == .singleByChoice }
        if !chosen.isEmpty { return ("checkmark.shield.fill", .green, "Everything is where you said it should be", "\(summary). \(chosen.count) folder\(chosen.count == 1 ? " has" : "s have") no backup by your choice.") }
        return ("checkmark.shield.fill", .green, "Everything is where you said it should be", summary)
    }
}

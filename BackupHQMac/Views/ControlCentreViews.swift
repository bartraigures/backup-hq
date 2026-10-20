import SwiftUI
import Charts
import BackupHQCore

// MARK: - Shared pieces used by Home and Folders

struct Legend: View {
    var body: some View {
        HStack(spacing: 14) {
            LegendSwatch(color: .green, text: "Safe")
            LegendSwatch(color: .green.opacity(0.6), text: "Copies on the way")
            LegendSwatch(color: .red, text: "Missing a copy")
            LegendSwatch(color: .gray, text: "No backup by choice")
            LegendSwatch(color: .gray.opacity(0.4), text: "Disk not plugged in")
        }.font(.caption).foregroundStyle(.secondary)
    }
}

struct LegendSwatch: View {
    var color: Color; var text: String
    var body: some View { HStack(spacing: 5) { RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10); Text(text) } }
}

struct PlaceRow: View {
    var place: PlaceSummary
    var body: some View {
        let kind = PlaceKind(rawValue: place.place) ?? .external
        HStack(spacing: 12) {
            Image(systemName: kind.icon).frame(width: 22).foregroundStyle(place.reachable ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack { Text(place.name).bold(); if !place.reachable { Pill(text: "not plugged in", color: .secondary) } }
                Text("\(Format.bytes(place.verifiedBytes)) · \(Format.count(place.verifiedCount)) files" + (place.freeBytes.map { " · \(Format.bytes($0)) free" } ?? ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let free = place.freeBytes {
                let total = Double(free + place.verifiedBytes)
                ProgressView(value: total > 0 ? Double(place.verifiedBytes) / total : 0).frame(width: 120)
            }
        }
        .padding(.vertical, 4)
    }
}

struct TimelineChart: View {
    var history: [CoverageSnapshot]
    var body: some View {
        if history.count < 2 {
            VStack { Spacer(); Text("The curve appears once the app has run for a while.").font(.caption).foregroundStyle(.secondary); Spacer() }.frame(maxWidth: .infinity)
        } else {
            Chart {
                // Each mark names its series; otherwise Swift Charts joins the
                // "protected" and "S3" points at every timestamp into one zigzag.
                ForEach(history) { h in
                    AreaMark(x: .value("Time", h.time), y: .value("GB", Double(h.protectedBytes) / 1e9), series: .value("Series", "Protected"))
                        .foregroundStyle(.green.opacity(0.25))
                    LineMark(x: .value("Time", h.time), y: .value("GB", Double(h.protectedBytes) / 1e9), series: .value("Series", "Protected"))
                        .foregroundStyle(.green)
                    LineMark(x: .value("Time", h.time), y: .value("GB", Double(h.s3Bytes) / 1e9), series: .value("Series", "S3"))
                        .foregroundStyle(Color.accentColor).lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                }
            }
            .chartYScale(domain: .automatic(includesZero: true))
            .chartYAxisLabel("GB")
        }
    }
}

// MARK: - Treemap (squarified)

struct TreemapItem: Identifiable {
    var id: Int64
    var value: Double
    var folder: FolderCoverage
}

struct Treemap: View {
    var items: [TreemapItem]
    var onTap: (FolderCoverage) -> Void

    var body: some View {
        GeometryReader { geo in
            let rects = Treemap.squarify(items.filter { $0.value > 0 }, in: CGRect(origin: .zero, size: geo.size))
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.4))
                ForEach(rects, id: \.item.id) { r in
                    let f = r.item.folder
                    Button { onTap(f) } label: {
                        ZStack(alignment: .topLeading) {
                            RoundedRectangle(cornerRadius: 6).fill(color(for: f))
                            if f.safety == .queued {
                                RoundedRectangle(cornerRadius: 6).fill(ImagePaint(image: Image(systemName: "line.diagonal"), scale: 0.4)).opacity(0.18)
                            }
                            if !f.reachable { RoundedRectangle(cornerRadius: 6).fill(.black.opacity(0.25)) }
                            if r.rect.width > 60 && r.rect.height > 26 {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(f.name).font(.caption).bold().lineLimit(1)
                                    if r.rect.height > 44 {
                                        Text(Format.bytes(f.bytes) + " · " + f.safety.word).font(.caption2).lineLimit(2)
                                    }
                                }
                                .foregroundStyle(.white).padding(7)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .frame(width: max(0, r.rect.width - 3), height: max(0, r.rect.height - 3))
                    .offset(x: r.rect.minX + 1.5, y: r.rect.minY + 1.5)
                    .help("\(f.name): \(Format.bytes(f.bytes)), \(f.safety.word)")
                }
            }
        }
    }

    private func color(for f: FolderCoverage) -> Color {
        switch f.safety { case .complete: return .green; case .queued: return .green.opacity(0.75); case .belowPolicy: return .red; case .singleByChoice: return .gray; case .offline: return .gray.opacity(0.6) }
    }

    struct Placed { var item: TreemapItem; var rect: CGRect }

    /// Squarified treemap (Bruls, Huizing, van Wijk). Items are laid largest first.
    static func squarify(_ items: [TreemapItem], in bounds: CGRect) -> [Placed] {
        var out: [Placed] = []
        let total = items.reduce(0) { $0 + $1.value }
        guard total > 0, bounds.width > 0, bounds.height > 0 else { return out }
        var rest = items.sorted { $0.value > $1.value }
        let scale = bounds.width * bounds.height / total
        var x = bounds.minX, y = bounds.minY, w = bounds.width, h = bounds.height
        while !rest.isEmpty && w > 0 && h > 0 {
            let horizontal = w >= h
            let side = horizontal ? h : w
            var row: [TreemapItem] = []
            var best = Double.infinity
            while let next = rest.first {
                let cand = row + [next]
                let sum = cand.reduce(0) { $0 + $1.value * scale }
                let len = sum / side
                let worst = cand.map { i -> Double in let t = i.value * scale / len; return max(len / t, t / len) }.max() ?? .infinity
                if worst <= best { row = cand; best = worst; rest.removeFirst() } else { break }
            }
            let sum = row.reduce(0) { $0 + $1.value * scale }
            let len = sum / side
            var off: CGFloat = 0
            for i in row {
                let t = i.value * scale / len
                let r = horizontal ? CGRect(x: x, y: y + off, width: len, height: t) : CGRect(x: x + off, y: y, width: t, height: len)
                out.append(Placed(item: i, rect: r))
                off += t
            }
            if horizontal { x += len; w -= len } else { y += len; h -= len }
        }
        return out
    }
}

// MARK: - Alerts

/// What needs attention, with acknowledge. Hidden entirely when there is nothing to say.
struct AlertsPanel: View {
    @Environment(AppModel.self) private var model
    @State private var showAcknowledged = false
    private let rowHeight: CGFloat = 58
    private let visibleRows = 3

    var body: some View {
        let all = model.stats.alerts
        let alerts = all.filter { showAcknowledged || $0.acknowledgedAt == nil }
        let acknowledged = all.filter { $0.acknowledgedAt != nil }.count
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Needs attention").font(.headline)
                Text(alerts.isEmpty ? " " : "\(alerts.count)").font(.caption).monospacedDigit().foregroundStyle(.secondary).frame(width: 30, alignment: .leading)
                Spacer()
                Toggle("Show acknowledged (\(acknowledged))", isOn: $showAcknowledged).toggleStyle(.checkbox).font(.caption).disabled(acknowledged == 0)
            }
            .frame(height: 20)
            // As tall as its rows up to three; beyond that it scrolls rather than growing. Alerts change rarely,
            // so the box only resizes when something genuinely new needs looking at.
            if alerts.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle").foregroundStyle(.green)
                    Text(all.isEmpty ? "Nothing needs attention." : "All acknowledged.").foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(height: 24)
            } else {
                ScrollView(.vertical) {
                    VStack(spacing: 6) { ForEach(alerts) { a in row(a) } }
                }
                .frame(height: rowHeight * CGFloat(min(alerts.count, visibleRows)) + 6 * CGFloat(max(0, min(alerts.count, visibleRows) - 1)))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func row(_ a: BackupHQCore.Alert) -> some View {
        let colour: Color = a.severity == .critical ? .red : (a.severity == .warning ? .orange : .blue)
        return HStack(alignment: .center, spacing: 10) {
            Image(systemName: a.severity == .critical ? "exclamationmark.octagon.fill" : (a.severity == .warning ? "exclamationmark.triangle.fill" : "info.circle.fill"))
                .foregroundStyle(colour).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(a.title).bold().lineLimit(1)
                Text(a.detail).font(.caption).foregroundStyle(colour.mix(with: .primary, by: 0.5)).lineLimit(1).truncationMode(.tail)
            }
            .help(a.detail)
            Spacer(minLength: 8)
            Text("since \(a.firstSeen.formatted(.relative(presentation: .named)))").font(.caption2).foregroundStyle(.tertiary).lineLimit(1).frame(width: 120, alignment: .trailing)
            Group {
                if a.acknowledgedAt == nil { Button("Acknowledge") { Task { await model.acknowledge(a) } }.buttonStyle(.borderless).controlSize(.small) }
                else { Text("acknowledged").font(.caption2).foregroundStyle(.tertiary) }
            }
            .frame(width: 100, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .frame(height: rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(colour.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Folders

/// Everything you can set up lives here: the folders you look after, and the places copies can go.
struct FoldersView: View {
    @Environment(AppModel.self) private var model
    @State private var showAddS3 = false
    @State private var editing: Location?

    var body: some View {
        let targets = model.targetsAvailable
        let places = model.locations.filter { $0.kind != .adobe && $0.role != .source && $0.enabled && ($0.isTarget || $0.role == .library) }
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Button { model.trackFolder() } label: { Label("Add a folder to look after…", systemImage: "folder.badge.plus") }.buttonStyle(.borderedProminent)
                        Menu {
                            Button("Backup disk…") { model.addMirrorRoot() }
                            Button("S3 archive…") { showAddS3 = true }
                            Divider()
                            Button("Photo library folder…") { model.addLocalLocation(asPrimary: !model.locations.contains { $0.role == .library }) }
                        } label: { Label("Add a place for copies…", systemImage: "externaldrive.badge.plus") }
                        .frame(width: 220)
                        if let b = model.busy { ProgressView().controlSize(.small); Text(b).font(.caption).foregroundStyle(.secondary) }
                    }
                    NowPanel(compact: true)

                    if model.owners.isEmpty {
                        SectionBox(title: "No folders yet") {
                            Text("Pick any folder on this Mac or on a disk. For each one, tick where a copy should also live. Nothing is copied anywhere you did not tick, and nothing in the folder is ever moved or deleted.").foregroundStyle(.secondary)
                        }
                    }
                    ForEach(model.owners) { loc in
                        FolderCard(location: loc, coverage: model.coverage(for: loc), targets: targets, highlighted: model.coverageSelection == loc.id, onEdit: { editing = loc })
                            .id(loc.id)
                    }

                    SectionBox(title: "Places copies can go", subtitle: places.isEmpty ? "Add a backup disk or an S3 archive, then tick it on a folder above." : "Tick these on a folder above. A disk is recognised wherever you plug it in.") {
                        ForEach(places) { loc in
                            let p = model.stats.places.first { $0.locationId == loc.id }
                            HStack(spacing: 12) {
                                Image(systemName: loc.icon).frame(width: 22).foregroundStyle(loc.isReachable ? Color.accentColor : .secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack { Text(loc.name).bold(); if !loc.isReachable { Pill(text: "not plugged in", color: .secondary) } }
                                    Text(loc.kind == .s3 ? s3Line(loc, p) : loc.summaryLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        .help(loc.kind == .s3 ? s3Help(loc, p) : "")
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(Format.bytes(p?.verifiedBytes ?? 0) + " held").font(.caption)
                                    if let free = p?.freeBytes { Text("\(Format.bytes(free)) free").font(.caption2).foregroundStyle(.secondary) }
                                }
                                Menu {
                                    Button("Rename…") { editing = loc }
                                    Button("Check every copy here") { Task { await model.verify(loc) } }
                                    if let url = loc.reachableRootURL { Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
                                    Divider()
                                    Button("Forget this place (keeps the files)", role: .destructive) { Task { await model.remove(loc) } }
                                } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).frame(width: 30)
                            }
                            .padding(.vertical, 4)
                        }
                    }

                    let sources = model.locations.filter { $0.role == .source }
                    if !sources.isEmpty {
                        SectionBox(title: "Lightroom hand-off folder", subtitle: "Lightroom downloads originals here; the app moves them on into the photo library. Not a place of its own.") {
                            ForEach(sources) { loc in
                                let st = model.stats.perLocation.first { $0.id == loc.id }
                                HStack(spacing: 12) {
                                    Image(systemName: "tray.and.arrow.down").frame(width: 22).foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(loc.name).bold()
                                        Text(loc.rootPath ?? "").font(.caption2.monospaced()).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                                    }
                                    Spacer()
                                    Text("\(Format.count(st?.verifiedCount ?? 0)) files seen").font(.caption).foregroundStyle(.secondary)
                                    Button("Ingest now") { Task { await model.scan(loc) } }.controlSize(.small)
                                    Menu {
                                        if let url = loc.reachableRootURL { Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
                                        Button("Forget this folder", role: .destructive) { Task { await model.remove(loc) } }
                                    } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).frame(width: 30)
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }
                }
                .padding(20)
            }
            .onAppear { if let id = model.coverageSelection { proxy.scrollTo(id, anchor: .top) } }
            .onChange(of: model.coverageSelection) { _, id in if let id { withAnimation { proxy.scrollTo(id, anchor: .top) } } }
        }
        .sheet(isPresented: $showAddS3) { AddS3Sheet() }
        .sheet(item: $editing) { loc in EditLocationSheet(location: loc) }
        .alert("Move the copies already in S3 too?", isPresented: Binding(get: { model.reclassPrompt != nil }, set: { if !$0 { model.reclassPrompt = nil } }), presenting: model.reclassPrompt) { p in
            Button("Move them too") { Task { await model.reclassExistingCopies(p); model.reclassPrompt = nil } }
            Button("New uploads only", role: .cancel) { model.reclassPrompt = nil }
        } message: { p in
            Text("\(Format.count(p.count)) copies (\(Format.bytes(p.bytes))) of \(p.folder.name) are in \(p.target.name) with a different storage class. "
                 + (p.fromArchive ? "Moving them means asking S3 to restore each one first, which takes hours and costs a little per gigabyte; objects under 180 days old in Deep Archive also pay the rest of their minimum. " : "")
                 + "New uploads use \(p.storageClass.displayName) either way.")
        }
    }

    /// "s3://bucket/ · eu-west-1 · 811 MB Standard, 4 MB Deep Archive · about $0.02 a month"
    private func s3Line(_ loc: Location, _ p: PlaceSummary?) -> String {
        var parts = ["s3://\(loc.s3Bucket ?? "?")/\(loc.s3Prefix ?? "")", loc.s3Region ?? ""]
        let usage = (p?.byClass ?? [:]).sorted { $0.value.bytes > $1.value.bytes }
        if usage.isEmpty {
            parts.append("new uploads go to \(S3StorageClass(rawValue: loc.s3StorageClass ?? "")?.plainName ?? loc.s3StorageClass ?? "Standard") unless a folder chooses otherwise")
        } else {
            parts.append(usage.map { "\(Format.bytes($0.value.bytes)) \(S3StorageClass(rawValue: $0.key)?.plainName ?? $0.key)" }.joined(separator: ", "))
            let usd = p?.monthlyUSD ?? 0
            parts.append(usd < 0.005 ? "under a cent a month" : "about $\(String(format: "%.2f", usd)) a month")
        }
        return parts.joined(separator: " · ")
    }

    private func s3Help(_ loc: Location, _ p: PlaceSummary?) -> String {
        var lines = ["Estimated storage cost at eu-west-1 list prices, per storage class actually used:"]
        for (cls, u) in (p?.byClass ?? [:]).sorted(by: { $0.value.bytes > $1.value.bytes }) {
            let c = S3StorageClass(rawValue: cls) ?? .standard
            lines.append("  \(c.plainName): \(Format.count(u.count)) objects, \(Format.bytes(u.bytes)) → $\(String(format: "%.3f", c.monthlyUSD(count: u.count, bytes: u.bytes)))/month")
        }
        lines.append("Default class for new uploads: \(S3StorageClass(rawValue: loc.s3StorageClass ?? "")?.plainName ?? "Standard"); each folder can pick its own on its card.")
        lines.append("Not included: requests, retrievals, and the 90/180-day minimums Glacier classes charge when objects are deleted early.")
        return lines.joined(separator: "\n")
    }
}

/// One folder: what it is, where it should also be (tick boxes), and how far along each copy is.
struct FolderCard: View {
    @Environment(AppModel.self) private var model
    var location: Location
    var coverage: FolderCoverage?
    var targets: [Location]
    var highlighted = false
    var onEdit: () -> Void
    @State private var editingIgnores = false

    var body: some View {
        let f = coverage
        let others = targets.filter { $0.id != location.id }
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: location.icon).font(.title2).frame(width: 30).foregroundStyle((f?.reachable ?? true) ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(location.name).font(.headline)
                    if location.role == .library { Pill(text: "photo library") }
                    if let f, f.lastScanned != nil { Pill(text: f.safety.word, color: f.safety.color) }
                    else { ProgressView().controlSize(.mini); Text("looking through it…").font(.caption).foregroundStyle(.secondary) }
                }
                Text("\(Format.bytes(f?.bytes ?? 0)) · \(Format.count(f?.fileCount ?? 0)) files · on \(PlaceKind(rawValue: f?.place ?? "")?.label ?? location.placeKind.label)")
                    .font(.caption).foregroundStyle(.secondary)
                Text(location.rootPath ?? "").font(.caption2.monospaced()).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                if let f, let d = f.lastScanned {
                    Text("last looked through \(d.formatted(.relative(presentation: .named)))" + (model.settings.watchFolders && model.stats.engineRunning && (f.reachable) ? " · watching for changes" : ""))
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                if let f, !f.activity.isEmpty { FolderActivityView(coverage: f) }
                if let f, f.missingCount > 0 {
                    Label("\(Format.count(f.missingCount)) file\(f.missingCount == 1 ? "" : "s") deleted from this folder · the backup copies are kept", systemImage: "trash.slash")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .leading, spacing: 5) {
                Text("Also keep a copy on").font(.caption).foregroundStyle(.secondary)
                ForEach(others) { t in
                    let on = location.targets.contains(t.id)
                    let tc = f?.targets.first { $0.id == t.id }
                    HStack(spacing: 8) {
                        Toggle(isOn: Binding(get: { on }, set: { v in Task { await model.setTarget(t, on: location, enabled: v) } })) {
                            Label(t.name, systemImage: t.placeKind.icon).lineLimit(1)
                        }.toggleStyle(.checkbox)
                        if on && t.kind == .s3 {
                            Picker("", selection: Binding(get: { location.storageClass(for: t) }, set: { c in Task { await model.setStorageClass(t, on: location, storageClass: c) } })) {
                                ForEach(S3StorageClass.allCases, id: \.self) { Text($0.shortName).tag($0) }
                            }
                            .labelsHidden().controlSize(.small).fixedSize()
                            .help("Storage class for new uploads from this folder. Copies already in S3 keep the class they were written with.")
                        }
                        Spacer()
                        if on, let tc, let f {
                            let gap = f.bytes - tc.coveredBytes - tc.pendingBytes
                            if tc.coveredCount >= f.fileCount { Label("done", systemImage: "checkmark").foregroundStyle(.green).font(.caption) }
                            else if gap > 0 && (model.stats.engineRunning || f.lastScanned == nil) { Text("\(Format.bytes(gap)) to copy").font(.caption).foregroundStyle(.secondary) }
                            else if gap > 0 { Text("\(Format.bytes(gap)) waiting — press Start").foregroundStyle(.red).font(.caption) }
                            else { Text("\(Format.bytes(tc.pendingBytes)) on the way").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
                if others.isEmpty { Text("Add a backup disk or an S3 archive below.").font(.caption).foregroundStyle(.secondary) }
            }
            .frame(width: 390)
            Menu {
                Button("Look through it again") { Task { await model.scan(location) } }
                Button("Check its copies") { Task { await model.verify(location) } }
                Button("Rename…") { onEdit() }
                Button("Ignore rules…") { editingIgnores = true }
                if location.role == .library { Button("Import anything missing from the hand-off folder") { Task { await model.importMissingToPrimary() } } }
                if let url = location.reachableRootURL { Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
                Divider()
                Button("Stop looking after this folder (keeps every copy)", role: .destructive) { Task { await model.remove(location) } }
            } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).frame(width: 30)
        }
        .sheet(isPresented: $editingIgnores) { IgnoreRulesSheet(location: location) }
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor, lineWidth: 2).opacity(highlighted ? 1 : 0))
        .shadow(color: .black.opacity(0.06), radius: 6, x: 0, y: 3)
        .opacity((f?.reachable ?? true) ? 1 : 0.65)
    }
}


/// Per-folder ignore rules: the standard list from Settings can be switched off here, and the folder can add its own.
struct IgnoreRulesSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let location: Location
    @State private var useStandard = true
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ignore rules for \(location.name)").font(.title2).bold()
            Toggle("Use the standard ignore list from Settings (\(IgnoreRules(model.settings.ignoreRules).namePatterns.count + IgnoreRules(model.settings.ignoreRules).pathPatterns.count) rules)", isOn: $useStandard)
            Text("Extra rules for this folder, one per line").font(.callout)
            TextEditor(text: $text).font(.body.monospaced()).frame(minHeight: 160)
            Text("A name such as `node_modules` or `*.tmp` is skipped wherever it appears. A path such as `Exports/*` is relative to this folder. Files already copied elsewhere are kept; they just stop counting as part of this folder.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    let rules = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    Task { await model.setIgnoreRules(location, rules: rules, useStandard: useStandard); dismiss() }
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 520)
        .onAppear { useStandard = location.useStandardIgnores; text = location.ignoreRules.joined(separator: "\n") }
    }
}

import SwiftUI
import Charts
import BackupHQCore

struct RootView: View {
    @Environment(PhoneModel.self) private var model
    @State private var showSetup = false
    @Environment(\.scenePhase) private var phase

    var body: some View {
        NavigationStack {
            Group {
                if !model.configured { SetupPrompt(showSetup: $showSetup) }
                else if let s = model.stats { StatusView(stats: s) }
                else if let e = model.error { ErrorPrompt(message: e, showSetup: $showSetup) }
                else { ProgressView("Fetching status…") }
            }
            .navigationTitle("Backup HQ")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button { showSetup = true } label: { Image(systemName: "gearshape") } }
                ToolbarItem(placement: .topBarLeading) {
                    if model.loading { ProgressView() }
                    else if let t = model.lastFetched { Text(t.formatted(.relative(presentation: .named))).font(.caption).foregroundStyle(.secondary) }
                }
            }
            .refreshable { await model.refresh() }
            .sheet(isPresented: $showSetup) { SetupView() }
            .task { await model.refresh() }
            .onChange(of: phase) { _, p in if p == .active { Task { await model.refresh() } } }
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 30_000_000_000)
                    await model.refresh()
                }
            }
        }
    }
}

struct SetupPrompt: View {
    @Binding var showSetup: Bool
    var body: some View {
        ContentUnavailableView {
            Label("Connect to your Mac's status", systemImage: "icloud.and.arrow.down")
        } description: {
            Text("Enter the read-only key the Mac app set up. The phone only reads a small status file from your S3 bucket; it never touches your photos.")
        } actions: {
            Button("Set up") { showSetup = true }.buttonStyle(.borderedProminent)
        }
    }
}

struct ErrorPrompt: View {
    var message: String
    @Binding var showSetup: Bool
    @Environment(PhoneModel.self) private var model
    var body: some View {
        ContentUnavailableView {
            Label("Could not fetch status", systemImage: "exclamationmark.icloud")
        } description: { Text(message) } actions: {
            Button("Try again") { Task { await model.refresh() } }
            Button("Settings") { showSetup = true }
        }
    }
}

struct SetupView: View {
    @Environment(PhoneModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var s = PhoneModel.Settings()
    @State private var secret = ""
    var body: some View {
        NavigationStack {
            Form {
                Section("Bucket") {
                    TextField("Bucket", text: $s.bucket).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Region", text: $s.region).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Prefix (usually empty)", text: $s.prefix).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Section("Read-only key") {
                    TextField("Access key ID", text: $s.accessKeyId).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Secret access key", text: $secret)
                    Text("Use a read-only key that can only fetch _backuphq/status.json (see docs/iam-policy-phone.json).").font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { model.save(s, secret: secret); dismiss(); Task { await model.refresh() } } }
            }
            .onAppear { s = model.settings; secret = model.secret }
        }
    }
}

// MARK: - Status

struct StatusView: View {
    var stats: CatalogStats
    var body: some View {
        List {
            Section {
                EngineHeader(stats: stats)
            }
            if !stats.alerts.isEmpty {
                Section("Needs attention") {
                    ForEach(stats.alerts) { a in
                        Label {
                            VStack(alignment: .leading, spacing: 2) { Text(a.title).font(.subheadline).bold(); Text(a.detail).font(.caption).foregroundStyle(.secondary) }
                        } icon: {
                            Image(systemName: a.severity == .critical ? "exclamationmark.octagon.fill" : (a.severity == .warning ? "exclamationmark.triangle.fill" : "info.circle.fill"))
                                .foregroundStyle(a.severity == .critical ? .red : (a.severity == .warning ? .orange : .blue))
                        }
                    }
                }
            }
            Section("Adobe transfer") {
                ProgressLine(label: "Assets held locally or in S3", done: Double(stats.cloudMatchedLocallyCount), total: Double(stats.cloudAssetCount), text: "\(fmt(stats.cloudMatchedLocallyCount)) of \(fmt(stats.cloudAssetCount))")
                ProgressLine(label: "Bytes", done: Double(stats.cloudMatchedLocallyBytes), total: Double(stats.cloudAssetBytes), text: "\(Format.bytes(stats.cloudMatchedLocallyBytes)) of \(Format.bytes(stats.cloudAssetBytes))")
                if stats.cloudOnlyCount > 0 { LabeledContent("Still only in Adobe", value: "\(fmt(stats.cloudOnlyCount)) · \(Format.bytes(stats.cloudOnlyBytes))") }
            }
            Section("Folders") {
                ForEach(stats.folders) { f in FolderRow(folder: f) }
            }
            Section("Places") {
                ForEach(stats.places) { p in
                    HStack {
                        Image(systemName: p.place == "s3" ? "icloud" : (p.place == "mac" ? "laptopcomputer" : "externaldrive")).foregroundStyle(p.reachable ? Color.accentColor : .secondary)
                        VStack(alignment: .leading) { Text(p.name); Text("\(Format.bytes(p.verifiedBytes)) · \(fmt(p.verifiedCount)) files" + (p.freeBytes.map { " · \(Format.bytes($0)) free" } ?? "")).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        if !p.reachable { Text("offline").font(.caption).foregroundStyle(.red) }
                    }
                }
            }
            if stats.history.count > 1 {
                Section("Protected over time") {
                    Chart(stats.history) { h in
                        AreaMark(x: .value("Time", h.time), y: .value("GB", Double(h.protectedBytes) / 1e9), series: .value("Series", "Protected")).foregroundStyle(.green.opacity(0.25))
                        LineMark(x: .value("Time", h.time), y: .value("GB", Double(h.protectedBytes) / 1e9), series: .value("Series", "Protected")).foregroundStyle(.green)
                    }
                    .frame(height: 140)
                }
            }
            Section {
                Text("Updated by the Mac \(stats.generatedAt.formatted(.relative(presentation: .named))).").font(.caption).foregroundStyle(.secondary)
            }
        }
        .listStyle(.insetGrouped)
    }
    private func fmt(_ n: Int) -> String { Format.count(n) }
}

struct EngineHeader: View {
    var stats: CatalogStats
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(stats.engineRunning ? Color.green : (stats.jobsPending > 0 ? Color.orange : Color.secondary)).frame(width: 10, height: 10)
                Text(stats.engineRunning ? "Working" : (stats.jobsPending > 0 ? "Paused — \(Format.count(stats.jobsPending)) waiting" : "Idle")).font(.headline)
                Spacer()
                if stats.engineRunning { Text("\(Format.bytes(Int64(stats.throughputBytesPerSecond)))/s").font(.subheadline).monospacedDigit().foregroundStyle(.secondary) }
            }
            HStack(spacing: 12) {
                Tile(title: "Below policy", value: Format.bytes(stats.vulnerableBytes), tint: stats.vulnerableBytes > 0 ? .red : .green)
                Tile(title: "Queued", value: Format.bytes(stats.bytesPendingUpload + stats.bytesPendingBackup + stats.bytesPendingImport), tint: .primary)
                Tile(title: "Failed", value: "\(stats.jobsFailed)", tint: stats.jobsFailed > 0 ? .red : .green)
            }
        }
        .padding(.vertical, 4)
    }
}

struct Tile: View {
    var title: String; var value: String; var tint: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.title3).bold().foregroundStyle(tint).lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct ProgressLine: View {
    var label: String; var done: Double; var total: Double; var text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack { Text(label).font(.subheadline); Spacer(); Text(text).font(.caption).monospacedDigit().foregroundStyle(.secondary) }
            ProgressView(value: total > 0 ? min(1, done / total) : 0)
        }
    }
}

struct FolderRow: View {
    var folder: FolderCoverage
    var body: some View {
        let complete = folder.vulnerableCount == 0
        let queued = folder.targets.reduce(0) { $0 + $1.pendingBytes }
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(folder.name).bold()
                Spacer()
                if folder.targets.isEmpty { Text("single copy").font(.caption).foregroundStyle(.secondary) }
                else if !folder.reachable { Text("offline").font(.caption).foregroundStyle(.secondary) }
                else if complete { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                else if queued > 0 { Text("\(Format.bytes(queued)) queued").font(.caption).foregroundStyle(.orange) }
                else { Text("\(Format.bytes(folder.vulnerableBytes)) missing").font(.caption).foregroundStyle(.red) }
            }
            Text("\(Format.bytes(folder.bytes)) · \(Format.count(folder.fileCount)) files" + (folder.targets.isEmpty ? "" : " → " + folder.targets.map { t in "\(t.name) \(folder.fileCount > 0 ? Int(Double(t.coveredCount) / Double(folder.fileCount) * 100) : 100)%" }.joined(separator: ", ")))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

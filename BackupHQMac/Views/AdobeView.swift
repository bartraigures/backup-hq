import SwiftUI
import BackupHQCore

/// The Adobe page: what Lightroom's catalog says the cloud holds, how to get Lightroom to download it, and how far along we are.
struct AdobeView: View {
    @Environment(AppModel.self) private var model
    @State private var missing: [CloudAsset] = []
    @State private var showNeverUploadedOnly = false

    var body: some View {
        let d = model.lightroom
        let s = model.stats
        VStack(alignment: .leading, spacing: 16) {
                SectionBox(title: "Lightroom catalog on this Mac", subtitle: "Lightroom keeps a full copy of the cloud catalog locally. Backup HQ reads it (read-only) as the list of what must be rescued.") {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                        GridRow { Text("Catalog").foregroundStyle(.secondary); Text(d.catalogURL?.path ?? "Not found").textSelection(.enabled).lineLimit(1).truncationMode(.middle) }
                        GridRow { Text("Assets in cloud").foregroundStyle(.secondary); Text("\(Format.count(s.cloudAssetCount)) · \(Format.bytes(s.cloudAssetBytes))") }
                        GridRow { Text("Never uploaded").foregroundStyle(.secondary); Text("\(Format.count(s.cloudNeverUploadedCount)) · \(Format.bytes(s.cloudNeverUploadedBytes))").foregroundStyle(s.cloudNeverUploadedCount > 0 ? .orange : .primary) }
                        GridRow { Text("Lightroom running").foregroundStyle(.secondary); Text(d.lightroomRunning ? "Yes" : "No") }
                    }
                    HStack {
                        Button(model.syncing ? "Syncing… \(Format.count(model.syncProgress))" : "Sync catalog now") { Task { await model.syncLightroom() } }
                            .disabled(model.syncing || d.catalogURL == nil)
                        Button("Re-detect") { model.rediscoverLightroom() }
                    }
                }

                SectionBox(title: "Getting the originals out", subtitle: "Adobe does not offer a public download API, so Lightroom itself does the downloading.") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("1. In Lightroom choose **Lightroom › Preferences › Local Storage** and turn on **Store a copy of all originals at the specified location**. Browse to a drive with at least \(Format.bytes(s.cloudAssetBytes)) free. Lightroom then downloads every original into that folder, in date-named subfolders.")
                        Text("2. Leave Lightroom running. Backup HQ watches the folder below, checks each file's SHA-256 against the catalog, and copies it into your library and on to S3. Press **Ingest now** whenever you like; it only picks up new files.")
                        Text("3. When *Still only in Adobe* reaches zero above, everything is home. You can then turn the Lightroom setting off again and reclaim the space.")
                    }
                    .font(.callout)
                    Divider()
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                        GridRow { Text("Store copies locally").foregroundStyle(.secondary); Text(d.keepAllOriginals.map { $0 ? "ON" : "OFF" } ?? "unknown").bold().foregroundStyle(d.keepAllOriginals == true ? .green : .orange) }
                        GridRow { Text("Originals folder").foregroundStyle(.secondary); Text(d.originalsStoreURL?.path ?? "unknown").textSelection(.enabled).lineLimit(1).truncationMode(.middle) }
                        GridRow {
                            Text("Downloaded so far").foregroundStyle(.secondary)
                            if let n = model.lightroomStoreFileCount { Text("\(Format.count(n)) files · \(Format.bytes(model.lightroomStoreBytes ?? 0))") } else { Text("—") }
                        }
                    }
                    HStack {
                        Button("Ingest now") { Task { await model.ingestLightroomStore() } }.disabled(d.originalsStoreURL == nil)
                        Button("Recount folder") { Task { await model.scanLightroomStore() } }
                        if let url = d.originalsStoreURL { Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
                    }
                }

                SectionBox(title: "Still only in Adobe", subtitle: "Live assets with no verified copy on any disk or in S3 (newest first, first 500).") {
                    Toggle("Show only the never-uploaded ones", isOn: $showNeverUploadedOnly).onChange(of: showNeverUploadedOnly) { _, _ in Task { await load() } }
                    Table(missing) {
                        TableColumn("Captured") { Text($0.captureDate?.prefix(19).replacingOccurrences(of: "T", with: " ") ?? "—").monospacedDigit() }.width(150)
                        TableColumn("File") { Text($0.fileName) }
                        TableColumn("Size") { Text(Format.bytes($0.fileSize)).monospacedDigit() }.width(80)
                        TableColumn("Type") { Text($0.subtype) }.width(50)
                        TableColumn("Note") { a in if a.willNotUploadMaster { Text("never uploaded").foregroundStyle(.orange) } }
                    }
                    .frame(minHeight: 300)
                }
        }
        .task { await load() }
        .onChange(of: model.stats.cloudOnlyCount) { _, _ in Task { await load() } }
    }

    private func load() async {
        guard let db = model.db else { return }
        missing = (try? await db.cloudAssetsMissingLocally(limit: 500, neverUploadedOnly: showNeverUploadedOnly)) ?? []
    }
}

import SwiftUI
import BackupHQCore

/// True duplicates only: byte-identical content that Lightroom holds under more than one asset.
struct DuplicatesView: View {
    @Environment(AppModel.self) private var model
    @State private var groups: [Database.DuplicateGroup] = []
    @State private var selected: Database.DuplicateGroup.ID?

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                Text("\(groups.count) groups of byte-identical files · \(Format.bytes(groups.reduce(0) { $0 + $1.size * Int64($1.names.count - 1) })) reclaimable in Lightroom")
                    .font(.callout).foregroundStyle(.secondary).padding(10)
                Table(groups, selection: $selected) {
                    TableColumn("Captured") { Text($0.captureDate?.prefix(10) ?? "—").monospacedDigit() }.width(90)
                    TableColumn("Names") { Text($0.names.joined(separator: "  =  ")) }
                    TableColumn("Copies") { Text("\($0.names.count)").monospacedDigit() }.width(50)
                    TableColumn("Size") { Text(Format.bytes($0.size)).monospacedDigit() }.width(80)
                }
            }
            .frame(minWidth: 480)
            if let id = selected, let g = groups.first(where: { $0.id == id }) {
                ContentDetailView(sha256: g.sha256).frame(minWidth: 300)
            } else {
                Text("Select a group to see where the file lives.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { groups = (try? await model.db?.duplicateGroups()) ?? [] }
    }
}

/// Everything known about one piece of content: its Lightroom records, every copy, and a thumbnail.
struct ContentDetailView: View {
    @Environment(AppModel.self) private var model
    var sha256: String
    @State private var content: Content?
    @State private var assets: [CloudAsset] = []
    @State private var copies: [Copy] = []
    @State private var thumbnail: NSImage?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let thumbnail {
                    Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fit).frame(maxHeight: 260).clipShape(RoundedRectangle(cornerRadius: 8))
                }
                if let c = content {
                    Text(c.displayName).font(.title3).bold()
                    Text("\(Format.bytes(c.size)) · \(c.captureDate ?? "undated") · \(c.contentType ?? c.kind.rawValue)").font(.caption).foregroundStyle(.secondary)
                    Text(c.sha256).font(.caption2).monospaced().foregroundStyle(.tertiary).textSelection(.enabled)
                }
                let places = copies.filter { $0.status == .verified }.count + (assets.contains { !$0.deleted && !$0.willNotUploadMaster } ? 1 : 0)
                Label(places >= 2 ? "Safe: in \(places) places" : (places == 1 ? "Vulnerable: only in one place" : "Not held anywhere yet"), systemImage: places >= 2 ? "checkmark.shield.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(places >= 2 ? .green : .red).bold()
                SectionBox(title: "Copies") {
                    if copies.isEmpty { Text("None recorded.").foregroundStyle(.secondary) }
                    ForEach(copies) { c in
                        HStack(alignment: .top) {
                            Circle().fill(c.status.color).frame(width: 8, height: 8).padding(.top, 5)
                            VStack(alignment: .leading) {
                                Text(model.locations.first { $0.id == c.locationId }?.name ?? "Location \(c.locationId)").bold()
                                Text(c.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                Text("\(c.status.rawValue)\(c.verifiedAt.map { " · checked \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "")\(c.storageClass.map { " · \($0)" } ?? "")").font(.caption2).foregroundStyle(.tertiary)
                            }
                            Spacer()
                            if let loc = model.locations.first(where: { $0.id == c.locationId }), let root = loc.rootURL {
                                Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([root.appendingPathComponent(c.path)]) }.controlSize(.small)
                            }
                        }
                    }
                }
                SectionBox(title: "In Lightroom") {
                    if assets.isEmpty { Text("Not in the Lightroom catalog.").foregroundStyle(.secondary) }
                    ForEach(assets) { a in
                        VStack(alignment: .leading) {
                            HStack {
                                Text(a.fileName).bold()
                                if a.deleted { Text("deleted").foregroundStyle(.red).font(.caption) }
                                if a.willNotUploadMaster { Text("original never uploaded").foregroundStyle(.orange).font(.caption) }
                                if let r = a.rating, r > 0 { Text(String(repeating: "★", count: r)).font(.caption) }
                            }
                            Text("asset \(a.assetId) · imported \(a.userCreated?.prefix(10) ?? "?")").font(.caption2).foregroundStyle(.tertiary).textSelection(.enabled)
                        }
                    }
                }
            }
            .padding(16)
        }
        .task(id: sha256) { await load() }
    }

    private func load() async {
        guard let db = model.db else { return }
        content = try? await db.content(sha256: sha256)
        assets = (try? await db.cloudAssets(sha256: sha256)) ?? []
        copies = (try? await db.copies(sha256: sha256)) ?? []
        thumbnail = nil
        if let files = try? await db.localFileURLs(sha256: sha256), let url = files.first(where: { FileManager.default.fileExists(atPath: $0.1.path) })?.1 {
            thumbnail = await Thumbnails.shared.thumbnail(for: url, size: 512)
        }
    }
}

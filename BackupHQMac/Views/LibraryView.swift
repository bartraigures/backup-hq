import SwiftUI
import BackupHQCore

/// Browse the catalogue: years → days → thumbnails, each badged with where it lives.
struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var years: [Database.DayBucket] = []
    @State private var days: [Database.DayBucket] = []
    @State private var selectedYear: String?
    @State private var selectedDay: String?
    @State private var items: [Content] = []
    @State private var selectedItem: Content.ID?
    @State private var search = ""

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $selectedYear) {
                    Section("Years") {
                        ForEach(years) { y in
                            HStack { Text(y.day); Spacer(); Text(Format.count(y.count)).foregroundStyle(.secondary).monospacedDigit() }.tag(y.day)
                        }
                    }
                }
                .frame(minHeight: 160)
                Divider()
                List(selection: $selectedDay) {
                    Section(selectedYear.map { "Days in \($0)" } ?? "Days") {
                        ForEach(days) { d in
                            HStack { Text(d.day); Spacer(); Text("\(d.count)").foregroundStyle(.secondary).monospacedDigit() }.tag(d.day)
                        }
                    }
                }
            }
            .frame(minWidth: 180, idealWidth: 200, maxWidth: 260)

            VStack(spacing: 0) {
                HStack {
                    TextField("Search file names", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 300)
                    Spacer()
                    Text("\(Format.count(items.count)) shown").foregroundStyle(.secondary).font(.caption)
                }.padding(10)
                if items.isEmpty {
                    ContentUnavailableView(model.stats.contentCount == 0 ? "Nothing catalogued yet" : "No photos here", systemImage: "photo.on.rectangle.angled",
                                           description: Text(model.stats.contentCount == 0 ? "Once files are ingested from Lightroom's folder or scanned from a disk they appear here." : "Pick another day or clear the search."))
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                            ForEach(items) { c in
                                ThumbCell(content: c, selected: selectedItem == c.id)
                                    .onTapGesture { selectedItem = c.id }
                            }
                        }.padding(10)
                    }
                }
            }
            .frame(minWidth: 400)

            if let id = selectedItem {
                ContentDetailView(sha256: id).frame(minWidth: 300, idealWidth: 340)
            }
        }
        .task { await loadYears() }
        .onChange(of: selectedYear) { _, _ in Task { await loadDays(); await loadItems() } }
        .onChange(of: selectedDay) { _, _ in Task { await loadItems() } }
        .onChange(of: search) { _, _ in Task { await loadItems() } }
        .onChange(of: model.stats.contentCount) { _, _ in Task { await loadYears(); await loadDays(); await loadItems() } }
    }

    private func loadYears() async { years = (try? await model.db?.contentYears()) ?? [] }
    private func loadDays() async {
        guard let y = selectedYear, y != "unknown" else { days = []; return }
        days = (try? await model.db?.contentDays(year: y)) ?? []
    }
    private func loadItems() async {
        guard let db = model.db else { return }
        if !search.isEmpty { items = (try? await db.contentList(search: search, limit: 600)) ?? []; return }
        if let d = selectedDay { items = (try? await db.contentList(day: d, limit: 2000)) ?? [] }
        else if let y = selectedYear, y != "unknown" { items = (try? await db.contentList(year: y, limit: 600)) ?? [] }
        else { items = (try? await db.contentList(limit: 300)) ?? [] }
    }
}

struct ThumbCell: View {
    @Environment(AppModel.self) private var model
    var content: Content
    var selected: Bool
    @State private var image: NSImage?
    @State private var places: (local: Int, s3: Int, adobe: Bool) = (0, 0, false)

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                if let image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fill) }
                else { Image(systemName: content.kind == .video ? "video" : "photo").font(.title).foregroundStyle(.secondary) }
            }
            .frame(height: 120).clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(alignment: .bottomTrailing) {
                HStack(spacing: 3) {
                    if places.adobe { Image(systemName: "cloud.fill") }
                    ForEach(0..<places.local, id: \.self) { _ in Image(systemName: "externaldrive.fill") }
                    ForEach(0..<places.s3, id: \.self) { _ in Image(systemName: "icloud.fill") }
                }
                .font(.caption2).padding(4).background(.black.opacity(0.55), in: Capsule()).foregroundStyle(.white).padding(4)
            }
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 3))
            Text(content.displayName).font(.caption).lineLimit(1)
            HStack {
                Text(Format.bytes(content.size)).font(.caption2).foregroundStyle(.secondary)
                Spacer()
                let total = places.local + places.s3 + (places.adobe ? 1 : 0)
                Circle().fill(total >= 2 ? Color.green : (total == 1 ? .orange : .red)).frame(width: 7, height: 7)
            }
        }
        .task(id: content.id) {
            guard let db = model.db else { return }
            let copies = (try? await db.copies(sha256: content.sha256)) ?? []
            let locs = model.locations
            var local = Set<Int64>(), s3 = Set<Int64>()
            for c in copies where c.status == .verified {
                if let l = locs.first(where: { $0.id == c.locationId }) { if l.kind == .local { local.insert(l.id) } else if l.kind == .s3 { s3.insert(l.id) } }
            }
            let assets = (try? await db.cloudAssets(sha256: content.sha256)) ?? []
            places = (local.count, s3.count, assets.contains { !$0.deleted && !$0.willNotUploadMaster })
            if let url = (try? await db.localFileURLs(sha256: content.sha256))?.first(where: { FileManager.default.fileExists(atPath: $0.1.path) })?.1 {
                image = await Thumbnails.shared.thumbnail(for: url, size: 300)
            }
        }
    }
}

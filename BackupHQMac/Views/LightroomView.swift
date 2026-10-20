import SwiftUI
import BackupHQCore

/// Everything about the photos themselves: the rescue from Adobe, browsing what is home, and true duplicates.
struct LightroomView: View {
    @Environment(AppModel.self) private var model
    @State private var tab: Tab = .rescue
    enum Tab: String, CaseIterable { case rescue = "Rescue from Adobe", photos = "Photos", duplicates = "Duplicates" }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) { ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden().frame(width: 420).padding(.vertical, 10)
            Divider()
            switch tab {
            case .rescue: RescueView()
            case .photos: LibraryView()
            case .duplicates: DuplicatesView()
            }
        }
    }
}

/// How far the one-off transfer out of Adobe has got, and what to do next.
struct RescueView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let s = model.stats
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    let done = s.cloudAssetCount > 0 && s.cloudOnlyCount == 0
                    Image(systemName: done ? "checkmark.shield.fill" : "cloud.fill").font(.system(size: 34)).foregroundStyle(done ? .green : .orange)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(done ? "Every photo is home" : "\(Format.count(s.cloudOnlyCount)) photos are still only in Adobe").font(.title2).bold()
                        Text("\(Format.count(s.cloudMatchedLocallyCount)) of \(Format.count(s.cloudAssetCount)) assets (\(Format.bytes(s.cloudMatchedLocallyBytes)) of \(Format.bytes(s.cloudAssetBytes))) are on a disk here or in S3.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background((s.cloudOnlyCount == 0 ? Color.green : Color.orange).opacity(0.08), in: RoundedRectangle(cornerRadius: 12))

                ProgressRow(label: "Bytes rescued", done: s.cloudMatchedLocallyBytes, total: s.cloudAssetBytes)
                if s.cloudNeverUploadedCount > 0 {
                    Label("\(Format.count(s.cloudNeverUploadedCount)) assets (\(Format.bytes(s.cloudNeverUploadedBytes))) were never uploaded to Adobe as originals, so Adobe only has previews. Their originals must come from wherever they were first imported.", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.orange)
                }
                AdobeView()
            }
            .padding(20)
        }
    }
}

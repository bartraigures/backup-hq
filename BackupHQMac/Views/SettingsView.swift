import SwiftUI
import BackupHQCore

/// Four things most people will ever touch; everything else is under Advanced with sensible defaults.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var advanced = false

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Toggle("Open Backup HQ when you log in", isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
                Toggle("Start copying as soon as the app opens", isOn: $model.settings.startEngineAtLaunch)
                Toggle("Quietly re-check old copies and repair any that went bad", isOn: Binding(get: { model.settings.backgroundMaintenance }, set: { model.settings.backgroundMaintenance = $0; model.settings.selfHeal = $0 }))
                Toggle("Notify me when something needs attention", isOn: $model.settings.notifications)
                Toggle("Work with Adobe Lightroom", isOn: $model.settings.lightroomEnabled)
                Text("Reads Lightroom's local catalogue (never changes it) and adds a Lightroom page that shows which originals are safely on a disk you look after.").font(.caption).foregroundStyle(.secondary)
            } footer: {
                Text("Closing the window does not quit the app; the shield in the menu bar shows what it is doing.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Noticing changes") {
                Toggle("Notice changes in folders as they happen", isOn: $model.settings.watchFolders)
                Picker("After a change, wait for the folder to go quiet for", selection: $model.settings.settleSeconds) {
                    Text("30 seconds").tag(30); Text("2 minutes").tag(120); Text("5 minutes").tag(300); Text("15 minutes").tag(900)
                }
                Picker("Look through every folder again", selection: $model.settings.scanEveryMinutes) {
                    Text("every 15 minutes").tag(15); Text("every 30 minutes").tag(30); Text("every hour").tag(60)
                    Text("every 6 hours").tag(360); Text("once a day").tag(1440); Text("only when I ask").tag(0)
                }
                Text("Waiting lets a burst of saves become one copy instead of many; a folder that never goes quiet is still looked at every 15 minutes. A look only visits the parts of a folder that changed since last time, so it is quick. The whole folder is walked when you press \"Look through it again\".").font(.caption).foregroundStyle(.secondary)
            }
            Section("Ignored everywhere") {
                TextEditor(text: Binding(get: { model.settings.ignoreRules.joined(separator: "\n") },
                                         set: { model.settings.ignoreRules = $0.components(separatedBy: "\n") }))
                    .font(.callout.monospaced()).frame(height: 150)
                HStack {
                    Text("One per line. A name like `node_modules` or `*.tmp` is skipped at any depth; a path like `Exports/*` is relative to each folder. Lines starting with # are notes. Each folder can add its own rules or opt out of this list from its menu.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset to standard") { model.settings.ignoreRules = IgnoreRules.standard }.controlSize(.small)
                }
            }
            Section("Phone") {
                Toggle("Let the Backup HQ phone app see progress", isOn: $model.settings.publishStatusToS3)
                Text("Writes a small status file into your S3 archive every \(model.settings.statusPublishIntervalSeconds) seconds. Nothing else leaves this Mac.").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                DisclosureGroup("Advanced", isExpanded: $advanced) {
                    Stepper("Files fingerprinted at once: \(model.settings.hashWorkers)", value: $model.settings.hashWorkers, in: 1...8)
                    Stepper("Files copied at once: \(model.settings.importWorkers)", value: $model.settings.importWorkers, in: 1...4)
                    Stepper("Files uploaded at once: \(model.settings.uploadWorkers)", value: $model.settings.uploadWorkers, in: 1...8)
                    Stepper("Re-check disk copies every \(model.settings.verifyLocalEveryDays) days", value: $model.settings.verifyLocalEveryDays, in: 7...365, step: 7)
                    Stepper("Re-check S3 copies every \(model.settings.verifyS3EveryDays) days", value: $model.settings.verifyS3EveryDays, in: 7...365, step: 7)
                    Picker("Warn when a folder has this much not yet copied", selection: $model.settings.alertVulnerableThresholdBytes) {
                        Text("anything").tag(Int64(1)); Text("10 MB").tag(Int64(10_000_000)); Text("100 MB").tag(Int64(100_000_000)); Text("1 GB").tag(Int64(1_000_000_000)); Text("10 GB").tag(Int64(10_000_000_000))
                    }
                    Stepper("Warn when a disk has not been seen for \(model.settings.alertDiskUnseenDays) days", value: $model.settings.alertDiskUnseenDays, in: 1...180)
                    Stepper("Warn when a disk has less than \(model.settings.alertFreeSpacePercent)% free", value: $model.settings.alertFreeSpacePercent, in: 1...50)
                    Toggle("Move instead of copy when the hand-off folder is on the library's own disk", isOn: $model.settings.moveWhenSameVolume)
                    Toggle("Look through every folder when the app opens", isOn: $model.settings.scanAtLaunch)
                    Toggle("Look through a disk's folders as soon as it is plugged in", isOn: $model.settings.scanOnMount)
                    LabeledContent("Catalogue file") {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Database.defaultURL()]) }.controlSize(.small)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: advanced ? 1040 : 800)
        .onChange(of: model.settings) { _, _ in Task { await model.saveSettings() } }
    }
}

import SwiftUI
import BackupHQCore

@main
struct BackupHQMacApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Backup HQ", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 1000, minHeight: 640)
                .task { await model.bootstrap() }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button(model.stats.engineRunning ? "Pause Engine" : "Start Engine") { Task { await model.toggleEngine() } }
                    .keyboardShortcut("r", modifiers: [.command])
                if model.settings.lightroomEnabled {
                    Button("Sync Lightroom Catalog") { Task { await model.syncLightroom() } }
                        .keyboardShortcut("l", modifiers: [.command, .shift])
                }
            }
        }
        Settings {
            SettingsView().environment(model)
        }
        // Lives in the menu bar so the engine keeps working with the window closed.
        MenuBarExtra {
            MenuBarContent().environment(model)
        } label: {
            let s = model.stats
            let critical = s.alerts.contains { $0.severity == .critical && $0.acknowledgedAt == nil }
            Image(systemName: critical ? "exclamationmark.shield.fill" : (s.engineRunning ? "arrow.triangle.2.circlepath.circle.fill" : "checkmark.shield"))
        }
    }
}

struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        let s = model.stats
        Text(s.engineRunning ? "Working — \(Format.bytes(Int64(s.throughputBytesPerSecond)))/s, \(s.jobsRunning) running, \(Format.count(s.jobsPending)) waiting" : (s.jobsPending > 0 ? "Paused — \(Format.count(s.jobsPending)) waiting" : "Idle — everything is as you asked"))
        if s.vulnerableBytes > 0 { Text("\(Format.bytes(s.vulnerableBytes)) below policy") }
        ForEach(s.alerts.filter { $0.acknowledgedAt == nil }.prefix(4)) { a in Text("\(a.severity == .critical ? "‼" : "⚠") \(a.title)") }
        Divider()
        Button(s.engineRunning ? "Pause" : "Start") { Task { await model.toggleEngine() } }
        Button("Back up everything now") { Task { await model.backUpEverything() } }
        Button("Check now") { Task { await model.runMaintenanceNow() } }
        Divider()
        Button("Open Backup HQ") { NSApp.activate(ignoringOtherApps: true); openWindow(id: "main") }
        Button("Quit") { NSApp.terminate(nil) }
    }
}

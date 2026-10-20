import Foundation
import UserNotifications
import ServiceManagement
import BackupHQCore

/// Turns new alerts into macOS notifications, once each, and manages launch-at-login.
@MainActor
final class Notifier {
    private var notified: Set<String> = []
    private var authorised = false
    private var asked = false

    func requestAuthorisation() {
        guard !asked else { return }
        asked = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] ok, _ in
            Task { @MainActor in self?.authorised = ok }
        }
    }

    /// Notify about alerts not seen before in this session. Critical ones always; others only if enabled.
    func notify(alerts: [BackupHQCore.Alert], enabled: Bool) {
        let fresh = alerts.filter { !notified.contains($0.key) && $0.acknowledgedAt == nil }
        for a in fresh {
            notified.insert(a.key)
            guard enabled || a.severity == .critical, authorised else { continue }
            let content = UNMutableNotificationContent()
            content.title = a.severity == .critical ? "Backup HQ: attention needed" : "Backup HQ"
            content.subtitle = a.title
            content.body = a.detail
            content.sound = a.severity == .critical ? .defaultCritical : .default
            content.threadIdentifier = "alerts"
            let req = UNNotificationRequest(identifier: "alert-\(a.key)", content: content, trigger: nil)
            UNUserNotificationCenter.current().add(req)
        }
        // Resolved alerts can notify again if they come back later.
        let active = Set(alerts.map(\.key))
        notified = notified.intersection(active)
    }

    func setBadge(_ n: Int) {
        UNUserNotificationCenter.current().setBadgeCount(n)
    }

    // MARK: Launch at login

    var launchesAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    func setLaunchAtLogin(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}

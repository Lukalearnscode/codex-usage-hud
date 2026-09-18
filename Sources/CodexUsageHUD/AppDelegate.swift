import AppKit
import os

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger(subsystem: "com.local.CodexUsageHUD", category: "lifecycle")
    private let client = AppServerClient()
    private let tracker = CodexWindowTracker()
    private let controller = HUDPanelController()
    private let loginItemManager = LoginItemManager()
    private var refreshTimer: Timer?
    private var tickTimer: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []
    private let workspaceCenter = NSWorkspace.shared.notificationCenter

    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        loginItemManager.registerAtLogin()

        tracker.onFrameChanged = { [weak controller] frame in
            controller?.updateWindowFrame(frame)
        }
        client.onSnapshot = { [weak controller] snapshot in
            controller?.setSnapshot(snapshot)
        }
        client.onStatus = { [weak controller] status in
            controller?.setStatus(status)
        }
        controller.onNeedsRefresh = { [weak client] force in client?.refresh(force: force) }

        for name in [NSWorkspace.didWakeNotification, NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            workspaceObservers.append(workspaceCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.tracker.refresh()
                    self?.client.refresh()
                }
            })
        }
        workspaceObservers.append(workspaceCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.tracker.refresh()
                if app?.bundleIdentifier == "com.openai.codex" {
                    self.client.refresh()
                }
            }
        })
        workspaceObservers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tracker.refresh()
                self?.client.refresh()
            }
        })

        // 20s rather than the 60s this shipped with: a round trip costs 2 to 5
        // seconds and reads no quota of its own, and the panel's numbers were
        // up to a minute behind for no reason anyone could see. It also gives
        // the client's own 180s stale-rebuild check three chances to notice a
        // connection that has stopped producing snapshots.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            self?.client.refresh()
        }
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.controller.tick()
            }
        }
        client.start()
        tracker.start()
        logger.info("Codex Usage HUD started")
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
        tickTimer?.invalidate()
        for observer in workspaceObservers {
            workspaceCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        client.stop()
    }

}

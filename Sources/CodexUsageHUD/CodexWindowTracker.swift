import AppKit
import CoreGraphics
import CodexUsageHUDCore

final class CodexWindowTracker: @unchecked Sendable {
    private let bundleIdentifier = "com.openai.codex"
    private var timer: Timer?
    private var watchdogTimer: Timer?
    private var activationObserver: NSObjectProtocol?

    var onFrameChanged: ((CGRect?) -> Void)?

    init() {
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
    }

    deinit {
        timer?.invalidate()
        watchdogTimer?.invalidate()
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
    }

    func start() {
        guard watchdogTimer == nil else { return }
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
        refresh()
    }

    func refresh() {
        let frontmostBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil"
        guard frontmostBundle == bundleIdentifier else {
            stopTracking()
            onFrameChanged?(nil)
            return
        }

        let frame = frontmostWindowFrame()
        onFrameChanged?(frame)
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.onFrameChanged?(self.frontmostWindowFrame())
                }
            }
        }
    }

    private func stopTracking() {
        timer?.invalidate()
        timer = nil
    }

    private func frontmostWindowFrame() -> CGRect? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier == bundleIdentifier else { return nil }

        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        let candidates = windows.compactMap { window -> CGRect? in
            guard let ownerPID = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  ownerPID == app.processIdentifier,
                  ((window[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1) == 0,
                  ((window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 0) > 0,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let quartzFrame = CGRect(dictionaryRepresentation: bounds),
                  quartzFrame.width > 100,
                  quartzFrame.height > 100
            else { return nil }
            return quartzFrame
        }

        // Codex can expose small transient windows alongside its main window.
        // The largest visible layer-0 window is the stable main-window anchor.
        return candidates.max { lhs, rhs in
            lhs.width * lhs.height < rhs.width * rhs.height
        }.map(quartzToAppKit)
    }


    private func quartzToAppKit(_ frame: CGRect) -> CGRect {
        // NSScreen.screens.first is the primary display, whose frame origin is
        // always (0, 0). NSScreen.main is the screen holding the key window,
        // not the primary one, so it is not a substitute here.
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? frame.maxY
        return PanelPlacement.appKitFrame(quartzFrame: frame, primaryScreenMaxY: primaryMaxY)
    }
}

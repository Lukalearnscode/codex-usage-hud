import AppKit
import CodexUsageHUDCore

private final class UsageBarView: NSView {
    private let trackHeight: CGFloat = 6

    private var usedPercent = 0.0
    private var fillColor = NSColor.secondaryLabelColor
    private var stale = false

    override var intrinsicContentSize: NSSize {
        NSSize(width: 72, height: 8)
    }

    func update(usedPercent: Double, color: NSColor, stale: Bool) {
        self.usedPercent = RateLimitParser.clamp(usedPercent)
        self.fillColor = color
        self.stale = stale
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let height = min(trackHeight, bounds.height)
        let y = (bounds.height - height) / 2

        let trackRect = CGRect(x: 0, y: y, width: bounds.width, height: height)
        let trackColor = stale
            ? fillColor.withAlphaComponent(0.18)
            : NSColor.secondaryLabelColor.withAlphaComponent(0.18)
        trackColor.setFill()
        NSBezierPath(roundedRect: trackRect, xRadius: height / 2, yRadius: height / 2).fill()

        let fillWidth = bounds.width * CGFloat(usedPercent / 100.0)
        if fillWidth > 0 {
            let fillRect = CGRect(x: 0, y: y, width: fillWidth, height: height)
            fillColor.setFill()
            NSBezierPath(roundedRect: fillRect, xRadius: height / 2, yRadius: height / 2).fill()
        }
    }
}

private final class HUDPanel: NSPanel {
    var onContextMenu: ((NSEvent) -> Void)?
    var onHoverChanged: ((Bool) -> Void)?

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func rightMouseDown(with event: NSEvent) {
        onContextMenu?(event)
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChanged?(false)
    }
}

@MainActor
final class HUDPanelController: NSObject, NSWindowDelegate {
    private let panel: HUDPanel
    private let effectView = NSVisualEffectView()
    private let manualOriginXKey = "hud.manualOrigin.x"
    private let manualOriginYKey = "hud.manualOrigin.y"
    private let fiveHourName = NSTextField(labelWithString: "5\u{2009}小时")
    private let fiveHourBar = UsageBarView()
    private let fiveHourPercent = NSTextField(labelWithString: "—")
    private let fiveHourStatus = NSTextField(labelWithString: "")
    private let weeklyName = NSTextField(labelWithString: "本周")
    private let weeklyBar = UsageBarView()
    private let weeklyPercent = NSTextField(labelWithString: "—")
    private let weeklyStatus = NSTextField(labelWithString: "")
    // Keep the usage signal legible without the visual weight of system blue,
    // orange, and red on a translucent dark panel.
    private let quietBlue = NSColor(calibratedRed: 0.46, green: 0.53, blue: 0.60, alpha: 1.0)
    private let quietAmber = NSColor(calibratedRed: 0.64, green: 0.55, blue: 0.43, alpha: 1.0)
    private let quietRed = NSColor(calibratedRed: 0.64, green: 0.46, blue: 0.46, alpha: 1.0)

    private var snapshot: RateLimitSnapshot?
    private var lastStatus: AppServerClientStatus = .unavailable
    private var expirationRefreshSent: [Int: Date] = [:]
    private var hasManualPosition = false
    private var applyingTrackedPosition = false
    private var lastAppliedTrackedOrigin: CGPoint?
    private var lastCodexFrame: CGRect?

    var onNeedsRefresh: (() -> Void)?

    override init() {
        panel = HUDPanel(
            contentRect: CGRect(x: 0, y: 0, width: 288, height: 64),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.ignoresMouseEvents = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.worksWhenModal = true
        panel.isMovableByWindowBackground = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.alphaValue = 1
        super.init()
        panel.delegate = self
        panel.onContextMenu = { [weak self] event in
            self?.showContextMenu(for: event)
        }
        panel.onHoverChanged = { [weak self] isHovered in
            self?.setHovered(isHovered)
        }
        panel.contentView?.addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
            owner: panel,
            userInfo: nil
        ))

        if let savedOrigin = savedManualOrigin(panelSize: panel.frame.size) {
            applyingTrackedPosition = true
            panel.setFrameOrigin(savedOrigin)
            applyingTrackedPosition = false
            hasManualPosition = true
        }

        // A display change can strand the manual position on a screen that no
        // longer exists. The only reset control lives in the panel's own
        // context menu, so an off-screen panel is unrecoverable without
        // editing defaults by hand. Re-check whenever the screen layout moves.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        effectView.material = .hudWindow
        effectView.blendingMode = .withinWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 12
        effectView.layer?.borderWidth = 0.5
        effectView.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.12).cgColor
        effectView.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView?.addSubview(effectView)
        NSLayoutConstraint.activate([
            effectView.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor),
            effectView.topAnchor.constraint(equalTo: panel.contentView!.topAnchor),
            effectView.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor)
        ])

        configureLabels()
        let grid = NSGridView(views: [
            [fiveHourName, fiveHourBar, fiveHourPercent, fiveHourStatus],
            [weeklyName, weeklyBar, weeklyPercent, weeklyStatus]
        ])
        grid.rowSpacing = 5
        grid.columnSpacing = 8
        for rowIndex in 0..<grid.numberOfRows {
            grid.row(at: rowIndex).yPlacement = .center
        }
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .center
        grid.column(at: 2).xPlacement = .trailing
        grid.column(at: 3).xPlacement = .leading
        grid.translatesAutoresizingMaskIntoConstraints = false
        effectView.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: effectView.leadingAnchor, constant: 14),
            grid.trailingAnchor.constraint(equalTo: effectView.trailingAnchor, constant: -14),
            grid.topAnchor.constraint(equalTo: effectView.topAnchor, constant: 10),
            grid.bottomAnchor.constraint(equalTo: effectView.bottomAnchor, constant: -10)
        ])
        render()
    }

    func setSnapshot(_ snapshot: RateLimitSnapshot) {
        self.snapshot = snapshot
        lastStatus = .available
        render()
    }

    func setStatus(_ status: AppServerClientStatus) {
        lastStatus = status
        render()
    }

    func tick() {
        render()
    }

    func updateWindowFrame(_ codexFrame: CGRect?) {
        guard let codexFrame else {
            lastCodexFrame = nil
            panel.orderOut(nil)
            return
        }
        lastCodexFrame = codexFrame
        // AppKit uses a bottom-left origin. The panel sits 52pt above the
        // Codex window's bottom edge, so its bottom is minY + 52.
        if !hasManualPosition {
            let rightOrigin = CGPoint(
                x: codexFrame.maxX - panel.frame.width - 12,
                y: codexFrame.minY + 52
            )
            let leftOrigin = CGPoint(x: codexFrame.minX + 8, y: codexFrame.minY + 52)
            let hudOrigin = rightOrigin.x >= codexFrame.minX + 8 ? rightOrigin : leftOrigin
            if panel.frame.origin != hudOrigin {
                applyingTrackedPosition = true
                panel.setFrameOrigin(hudOrigin)
                applyingTrackedPosition = false
                lastAppliedTrackedOrigin = hudOrigin
            }
        }
        panel.setIsVisible(true)
        panel.orderFrontRegardless()
    }

    func windowDidMove(_ notification: Notification) {
        guard !applyingTrackedPosition else { return }
        if panel.frame.origin == lastAppliedTrackedOrigin {
            lastAppliedTrackedOrigin = nil
            return
        }
        lastAppliedTrackedOrigin = nil
        hasManualPosition = true
        UserDefaults.standard.set(panel.frame.origin.x, forKey: manualOriginXKey)
        UserDefaults.standard.set(panel.frame.origin.y, forKey: manualOriginYKey)
    }

    private func setHovered(_ isHovered: Bool) {
        effectView.layer?.borderColor = NSColor.separatorColor
            .withAlphaComponent(isHovered ? 0.22 : 0.12)
            .cgColor
    }

    private func showContextMenu(for event: NSEvent) {
        let menu = NSMenu()
        let refreshItem = NSMenuItem(title: "立即刷新", action: #selector(refreshFromMenu), keyEquivalent: "r")
        refreshItem.target = self
        let resetItem = NSMenuItem(title: "恢复默认位置", action: #selector(resetPositionFromMenu), keyEquivalent: "")
        resetItem.target = self
        let quitItem = NSMenuItem(title: "退出", action: #selector(quitFromMenu), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(refreshItem)
        menu.addItem(resetItem)
        menu.addItem(.separator())
        menu.addItem(quitItem)
        menu.popUp(positioning: nil, at: event.locationInWindow, in: panel.contentView)
    }

    @objc private func refreshFromMenu() {
        onNeedsRefresh?()
    }

    @objc private func resetPositionFromMenu() {
        discardManualPosition()
        if let lastCodexFrame {
            updateWindowFrame(lastCodexFrame)
        }
    }

    @objc private func quitFromMenu() {
        NSApp.terminate(nil)
    }

    private func configureLabels() {
        for label in [fiveHourName, weeklyName] {
            label.font = hudFont(ofSize: 12, bold: true)
            // Same weight as the countdown on the right: labelColor sits at
            // alpha 0.85 against secondaryLabelColor's 0.55, which read as two
            // different opacities across one row.
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byClipping
            label.maximumNumberOfLines = 1
            label.alignment = .right
            label.setContentHuggingPriority(.required, for: .horizontal)
            label.widthAnchor.constraint(equalToConstant: 40).isActive = true
        }
        for bar in [fiveHourBar, weeklyBar] {
            bar.setContentHuggingPriority(.required, for: .horizontal)
            bar.widthAnchor.constraint(equalToConstant: 72).isActive = true
            bar.heightAnchor.constraint(equalToConstant: 8).isActive = true
        }
        for label in [fiveHourPercent, weeklyPercent] {
            label.font = hudFont(ofSize: 12)
            label.lineBreakMode = .byClipping
            label.maximumNumberOfLines = 1
            label.alignment = .right
            label.textColor = .labelColor
            label.setContentHuggingPriority(.required, for: .horizontal)
            label.widthAnchor.constraint(equalToConstant: 34).isActive = true
        }
        for label in [fiveHourStatus, weeklyStatus] {
            label.font = hudFont(ofSize: 12)
            label.lineBreakMode = .byClipping
            label.maximumNumberOfLines = 1
            label.alignment = .right
            label.textColor = .secondaryLabelColor
            label.setContentHuggingPriority(.required, for: .horizontal)
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
            label.widthAnchor.constraint(equalToConstant: 90).isActive = true
        }
    }

    private func hudFont(ofSize size: CGFloat, bold: Bool = false) -> NSFont {
        let name = bold ? "Songti SC Bold" : "Songti SC"
        return NSFont(name: name, size: size) ?? NSFont.systemFont(ofSize: size)
    }

    private func render() {
        guard let snapshot else {
            renderEmpty()
            return
        }
        let stale = Date().timeIntervalSince(snapshot.fetchedAt) > 180
        // Both rows share one run width so their 后重置 land on the same x.
        // Measuring the pair here, rather than assuming a worst case, keeps the
        // gap no wider than the two countdowns actually on screen require.
        let now = Date()
        let font = hudFont(ofSize: 12)
        let runWidth = [snapshot.fiveHour, snapshot.weekly]
            .compactMap { window -> CGFloat? in
                guard let window, !stale, window.resetsAt > now else { return nil }
                return CountdownTypesetter.compactRunWidth(
                    for: UsagePresentation.countdownLayout(until: window.resetsAt, now: now),
                    font: font
                )
            }
            .max() ?? 0
        render(window: snapshot.fiveHour, name: fiveHourName, bar: fiveHourBar, percent: fiveHourPercent, status: fiveHourStatus, stale: stale, key: 300, runWidth: runWidth)
        render(window: snapshot.weekly, name: weeklyName, bar: weeklyBar, percent: weeklyPercent, status: weeklyStatus, stale: stale, key: 10080, runWidth: runWidth)
    }

    private func renderEmpty() {
        let (headline, detail) = UsagePresentation.emptyStateLines(for: lastStatus)
        let lines = [
            (fiveHourBar, fiveHourPercent, fiveHourStatus, headline),
            (weeklyBar, weeklyPercent, weeklyStatus, detail)
        ]
        for (bar, percent, status, text) in lines {
            bar.update(usedPercent: 0, color: .secondaryLabelColor, stale: true)
            percent.stringValue = "—"
            status.stringValue = text
            percent.textColor = .secondaryLabelColor
            status.textColor = .secondaryLabelColor
        }
    }

    private func render(window: RateLimitWindow?, name: NSTextField, bar: UsageBarView, percent: NSTextField, status: NSTextField, stale: Bool, key: Int, runWidth: CGFloat) {
        guard let window else {
            bar.update(usedPercent: 0, color: .secondaryLabelColor, stale: true)
            percent.stringValue = "—"
            status.stringValue = "—"
            percent.textColor = .secondaryLabelColor
            status.textColor = .secondaryLabelColor
            return
        }
        let color: NSColor = stale ? .secondaryLabelColor : usageColor(for: window.usedPercent)
        bar.update(usedPercent: window.usedPercent, color: color, stale: stale)
        percent.stringValue = "\(Int(window.usedPercent.rounded()))%"
        percent.textColor = stale ? .secondaryLabelColor : color
        status.textColor = stale ? .secondaryLabelColor : .secondaryLabelColor
        if stale {
            status.stringValue = "数据滞后"
        } else if window.resetsAt <= Date() {
            status.stringValue = "正在重置…"
            if expirationRefreshSent[key] != window.resetsAt {
                expirationRefreshSent[key] = window.resetsAt
                onNeedsRefresh?()
            }
        } else {
            status.attributedStringValue = CountdownTypesetter.attributedString(
                for: UsagePresentation.countdownLayout(until: window.resetsAt),
                font: hudFont(ofSize: 12),
                color: status.textColor ?? .secondaryLabelColor,
                runWidth: runWidth
            )
        }
    }


    private func usageColor(for percent: Double) -> NSColor {
        if percent < 70 { return quietBlue }
        if percent < 90 { return quietAmber }
        return quietRed
    }

    private func savedManualOrigin(panelSize: CGSize) -> CGPoint? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: manualOriginXKey) != nil,
              defaults.object(forKey: manualOriginYKey) != nil else { return nil }
        let origin = CGPoint(
            x: defaults.double(forKey: manualOriginXKey),
            y: defaults.double(forKey: manualOriginYKey)
        )
        guard Self.isOriginReachable(origin, size: panelSize) else {
            discardManualPosition()
            return nil
        }
        return origin
    }

    static func isOriginReachable(_ origin: CGPoint, size: CGSize) -> Bool {
        PanelPlacement.isReachable(
            CGRect(origin: origin, size: size),
            visibleFrames: NSScreen.screens.map(\.visibleFrame)
        )
    }

    private func discardManualPosition() {
        hasManualPosition = false
        UserDefaults.standard.removeObject(forKey: manualOriginXKey)
        UserDefaults.standard.removeObject(forKey: manualOriginYKey)
    }

    @objc private func screenParametersChanged() {
        guard hasManualPosition else { return }
        guard !Self.isOriginReachable(panel.frame.origin, size: panel.frame.size) else { return }
        discardManualPosition()
        if let lastCodexFrame {
            updateWindowFrame(lastCodexFrame)
        }
    }
}

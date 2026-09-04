import AppKit
import CodexUsageHUDCore

enum ColorScheme: String, CaseIterable {
    case rosewood, quiet, dusk, sage, slate

    static let key = "hud.colorScheme"
    static var current: ColorScheme {
        ColorScheme(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .rosewood
    }

    var displayName: String {
        switch self {
        case .rosewood: return "灰蓝 → 暗玫瑰"
        case .quiet: return "静默升级"
        case .dusk: return "雾青 → 黄昏紫"
        case .sage: return "鼠尾草 → 陶土"
        case .slate: return "石板 → 铁锈"
        }
    }

    /// Every value is computed, not eyeballed: each clears 4.5 contrast against
    /// its own panel background. 4.5 is the body-text threshold rather than the
    /// 3.0 one for graphics, because these colours carry the percentage label
    /// as well as the bar. The hue progressions keep saturation low and
    /// grey-leaning, read as an ordered progression rather than three unrelated
    /// hues, and leave the quiet end nearly colourless so colour only appears
    /// when it means something.
    var colors: (low: NSColor, mid: NSColor, high: NSColor) {
        func c(_ lr: CGFloat, _ lg: CGFloat, _ lb: CGFloat,
               _ dr: CGFloat, _ dg: CGFloat, _ db: CGFloat) -> NSColor {
            adaptiveColor(light: NSColor(calibratedRed: lr, green: lg, blue: lb, alpha: 1),
                          dark: NSColor(calibratedRed: dr, green: dg, blue: db, alpha: 1))
        }
        switch self {
        case .rosewood:
            return (c(0.40, 0.45, 0.53, 0.49, 0.54, 0.60),
                    c(0.52, 0.43, 0.35, 0.60, 0.52, 0.44),
                    c(0.57, 0.40, 0.44, 0.65, 0.49, 0.53))
        case .quiet:
            return (c(0.44, 0.45, 0.46, 0.52, 0.53, 0.55),
                    c(0.50, 0.44, 0.35, 0.58, 0.52, 0.44),
                    c(0.60, 0.39, 0.37, 0.67, 0.49, 0.47))
        case .dusk:
            return (c(0.36, 0.46, 0.48, 0.45, 0.55, 0.56),
                    c(0.49, 0.42, 0.53, 0.57, 0.51, 0.60),
                    c(0.56, 0.39, 0.51, 0.64, 0.49, 0.59))
        case .sage:
            return (c(0.37, 0.47, 0.37, 0.46, 0.56, 0.46),
                    c(0.50, 0.44, 0.33, 0.58, 0.53, 0.42),
                    c(0.56, 0.41, 0.35, 0.64, 0.50, 0.44))
        case .slate:
            return (c(0.41, 0.45, 0.51, 0.49, 0.54, 0.59),
                    c(0.49, 0.44, 0.36, 0.58, 0.53, 0.45),
                    c(0.59, 0.40, 0.34, 0.66, 0.49, 0.44))
        }
    }
}

/// A colour that resolves differently in Light and Dark Mode. Views resolve it
/// against their own effective appearance when drawing, so a self-drawn bar
/// picks up the right one without checking anything itself.
private func adaptiveColor(light: NSColor, dark: NSColor) -> NSColor {
    NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
    }
}

/// A plain translucent backing, used when the frosted material is not wanted.
/// Drawing it by hand means the adaptive colour resolves against this view's
/// own effective appearance, which a CGColor on a layer would not do.
private final class TintView: NSView {
    var fill: NSColor = .clear { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        fill.setFill()
        bounds.fill()
    }
}

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
    private let container = NSView()
    private let effectView = NSVisualEffectView()
    private let tintView = TintView()
    private let panelStyleKey = "hud.frostedStyle"
    private let appearanceKey = "hud.appearance"
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
    // Five palettes to choose between, all measured rather than eyeballed:
    // every colour clears 4.5 contrast against its own panel background, so
    // none of them can end up as unreadable as the original single palette did
    // on a light background (1.4-1.7).
    private var scheme: ColorScheme { ColorScheme.current }
    private var quietBlue: NSColor { scheme.colors.low }
    private var quietAmber: NSColor { scheme.colors.mid }
    private var quietRed: NSColor { scheme.colors.high }

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

        // The rounded corner and hairline border live on a container, not on
        // the visual-effect view. Setting wantsLayer and layer properties
        // directly on an NSVisualEffectView replaces the backdrop layer the
        // system draws its material into, which is one way to end up with a
        // flat slab where the translucency should be.
        container.wantsLayer = true
        container.layer?.cornerRadius = 12
        container.layer?.masksToBounds = true
        container.layer?.borderWidth = 0.5
        container.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.12).cgColor
        container.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView?.addSubview(container)
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor),
            container.topAnchor.constraint(equalTo: panel.contentView!.topAnchor),
            container.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor)
        ])

        tintView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(tintView)
        NSLayoutConstraint.activate([
            tintView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tintView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            tintView.topAnchor.constraint(equalTo: container.topAnchor),
            tintView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        // .hudWindow is a dark-only material: in Light Mode it renders as a
        // flat mid-grey slab. .popover follows the system appearance.
        effectView.material = .popover
        // .withinWindow blends against sibling views inside this window, and
        // this view is the bottom of the panel, so there is nothing to blend
        // with. .behindWindow is what samples the window underneath.
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(effectView)
        NSLayoutConstraint.activate([
            effectView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            effectView.topAnchor.constraint(equalTo: container.topAnchor),
            effectView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
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
        container.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            grid.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            grid.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            grid.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10)
        ])
        applyPanelStyle()
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
        container.layer?.borderColor = NSColor.separatorColor
            .withAlphaComponent(isHovered ? 0.22 : 0.12)
            .cgColor
    }

    private func showContextMenu(for event: NSEvent) {
        let menu = NSMenu()
        let refreshItem = NSMenuItem(title: "立即刷新", action: #selector(refreshFromMenu), keyEquivalent: "r")
        refreshItem.target = self
        let resetItem = NSMenuItem(title: "恢复默认位置", action: #selector(resetPositionFromMenu), keyEquivalent: "")
        resetItem.target = self
        let appearanceItem = NSMenuItem(title: "明暗", action: nil, keyEquivalent: "")
        let appearanceMenu = NSMenu()
        let currentAppearance = UserDefaults.standard.string(forKey: appearanceKey) ?? "system"
        for (raw, title) in [("system", "跟随系统"), ("light", "浅色"), ("dark", "深色")] {
            let item = NSMenuItem(title: title, action: #selector(pickAppearance(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = raw
            item.state = raw == currentAppearance ? .on : .off
            appearanceMenu.addItem(item)
        }
        appearanceItem.submenu = appearanceMenu
        let quitItem = NSMenuItem(title: "退出", action: #selector(quitFromMenu), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(refreshItem)
        menu.addItem(resetItem)
        menu.addItem(appearanceItem)

        let schemeItem = NSMenuItem(title: "配色", action: nil, keyEquivalent: "")
        let schemeMenu = NSMenu()
        for option in ColorScheme.allCases {
            let item = NSMenuItem(title: option.displayName,
                                  action: #selector(pickColorScheme(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = option.rawValue
            item.state = option == ColorScheme.current ? .on : .off
            schemeMenu.addItem(item)
        }
        schemeItem.submenu = schemeMenu
        menu.addItem(schemeItem)
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

    // Default is the plain translucent backing. Three attempts showed the
    // .behindWindow material never samples anything on a borderless
    // nonactivating panel: the interior stayed a perfectly uniform colour in
    // every Light Mode screenshot. Window-server alpha compositing does work.
    private var usesFrostedStyle: Bool {
        UserDefaults.standard.object(forKey: panelStyleKey) as? Bool ?? false
    }

    @objc private func pickColorScheme(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        UserDefaults.standard.set(raw, forKey: ColorScheme.key)
        render()
    }

    private func applyPanelStyle() {
        let frosted = usesFrostedStyle
        effectView.isHidden = !frosted
        tintView.isHidden = frosted
        tintView.fill = adaptiveColor(
            light: NSColor(calibratedWhite: 0.97, alpha: 0.78),
            dark: NSColor(calibratedWhite: 0.13, alpha: 0.76))
        applyAppearance()
    }

    /// The panel follows the macOS system appearance by default, but Codex has
    /// its own light/dark theme setting that does not have to agree with it. A
    /// dark system with a light Codex leaves a dark slab sitting on a light
    /// window, so the appearance is overridable here.
    private func applyAppearance() {
        switch UserDefaults.standard.string(forKey: appearanceKey) {
        case "light": panel.appearance = NSAppearance(named: .aqua)
        case "dark": panel.appearance = NSAppearance(named: .darkAqua)
        default: panel.appearance = nil
        }
        tintView.needsDisplay = true
        render()
    }

    @objc private func pickAppearance(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        if raw == "system" {
            UserDefaults.standard.removeObject(forKey: appearanceKey)
        } else {
            UserDefaults.standard.set(raw, forKey: appearanceKey)
        }
        applyAppearance()
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

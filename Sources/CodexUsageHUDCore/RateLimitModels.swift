import Foundation

public struct RateLimitWindow: Equatable, Sendable {
    public let usedPercent: Double
    public let windowDurationMinutes: Int
    public let resetsAt: Date

    public init(usedPercent: Double, windowDurationMinutes: Int, resetsAt: Date) {
        self.usedPercent = usedPercent
        self.windowDurationMinutes = windowDurationMinutes
        self.resetsAt = resetsAt
    }
}

public struct RateLimitSnapshot: Equatable, Sendable {
    /// Every window the server reported, shortest first. Paid plans send a
    /// five-hour and a weekly window; the free plan sends a single 30-day one
    /// (seen 2026-09-11 after the subscription lapsed). Keying rows by fixed
    /// durations dropped that window on the floor, and the HUD kept showing
    /// the last paid-plan numbers as "数据滞后" for six days.
    public let windows: [RateLimitWindow]
    /// `planType` from the rate-limit bucket: "free", "plus", "pro", ...
    public let planType: String?
    public let fetchedAt: Date

    public init(windows: [RateLimitWindow], planType: String? = nil, fetchedAt: Date) {
        self.windows = windows.sorted { $0.windowDurationMinutes < $1.windowDurationMinutes }
        self.planType = planType
        self.fetchedAt = fetchedAt
    }

    public func window(minutes: Int) -> RateLimitWindow? {
        windows.first { $0.windowDurationMinutes == minutes }
    }

    public var fiveHour: RateLimitWindow? { window(minutes: 300) }
    public var weekly: RateLimitWindow? { window(minutes: 10080) }
}

public enum RateLimitParseOutcome: Equatable {
    case snapshot(RateLimitSnapshot)
    case notAuthenticated
    case invalid
}

public enum RateLimitParser {
    public static func parse(_ data: Data, fetchedAt: Date = Date()) -> RateLimitParseOutcome {
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let message = object as? [String: Any],
            let result = message["result"] as? [String: Any]
        else {
            return .invalid
        }

        let selectedBucket: [String: Any]?
        if let buckets = result["rateLimitsByLimitId"] as? [String: Any],
           let codex = buckets["codex"] as? [String: Any] {
            selectedBucket = codex
        } else {
            selectedBucket = result["rateLimits"] as? [String: Any]
        }

        guard let bucket = selectedBucket else { return .notAuthenticated }

        var windows: [Int: RateLimitWindow] = [:]
        for key in ["primary", "secondary"] {
            guard let rawWindow = bucket[key] as? [String: Any],
                  let duration = intValue(rawWindow["windowDurationMins"]),
                  let timestamp = doubleValue(rawWindow["resetsAt"]),
                  duration > 0,
                  timestamp.isFinite
            else { continue }

            let rawUsed = doubleValue(rawWindow["usedPercent"]) ?? 0
            let used = rawUsed.isFinite ? clamp(rawUsed, lower: 0, upper: 100) : 0
            windows[duration] = RateLimitWindow(
                usedPercent: used,
                windowDurationMinutes: duration,
                resetsAt: Date(timeIntervalSince1970: timestamp)
            )
        }

        guard !windows.isEmpty else { return .invalid }
        return .snapshot(RateLimitSnapshot(
            windows: Array(windows.values),
            planType: bucket["planType"] as? String,
            fetchedAt: fetchedAt
        ))
    }

    public static func clamp(_ value: Double, lower: Double = 0, upper: Double = 100) -> Double {
        guard value.isFinite else { return lower }
        return Swift.min(Swift.max(value, lower), upper)
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }
}

public enum UsagePresentation {
    static let narrowSpace = "\u{2009}"

    /// Wording shown when there is no snapshot to draw.
    ///
    /// The parser reports `.notAuthenticated` whenever the response carries no
    /// rate-limit bucket at all, and being signed out is only one way to land
    /// there: a renamed or restructured field does it too. Naming only the
    /// login would send the user to re-authenticate over a protocol change, so
    /// the headline states what failed and the detail names the likely cause
    /// without asserting it. The two strings fill the panel's two existing
    /// rows, so neither has to fit one row's width alone.
    public static func emptyStateLines(for status: AppServerClientStatus) -> (headline: String, detail: String) {
        switch status {
        case .notAuthenticated: return ("无法读取额度", "请确认已登录")
        case .connecting: return ("正在连接…", "")
        case .unavailable: return ("无法读取额度", "正在重试…")
        case .available: return ("等待数据…", "")
        }
    }

    public static func progressBar(for usedPercent: Double) -> String {
        let filled = Int((RateLimitParser.clamp(usedPercent) / 100.0 * 8.0).rounded())
        let count = Swift.min(Swift.max(filled, 0), 8)
        return String(repeating: "█", count: count) + String(repeating: "░", count: 8 - count)
    }

    /// Row label for a window, by its length. The two paid-plan windows keep
    /// the wording the panel has always used; any other window is named by
    /// its duration so it still reads as one. The name column is 40pt, so
    /// keep these within about three CJK characters.
    public static func windowName(minutes: Int) -> String {
        switch minutes {
        case 300: return "5\(narrowSpace)小时"
        case 10080: return "本周"
        default:
            if minutes % (24 * 60) == 0 { return "\(minutes / (24 * 60))\(narrowSpace)天" }
            if minutes % 60 == 0 { return "\(minutes / 60)\(narrowSpace)小时" }
            return "\(minutes)\(narrowSpace)分"
        }
    }

    /// Wording for the plan row the panel shows when the server reports only
    /// one window. Short enough that it can never clip in the 90pt status
    /// column (seven CJK characters at 12pt).
    public static func planLabel(for planType: String?) -> String {
        guard let planType, !planType.isEmpty else { return "" }
        switch planType.lowercased() {
        case "free": return "免费档"
        case "plus": return "Plus"
        case "pro": return "Pro"
        case "team": return "Team"
        case "business": return "Business"
        case "enterprise": return "Enterprise"
        case "edu": return "Edu"
        default: return planType
        }
    }

    /// A countdown split into its parts.
    ///
    /// The panel needs the pieces, not just the sentence: `m` is 9.42pt wide in
    /// Songti SC against 6.38 for `h` and 6.17 for `d`, so "2 h 21 m 后重置"
    /// and "6 d 11 h 后重置" drift apart by 3.25pt even though the digits are
    /// all 5.628pt. Knowing where each unit letter starts lets the panel pad
    /// them to one width and keep the two rows in step.
    public struct CountdownLayout: Equatable, Sendable {
        public struct Pair: Equatable, Sendable {
            public let value: String
            public let unit: String

            public init(value: String, unit: String) {
                self.value = value
                self.unit = unit
            }
        }

        public let pairs: [Pair]
        public let suffix: String

        public init(pairs: [Pair], suffix: String) {
            self.pairs = pairs
            self.suffix = suffix
        }

        /// The same countdown as one string, narrow spaces included.
        public var plain: String {
            let rendered = pairs.map { "\($0.value)\(UsagePresentation.narrowSpace)\($0.unit)" }
                .joined(separator: UsagePresentation.narrowSpace)
            guard !rendered.isEmpty else { return suffix }
            guard !suffix.isEmpty else { return rendered }
            return rendered + UsagePresentation.narrowSpace + suffix
        }
    }

    public static func countdownLayout(until date: Date, now: Date = Date()) -> CountdownLayout {
        let seconds = date.timeIntervalSince(now)
        guard seconds > 0 else { return CountdownLayout(pairs: [], suffix: "正在重置…") }

        let minutes = Int(ceil(seconds / 60.0))
        let pairs: [CountdownLayout.Pair]
        if minutes < 24 * 60 {
            if minutes < 60 {
                pairs = [.init(value: "\(minutes)", unit: "m")]
            } else {
                pairs = [.init(value: "\(minutes / 60)", unit: "h"),
                         .init(value: "\(minutes % 60)", unit: "m")]
            }
        } else {
            let days = minutes / (24 * 60)
            let remainingMinutes = minutes % (24 * 60)
            let hours = (remainingMinutes + 59) / 60
            if hours >= 24 {
                pairs = [.init(value: "\(days + 1)", unit: "d"), .init(value: "0", unit: "h")]
            } else {
                pairs = [.init(value: "\(days)", unit: "d"), .init(value: "\(hours)", unit: "h")]
            }
        }
        return CountdownLayout(pairs: pairs, suffix: "后重置")
    }

    public static func countdown(until date: Date, now: Date = Date()) -> String {
        countdownLayout(until: date, now: now).plain
    }
}

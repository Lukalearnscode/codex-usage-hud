import AppKit
import CoreGraphics
import Foundation
import CodexUsageHUDCore

@main
enum RateLimitCoreTests {
    static func main() {
        testParsesPreferredCodexBucketAndBothWindows()
        testFallsBackToLegacyBucket()
        testParsesFreePlanSingleWindow()
        testClampsPercentAndRecognizesUnauthenticated()
        testRendersEightSegmentProgress()
        testRendersCountdownBoundaries()
        testMapsQuartzToAppKitUsingPrimaryScreenOnly()
        testRejectsUnreachableSavedPositions()
        testEmptyStateWordingDoesNotAssertSignedOut()
        testCountdownRowsEndTogetherWithNoInnerGaps()
        print("CodexUsageHUDCoreTests: 10 passed")
    }

    private static let fetchedAt = Date(timeIntervalSince1970: 1_700_000_000)

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }

    private static func testParsesPreferredCodexBucketAndBothWindows() {
        let json = """
        {"result":{"rateLimits":{"primary":{"usedPercent":99,"windowDurationMins":15,"resetsAt":1700000600}},"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":47,"windowDurationMins":300,"resetsAt":1700008280},"secondary":{"usedPercent":23,"windowDurationMins":10080,"resetsAt":1700563380}}}}}
        """.data(using: .utf8)!
        guard case let .snapshot(snapshot) = RateLimitParser.parse(json, fetchedAt: fetchedAt) else { fatalError("preferred bucket did not parse") }
        check(snapshot.fiveHour?.usedPercent == 47, "preferred five-hour bucket")
        check(snapshot.weekly?.usedPercent == 23, "preferred weekly bucket")
        check(snapshot.fiveHour?.windowDurationMinutes == 300, "five-hour duration")
        check(snapshot.weekly?.windowDurationMinutes == 10080, "weekly duration")
    }

    private static func testFallsBackToLegacyBucket() {
        let json = """
        {"result":{"rateLimits":{"primary":{"usedPercent":12,"windowDurationMins":300,"resetsAt":1700000600},"secondary":{"usedPercent":34,"windowDurationMins":10080,"resetsAt":1700563380}}}}
        """.data(using: .utf8)!
        guard case let .snapshot(snapshot) = RateLimitParser.parse(json, fetchedAt: fetchedAt) else { fatalError("legacy bucket did not parse") }
        check(snapshot.fiveHour?.usedPercent == 12, "legacy five-hour bucket")
        check(snapshot.weekly?.usedPercent == 34, "legacy weekly bucket")
    }

    private static func testParsesFreePlanSingleWindow() {
        // Verbatim (account id redacted) from account/rateLimits/read on
        // 2026-09-11, after the paid subscription lapsed: one 30-day window,
        // secondary null, planType "free". The old parser returned .invalid
        // for this and the HUD kept showing six-day-old numbers.
        let json = """
        {"id":2,"result":{"rateLimits":{"limitId":"codex","limitName":null,"primary":{"usedPercent":33,"windowDurationMins":43200,"resetsAt":1791690762},"secondary":null,"credits":{"hasCredits":false,"unlimited":false,"balance":null},"individualLimit":null,"spendControlReached":false,"planType":"free","rateLimitReachedType":null},"rateLimitsByLimitId":{"codex":{"limitId":"codex","limitName":null,"primary":{"usedPercent":33,"windowDurationMins":43200,"resetsAt":1791690762},"secondary":null,"credits":{"hasCredits":false,"unlimited":false,"balance":null},"individualLimit":null,"spendControlReached":false,"planType":"free","rateLimitReachedType":null}},"rateLimitResetCredits":{"availableCount":0,"credits":[]},"accountId":"redacted","rateLimitUpsell":null}}
        """.data(using: .utf8)!
        guard case let .snapshot(snapshot) = RateLimitParser.parse(json, fetchedAt: fetchedAt) else { fatalError("free plan did not parse") }
        check(snapshot.windows.count == 1, "free plan has one window")
        check(snapshot.windows.first?.windowDurationMinutes == 43200, "free plan window is 30 days")
        check(snapshot.windows.first?.usedPercent == 33, "free plan usage")
        check(snapshot.planType == "free", "free plan type")
        check(snapshot.fiveHour == nil && snapshot.weekly == nil, "no paid windows on the free plan")
        check(UsagePresentation.windowName(minutes: 43200) == "30\u{2009}天", "30-day window name")
        check(UsagePresentation.windowName(minutes: 300) == "5\u{2009}小时", "five-hour window name unchanged")
        check(UsagePresentation.windowName(minutes: 10080) == "本周", "weekly window name unchanged")
        check(UsagePresentation.planLabel(for: "free") == "免费档", "free plan label")
        check(UsagePresentation.planLabel(for: nil) == "", "missing plan label")

        // Rows go shortest first whichever slot the server put them in.
        let reversed = """
        {"result":{"rateLimits":{"primary":{"usedPercent":5,"windowDurationMins":10080,"resetsAt":1700563380},"secondary":{"usedPercent":9,"windowDurationMins":300,"resetsAt":1700008280}}}}
        """.data(using: .utf8)!
        guard case let .snapshot(sorted) = RateLimitParser.parse(reversed, fetchedAt: fetchedAt) else { fatalError("reversed sample did not parse") }
        check(sorted.windows.map(\.windowDurationMinutes) == [300, 10080], "windows sorted shortest first")

        let noWindows = #"{"result":{"rateLimits":{"planType":"free","primary":null,"secondary":null}}}"#.data(using: .utf8)!
        check(RateLimitParser.parse(noWindows, fetchedAt: fetchedAt) == .invalid, "a bucket with no windows is invalid")
    }

    private static func testClampsPercentAndRecognizesUnauthenticated() {
        let high = """
        {"result":{"rateLimits":{"primary":{"usedPercent":140,"windowDurationMins":300,"resetsAt":1700000600}}}}
        """.data(using: .utf8)!
        let empty = #"{"result":{"rateLimits":null}}"#.data(using: .utf8)!
        guard case let .snapshot(snapshot) = RateLimitParser.parse(high, fetchedAt: fetchedAt) else { fatalError("clamp sample did not parse") }
        check(snapshot.fiveHour?.usedPercent == 100, "percentage clamp")
        check(RateLimitParser.parse(empty, fetchedAt: fetchedAt) == .notAuthenticated, "unauthenticated response")
    }

    private static func testRendersEightSegmentProgress() {
        check(UsagePresentation.progressBar(for: -1) == "░░░░░░░░", "negative progress")
        check(UsagePresentation.progressBar(for: 47) == "████░░░░", "47 percent progress")
        check(UsagePresentation.progressBar(for: 100) == "████████", "full progress")
        check(UsagePresentation.progressBar(for: .nan) == "░░░░░░░░", "non-finite progress")
    }

    private static func testRendersCountdownBoundaries() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        check(UsagePresentation.countdown(until: now.addingTimeInterval(2 * 3600 + 18 * 60), now: now) == "2\u{2009}h\u{2009}18\u{2009}m\u{2009}后重置", "hour countdown")
        check(UsagePresentation.countdown(until: now.addingTimeInterval(24 * 3600), now: now) == "1\u{2009}d\u{2009}0\u{2009}h\u{2009}后重置", "day boundary")
        check(UsagePresentation.countdown(until: now.addingTimeInterval(2 * 24 * 3600 - 1), now: now) == "2\u{2009}d\u{2009}0\u{2009}h\u{2009}后重置", "day rollover")
        check(UsagePresentation.countdown(until: now.addingTimeInterval(6 * 24 * 3600 + 13 * 3600), now: now) == "6\u{2009}d\u{2009}13\u{2009}h\u{2009}后重置", "multi-day countdown")
        check(UsagePresentation.countdown(until: now, now: now) == "正在重置…", "expired countdown")
    }

    private static func testMapsQuartzToAppKitUsingPrimaryScreenOnly() {
        // A 1440x900 primary display, Codex occupying the usual top-left area.
        let codex = CGRect(x: 0, y: 30, width: 720, height: 778)
        let mapped = PanelPlacement.appKitFrame(quartzFrame: codex, primaryScreenMaxY: 900)
        check(mapped.minY == 92, "primary-only mapping")
        check(mapped.minX == 0 && mapped.width == 720 && mapped.height == 778, "mapping preserves x and size")

        // The regression this guards: an external display arranged above the
        // primary one pushes the tallest screen's maxY to 1800, and the old
        // formula fed that number in. The mapping must not move.
        let wrong = PanelPlacement.appKitFrame(quartzFrame: codex, primaryScreenMaxY: 1800)
        check(wrong.minY == 992, "the stacked-display value really is 900pt off")
        check(mapped.minY != wrong.minY, "primary height, not the tallest screen, drives the mapping")

        let flush = PanelPlacement.appKitFrame(
            quartzFrame: CGRect(x: 100, y: 0, width: 200, height: 100),
            primaryScreenMaxY: 1000
        )
        check(flush.minY == 900, "window flush to the top of the primary screen")
    }

    private static func testRejectsUnreachableSavedPositions() {
        let builtIn = CGRect(x: 0, y: 0, width: 1440, height: 875)
        let external = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        let panel = CGSize(width: 288, height: 64)

        func rect(_ x: CGFloat, _ y: CGFloat) -> CGRect {
            CGRect(origin: CGPoint(x: x, y: y), size: panel)
        }

        check(PanelPlacement.isReachable(rect(400, 300), visibleFrames: [builtIn]), "fully on screen")
        check(PanelPlacement.isReachable(rect(1800, 500), visibleFrames: [builtIn, external]), "on the external display")
        // The external display is unplugged: the same saved origin is now gone.
        check(!PanelPlacement.isReachable(rect(1800, 500), visibleFrames: [builtIn]), "stranded after unplug")
        // Slivers do not count; the reset control sits in the panel's own menu.
        check(!PanelPlacement.isReachable(rect(1430, 300), visibleFrames: [builtIn]), "10pt sliver is unreachable")
        check(PanelPlacement.isReachable(rect(1390, 300), visibleFrames: [builtIn]), "50pt edge is reachable")
        check(!PanelPlacement.isReachable(rect(400, 855), visibleFrames: [builtIn]), "20pt strip under the top edge")
        check(!PanelPlacement.isReachable(rect(400, 300), visibleFrames: []), "no screens at all")
    }

    private static func testEmptyStateWordingDoesNotAssertSignedOut() {
        let missingBucket = UsagePresentation.emptyStateLines(for: .notAuthenticated)
        // A missing bucket can equally mean a renamed field, so the wording
        // must lead with the failure and offer the login as a possibility.
        check(missingBucket.headline == "无法读取额度", "missing-bucket headline states the failure")
        check(missingBucket.detail == "请确认已登录", "missing-bucket detail suggests rather than asserts")
        check(!missingBucket.headline.contains("登录"), "headline does not blame the login")

        check(UsagePresentation.emptyStateLines(for: .connecting) == ("正在连接…", ""), "connecting wording")
        check(UsagePresentation.emptyStateLines(for: .unavailable) == ("无法读取额度", "正在重试…"), "unavailable wording")
        check(UsagePresentation.emptyStateLines(for: .available) == ("等待数据…", ""), "waiting wording")
    }

    private static func testCountdownRowsEndTogetherWithNoInnerGaps() {
        let font = NSFont(name: "Songti SC", size: 12) ?? NSFont.systemFont(ofSize: 12)
        func layout(_ pairs: [(String, String)]) -> UsagePresentation.CountdownLayout {
            UsagePresentation.CountdownLayout(pairs: pairs.map { .init(value: $0.0, unit: $0.1) }, suffix: "后重置")
        }
        func rendered(_ l: UsagePresentation.CountdownLayout, runWidth: CGFloat) -> NSAttributedString {
            CountdownTypesetter.attributedString(for: l, font: font, color: .labelColor, runWidth: runWidth)
        }

        // Pairs the panel can show side by side, including both digit counts.
        let pairsOfRows = [
            (layout([("2", "h"), ("13", "m")]), layout([("6", "d"), ("11", "h")])),
            (layout([("2", "h"), ("5", "m")]), layout([("6", "d"), ("11", "h")])),
            (layout([("4", "h"), ("59", "m")]), layout([("1", "d"), ("0", "h")])),
            (layout([("0", "h"), ("1", "m")]), layout([("6", "d"), ("9", "h")]))
        ]
        for (index, rows) in pairsOfRows.enumerated() {
            let runWidth = max(
                CountdownTypesetter.compactRunWidth(for: rows.0, font: font),
                CountdownTypesetter.compactRunWidth(for: rows.1, font: font)
            )
            let top = rendered(rows.0, runWidth: runWidth).size().width
            let bottom = rendered(rows.1, runWidth: runWidth).size().width
            check(abs(top - bottom) < 0.01, "pair \(index): rows end at \(top) and \(bottom)")
            check(top <= 90, "pair \(index): width \(top) exceeds the 90pt status column")
        }

        // Nothing may sit between a number and its unit, or between the two
        // groups: that gap is what the panel looked wrong with.
        let solid = rendered(pairsOfRows[0].0, runWidth: 40)
        check(solid.string.hasPrefix("2h13m"), "digits and units set solid, got \(solid.string)")
        check(!solid.string.contains(" "), "no ASCII space anywhere in the countdown")
        let narrowSpaces = solid.string.filter { $0 == "\u{2009}" }.count
        check(narrowSpaces == 1, "exactly one narrow space, before 后重置, got \(narrowSpaces)")

        // The pad must ride ahead of 后重置, never widen the run itself.
        let unpadded = rendered(pairsOfRows[0].0, runWidth: 0)
        let padded = rendered(pairsOfRows[0].0, runWidth: 60)
        check(padded.size().width > unpadded.size().width, "runWidth widens the line")
        check(padded.string == unpadded.string, "padding changes no characters")
    }
}

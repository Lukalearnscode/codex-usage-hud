#if canImport(XCTest)
import AppKit
import CoreGraphics
import XCTest
@testable import CodexUsageHUDCore

final class RateLimitCoreTests: XCTestCase {
    private let fetchedAt = Date(timeIntervalSince1970: 1_700_000_000)

    func testParsesPreferredCodexBucketAndBothWindows() throws {
        let json = """
        {"result":{"rateLimits":{"primary":{"usedPercent":99,"windowDurationMins":15,"resetsAt":1700000600}},"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":47,"windowDurationMins":300,"resetsAt":1700008280},"secondary":{"usedPercent":23,"windowDurationMins":10080,"resetsAt":1700563380}}}}}
        """.data(using: .utf8)!

        guard case let .snapshot(snapshot) = RateLimitParser.parse(json, fetchedAt: fetchedAt) else {
            return XCTFail("preferred bucket did not parse")
        }
        XCTAssertEqual(snapshot.fiveHour?.usedPercent, 47)
        XCTAssertEqual(snapshot.weekly?.usedPercent, 23)
        XCTAssertEqual(snapshot.fiveHour?.windowDurationMinutes, 300)
        XCTAssertEqual(snapshot.weekly?.windowDurationMinutes, 10080)
        XCTAssertEqual(snapshot.fetchedAt, fetchedAt)
    }

    func testFallsBackToLegacyBucket() {
        let json = """
        {"result":{"rateLimits":{"primary":{"usedPercent":12,"windowDurationMins":300,"resetsAt":1700000600},"secondary":{"usedPercent":34,"windowDurationMins":10080,"resetsAt":1700563380}}}}
        """.data(using: .utf8)!

        guard case let .snapshot(snapshot) = RateLimitParser.parse(json, fetchedAt: fetchedAt) else {
            return XCTFail("legacy bucket did not parse")
        }
        XCTAssertEqual(snapshot.fiveHour?.usedPercent, 12)
        XCTAssertEqual(snapshot.weekly?.usedPercent, 34)
    }

    func testClampsInvalidPercentAndRecognizesUnauthenticated() {
        let high = """
        {"result":{"rateLimits":{"primary":{"usedPercent":140,"windowDurationMins":300,"resetsAt":1700000600}}}}
        """.data(using: .utf8)!
        let nonFinite = """
        {"result":{"rateLimits":{"primary":{"usedPercent":"nan","windowDurationMins":300,"resetsAt":1700000600}}}}
        """.data(using: .utf8)!
        let empty = #"{"result":{"rateLimits":null}}"#.data(using: .utf8)!

        guard case let .snapshot(snapshot) = RateLimitParser.parse(high, fetchedAt: fetchedAt) else {
            return XCTFail("clamp sample did not parse")
        }
        XCTAssertEqual(snapshot.fiveHour?.usedPercent, 100)
        guard case let .snapshot(nonFiniteSnapshot) = RateLimitParser.parse(nonFinite, fetchedAt: fetchedAt) else {
            return XCTFail("non-finite sample did not parse")
        }
        XCTAssertEqual(nonFiniteSnapshot.fiveHour?.usedPercent, 0)
        XCTAssertEqual(RateLimitParser.parse(empty, fetchedAt: fetchedAt), .notAuthenticated)
    }

    func testRendersEightSegmentProgress() {
        XCTAssertEqual(UsagePresentation.progressBar(for: -1), "░░░░░░░░")
        XCTAssertEqual(UsagePresentation.progressBar(for: 0), "░░░░░░░░")
        XCTAssertEqual(UsagePresentation.progressBar(for: 47), "████░░░░")
        XCTAssertEqual(UsagePresentation.progressBar(for: 50), "████░░░░")
        XCTAssertEqual(UsagePresentation.progressBar(for: 100), "████████")
        XCTAssertEqual(UsagePresentation.progressBar(for: .nan), "░░░░░░░░")
        XCTAssertEqual(UsagePresentation.progressBar(for: 101), "████████")
    }

    func testRendersCountdownBoundaries() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(UsagePresentation.countdown(until: now.addingTimeInterval(2 * 3600 + 18 * 60), now: now), "2\u{2009}h\u{2009}18\u{2009}m\u{2009}后重置")
        XCTAssertEqual(UsagePresentation.countdown(until: now.addingTimeInterval(24 * 3600), now: now), "1\u{2009}d\u{2009}0\u{2009}h\u{2009}后重置")
        XCTAssertEqual(UsagePresentation.countdown(until: now.addingTimeInterval(2 * 24 * 3600 - 1), now: now), "2\u{2009}d\u{2009}0\u{2009}h\u{2009}后重置")
        XCTAssertEqual(UsagePresentation.countdown(until: now.addingTimeInterval(6 * 24 * 3600 + 13 * 3600), now: now), "6\u{2009}d\u{2009}13\u{2009}h\u{2009}后重置")
        XCTAssertEqual(UsagePresentation.countdown(until: now.addingTimeInterval(1), now: now), "1\u{2009}m\u{2009}后重置")
        XCTAssertEqual(UsagePresentation.countdown(until: now, now: now), "正在重置…")
    }

    func testMapsQuartzToAppKitUsingPrimaryScreenOnly() {
        let codex = CGRect(x: 0, y: 30, width: 720, height: 778)
        let mapped = PanelPlacement.appKitFrame(quartzFrame: codex, primaryScreenMaxY: 900)
        XCTAssertEqual(mapped.minY, 92)
        XCTAssertEqual(mapped.minX, 0)
        XCTAssertEqual(mapped.size, CGSize(width: 720, height: 778))

        // An external display arranged above the primary one used to feed 1800
        // in here, moving the HUD by the height of the primary screen.
        let wrong = PanelPlacement.appKitFrame(quartzFrame: codex, primaryScreenMaxY: 1800)
        XCTAssertEqual(wrong.minY, 992)
        XCTAssertNotEqual(mapped.minY, wrong.minY)

        XCTAssertEqual(
            PanelPlacement.appKitFrame(
                quartzFrame: CGRect(x: 100, y: 0, width: 200, height: 100),
                primaryScreenMaxY: 1000
            ).minY,
            900
        )
    }

    func testRejectsUnreachableSavedPositions() {
        let builtIn = CGRect(x: 0, y: 0, width: 1440, height: 875)
        let external = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        let panel = CGSize(width: 288, height: 64)
        func rect(_ x: CGFloat, _ y: CGFloat) -> CGRect {
            CGRect(origin: CGPoint(x: x, y: y), size: panel)
        }

        XCTAssertTrue(PanelPlacement.isReachable(rect(400, 300), visibleFrames: [builtIn]))
        XCTAssertTrue(PanelPlacement.isReachable(rect(1800, 500), visibleFrames: [builtIn, external]))
        XCTAssertFalse(PanelPlacement.isReachable(rect(1800, 500), visibleFrames: [builtIn]))
        XCTAssertFalse(PanelPlacement.isReachable(rect(1430, 300), visibleFrames: [builtIn]))
        XCTAssertTrue(PanelPlacement.isReachable(rect(1390, 300), visibleFrames: [builtIn]))
        XCTAssertFalse(PanelPlacement.isReachable(rect(400, 855), visibleFrames: [builtIn]))
        XCTAssertFalse(PanelPlacement.isReachable(rect(400, 300), visibleFrames: []))
    }

    func testEmptyStateWordingDoesNotAssertSignedOut() {
        let missingBucket = UsagePresentation.emptyStateLines(for: .notAuthenticated)
        XCTAssertEqual(missingBucket.headline, "无法读取额度")
        XCTAssertEqual(missingBucket.detail, "请确认已登录")
        XCTAssertFalse(missingBucket.headline.contains("登录"))

        XCTAssertEqual(UsagePresentation.emptyStateLines(for: .connecting).headline, "正在连接…")
        XCTAssertEqual(UsagePresentation.emptyStateLines(for: .unavailable).detail, "正在重试…")
        XCTAssertEqual(UsagePresentation.emptyStateLines(for: .available).headline, "等待数据…")
    }

    func testCountdownRowsEndTogetherWithNoInnerGaps() {
        let font = NSFont(name: "Songti SC", size: 12) ?? NSFont.systemFont(ofSize: 12)
        func layout(_ pairs: [(String, String)]) -> UsagePresentation.CountdownLayout {
            UsagePresentation.CountdownLayout(pairs: pairs.map { .init(value: $0.0, unit: $0.1) }, suffix: "后重置")
        }
        func rendered(_ l: UsagePresentation.CountdownLayout, runWidth: CGFloat) -> NSAttributedString {
            CountdownTypesetter.attributedString(for: l, font: font, color: .labelColor, runWidth: runWidth)
        }

        let pairsOfRows = [
            (layout([("2", "h"), ("13", "m")]), layout([("6", "d"), ("11", "h")])),
            (layout([("2", "h"), ("5", "m")]), layout([("6", "d"), ("11", "h")])),
            (layout([("4", "h"), ("59", "m")]), layout([("1", "d"), ("0", "h")])),
            (layout([("0", "h"), ("1", "m")]), layout([("6", "d"), ("9", "h")]))
        ]
        for rows in pairsOfRows {
            let runWidth = max(
                CountdownTypesetter.compactRunWidth(for: rows.0, font: font),
                CountdownTypesetter.compactRunWidth(for: rows.1, font: font)
            )
            let top = rendered(rows.0, runWidth: runWidth).size().width
            let bottom = rendered(rows.1, runWidth: runWidth).size().width
            XCTAssertEqual(top, bottom, accuracy: 0.01)
            XCTAssertLessThanOrEqual(top, 90)
        }

        let solid = rendered(pairsOfRows[0].0, runWidth: 40)
        XCTAssertTrue(solid.string.hasPrefix("2h13m"))
        XCTAssertFalse(solid.string.contains(" "))
        XCTAssertEqual(solid.string.filter { $0 == "\u{2009}" }.count, 1)

        // .kern applies to every character in its range, so the pad has to sit
        // on the single narrow space rather than on the run.
        let unpadded = rendered(pairsOfRows[0].0, runWidth: 0)
        let padded = rendered(pairsOfRows[0].0, runWidth: 60)
        XCTAssertGreaterThan(padded.size().width, unpadded.size().width)
        XCTAssertEqual(padded.string, unpadded.string)
    }
}
#else
import Foundation
import CodexUsageHUDCore

// Apple Command Line Tools does not ship XCTest or Swift Testing. The executable
// CodexUsageHUDCoreTests runs the behavioral assertions on that toolchain; this
// fallback keeps `swift test` as a useful SwiftPM compile check there.
enum RateLimitCoreTestsToolchainFallback {
    static let coreTypesCompile = RateLimitSnapshot(fiveHour: nil, weekly: nil, fetchedAt: Date.distantPast)
}
#endif

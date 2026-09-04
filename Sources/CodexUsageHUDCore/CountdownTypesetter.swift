#if canImport(AppKit)
import AppKit

/// Lays the countdown out so the panel's two rows stay in step without putting
/// gaps inside the numbers.
///
/// Songti SC gives every digit the same 5.628pt advance but not the unit
/// letters: m is 9.42pt against 6.38 for h and 6.17 for d. So "2h13m" and
/// "6d11h" are different widths even with identical digit counts, and anything
/// that follows them lands in a different place on each row.
///
/// Padding the letters individually would fix that, but it opens a gap on
/// either side of every letter, which reads worse than the misalignment did.
/// Instead the digits and letters are set solid, and the whole run is padded
/// out to a shared width in the one place a gap is already expected: before
/// 后重置. The two rows then end at the same x with nothing loose inside them.
public enum CountdownTypesetter {
    private static let narrowSpace = "\u{2009}"

    /// Width of the digits and unit letters set solid, with no padding.
    /// The caller measures both rows and feeds the larger back in as `runWidth`
    /// so the shared slot is only ever as wide as it has to be.
    public static func compactRunWidth(
        for layout: UsagePresentation.CountdownLayout,
        font: NSFont
    ) -> CGFloat {
        let run = layout.pairs.map { $0.value + $0.unit }.joined()
        return (run as NSString).size(withAttributes: [.font: font]).width
    }

    public static func attributedString(
        for layout: UsagePresentation.CountdownLayout,
        font: NSFont,
        color: NSColor,
        runWidth: CGFloat = 0
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        func append(_ text: String, kern: CGFloat = 0) {
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            if kern != 0 { attributes[.kern] = kern }
            result.append(NSAttributedString(string: text, attributes: attributes))
        }

        let run = layout.pairs.map { $0.value + $0.unit }.joined()
        if !run.isEmpty {
            append(run)
        }
        if !layout.suffix.isEmpty {
            // A narrow space between Latin and Chinese, none inside 后重置.
            // The pad rides on that single space: .kern applies to every
            // character in its range, so putting it on the multi-character run
            // would multiply it by the character count.
            if !run.isEmpty {
                let pad = max(runWidth - compactRunWidth(for: layout, font: font), 0)
                append(narrowSpace, kern: pad)
            }
            append(layout.suffix)
        }
        return result
    }
}
#endif

import CoreText
import Foundation

/// Total widths cannot tell Georgia from the system font; character positions can.
enum FontMatcher {
    static let systemFamily = ".AppleSystemUIFont"

    /// Families web pages commonly name that ship with macOS. Fonts in one group look alike, so a close call
    /// between them does not matter.
    static let groups: [[String]] = [
        [systemFamily],
        ["Helvetica", "Arial", "Helvetica Neue"],
        ["Times", "Times New Roman"],
        ["Georgia"],
        ["Verdana"],
        ["Trebuchet MS"],
        ["Menlo", "SF Mono", "Courier New"],
    ]

    /// RMS distance in points. Apps report positions rounded to whole points, about 0.4 off on average.
    static let maxError: CGFloat = 0.8
    static let minLead: CGFloat = 0.4
    static let minSample = 12

    static func family(sample: String, positions: [CGFloat], size: CGFloat, bold: Bool, italic: Bool) -> String? {
        guard sample.count >= minSample, positions.count == sample.count + 1 else { return nil }
        let errors = groups.joined().compactMap { family -> (family: String, error: CGFloat)? in
            guard let font = font(family, size: size, bold: bold, italic: italic) else { return nil }
            let differences = zip(offsets(sample, font: font), positions).map { $0 - $1 }
            // Rounding the first position shifts all the others alike: the mean difference is taken out.
            let shift = differences.reduce(0, +) / CGFloat(differences.count)
            let squares = differences.map { ($0 - shift) * ($0 - shift) }
            return (family, (squares.reduce(0, +) / CGFloat(squares.count)).squareRoot())
        }
        return choose(errors)
    }

    static func choose(_ errors: [(family: String, error: CGFloat)]) -> String? {
        guard let best = errors.min(by: { $0.error < $1.error }), best.error <= maxError else { return nil }
        let group = groups.first { $0.contains(best.family) } ?? [best.family]
        let rival = errors.filter { !group.contains($0.family) }.map(\.error).min() ?? .infinity
        guard rival - best.error >= minLead, best.family != systemFamily else { return nil }
        return best.family
    }

    static func font(_ family: String, size: CGFloat, bold: Bool, italic: Bool) -> CTFont? {
        let base: CTFont
        if family == systemFamily {
            guard let system = CTFontCreateUIFontForLanguage(.system, size, nil) else { return nil }
            base = system
        } else {
            let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: family] as CFDictionary)
            base = CTFontCreateWithFontDescriptor(descriptor, size, nil)
            // CoreText substitutes another font for a missing family.
            guard CTFontCopyFamilyName(base) as String == family else { return nil }
        }
        var traits: CTFontSymbolicTraits = []
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        guard !traits.isEmpty else { return base }
        return CTFontCreateCopyWithSymbolicTraits(base, 0, nil, traits, traits) ?? base
    }

    static func offsets(_ text: String, font: CTFont) -> [CGFloat] {
        let string = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        let line = CTLineCreateWithAttributedString(string)
        var index = 0
        var result: [CGFloat] = []
        for character in text {
            result.append(CTLineGetOffsetForStringIndex(line, index, nil))
            index += character.utf16.count
        }
        result.append(CTLineGetOffsetForStringIndex(line, index, nil))
        return result
    }
}

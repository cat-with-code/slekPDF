import CoreGraphics
import Foundation

/// Rebuilds readable Khmer from PDFium's per-character data for copy and search.
///
/// Many PDFs store Khmer glyphs in drawing order (docs/spikes/01): pre-base vowels (េ ែ ៃ) and the subscript
/// ្រ are drawn left of their consonant, some vowels are drawn after the next consonant, ligature glyphs are
/// reported twice, and PDFium inserts line breaks when a mark sits higher than its letter. This rebuilder:
/// 1. drops PDFium's generated line breaks between characters on the same baseline (real line changes become "\n");
///    generated spaces are kept — they are often real phrase spaces (Chrome-made PDFs have no space glyphs);
/// 2. drops a glyph that repeats the identical characters of an overlapping earlier glyph;
/// 3. attaches stand-alone marks to the consonant they are drawn on, and stand-alone pre-base vowels / ្រ to the
///    consonant drawn to their right;
/// 4. puts only the syllables it changed into Unicode order (consonant, subscripts with ្រ last, shifters, vowel,
///    signs) and merges split vowels (េ + ា → ោ, េ + ី → ើ, េ + ៀ → ៀ …).
/// Invisible text (render mode 3) is passed through unchanged: it is already in reading order.
nonisolated enum KhmerTextRebuilder {
    struct Result: Equatable {
        /// The rebuilt text.
        let text: String
        /// For each Unicode scalar of `text`, the PDFium character index it came from (nil for inserted "\n").
        let sources: [Int?]
    }

    static func rebuild(_ chars: [PDFiumChar]) -> Result {
        let lines = splitIntoLines(chars)
        var scalars: [Unicode.Scalar] = []
        var sources: [Int?] = []
        for (number, line) in lines.enumerated() {
            if number > 0 {
                scalars.append("\n")
                sources.append(nil)
            }
            for char in rebuildLine(line) {
                scalars.append(char.scalar)
                sources.append(char.index)
            }
        }
        var text = ""
        text.unicodeScalars.append(contentsOf: scalars)
        return Result(text: text, sources: sources)
    }

    // MARK: - Lines

    private static func splitIntoLines(_ chars: [PDFiumChar]) -> [[PDFiumChar]] {
        var lines: [[PDFiumChar]] = []
        var current: [PDFiumChar] = []
        var baseline: CGFloat?
        var pendingBreak = false
        for char in chars {
            if char.isGenerated, char.scalar == "\r" || char.scalar == "\n" {
                pendingBreak = true
                continue
            }
            let tolerance = max(char.fontSize, Double(char.box.height), 4) * 0.5
            let newLine = baseline.map { abs($0 - char.origin.y) > tolerance } ?? false
            // A real line change: baseline moved. A generated break on the same baseline is dropped.
            if newLine || (pendingBreak && !char.isGenerated && baseline.map { abs($0 - char.origin.y) > tolerance } == true) {
                if !current.isEmpty { lines.append(current) }
                current = []
            }
            pendingBreak = false
            if !char.isGenerated || char.scalar == " " {
                if !char.isGenerated { baseline = char.origin.y }
                current.append(char)
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines.map(trimSpaces)
    }

    private static func trimSpaces(_ line: [PDFiumChar]) -> [PDFiumChar] {
        var line = line
        while line.first?.scalar == " " { line.removeFirst() }
        while line.last?.scalar == " " { line.removeLast() }
        // No space directly before a Khmer mark (PDFium sometimes generates one) — except េ ែ ៃ, which are
        // drawn first and start their syllable, so a space before them is real.
        return line.enumerated().filter { offset, char in
            guard char.isGenerated, char.scalar == " ", offset + 1 < line.count else { return true }
            let next = line[offset + 1].scalar
            return !Khmer.isMark(next) || Khmer.isPreBaseVowel(next)
        }.map(\.element)
    }

    // MARK: - Glyph groups and syllables

    /// One drawn glyph: PDFium reports several characters with the same origin for a ligature glyph.
    private struct Glyph {
        var chars: [PDFiumChar]
        var box: CGRect { chars.dropFirst().reduce(chars[0].box) { $0.union($1.box) } }
        var text: [Unicode.Scalar] { chars.map(\.scalar) }
        var isInvisible: Bool { chars.contains { $0.isInvisible } }
        var startsWithBase: Bool { Khmer.isBase(chars[0].scalar) }
        var isMarkOnly: Bool { chars.allSatisfy { Khmer.isMark($0.scalar) || ($0.scalar != chars[0].scalar && Khmer.isBase($0.scalar)) } && Khmer.isMark(chars[0].scalar) }
        /// Drawn to the left of the consonant it belongs to: pre-base vowels and the subscript ្រ.
        var isPreBase: Bool {
            let s = text
            if s.allSatisfy(Khmer.isPreBaseVowel) { return true }
            return s.count == 2 && s[0] == Khmer.coeng && s[1] == Khmer.ro
                || s.count == 3 && Khmer.isPreBaseVowel(s[0]) && s[1] == Khmer.coeng && s[2] == Khmer.ro
        }
    }

    private static func glyphs(in line: [PDFiumChar]) -> [Glyph] {
        var glyphs: [Glyph] = []
        for char in line {
            if let last = glyphs.last?.chars.last, !char.isGenerated, !last.isGenerated,
               abs(last.origin.x - char.origin.x) < 0.05, abs(last.origin.y - char.origin.y) < 0.05 {
                glyphs[glyphs.count - 1].chars.append(char)
            } else {
                glyphs.append(Glyph(chars: [char]))
            }
        }
        return glyphs
    }

    private static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let width = min(a.maxX, b.maxX) - max(a.minX, b.minX)
        return max(0, width) / max(min(a.width, b.width), 0.01)
    }

    private struct Syllable {
        var chars: [PDFiumChar]
        var box: CGRect
        var changed = false
    }

    private static func rebuildLine(_ line: [PDFiumChar]) -> [PDFiumChar] {
        var all = glyphs(in: line)

        // Duplicate ligature glyphs: identical characters drawn over an earlier glyph.
        // Same characters as a recent glyph, drawn on it or between it and the following glyph (e.g. the
        // ូ under ត្រ reported again as "ត្រូ"). A genuinely repeated syllable is drawn further right and stays.
        var kept: [Glyph] = []
        for glyph in all {
            var isDuplicate = false
            if glyph.text.count > 1, !glyph.isInvisible {
                for offset in kept.indices.suffix(4) where kept[offset].text == glyph.text {
                    let following = kept[(offset + 1)...].first { !$0.chars.allSatisfy(\.isGenerated) }
                    let reach = following.map { max($0.box.maxX, kept[offset].box.maxX) } ?? kept[offset].box.maxX
                    if overlap(kept[offset].box, glyph.box) > 0.5 || (kept[offset].box.minX...reach).contains(glyph.box.midX) {
                        isDuplicate = true
                    }
                }
            }
            if !isDuplicate { kept.append(glyph) }
        }
        all = kept

        var syllables: [Syllable] = []
        var pendingPreBase: [Glyph] = []
        for glyph in all {
            let khmer = glyph.chars.contains { Khmer.isKhmer($0.scalar) }
            if glyph.isInvisible || !khmer {
                flush(&pendingPreBase, into: &syllables)
                syllables.append(Syllable(chars: glyph.chars, box: glyph.box))
            } else if glyph.isPreBase {
                // Belongs to the consonant drawn to its right: hold until that consonant arrives.
                pendingPreBase.append(glyph)
            } else if glyph.isMarkOnly {
                // Attach to the syllable it is drawn on (by geometry), else the previous one.
                let center = glyph.box.midX
                let target = syllables.indices.suffix(4).last { index in
                    let box = syllables[index].box
                    return box.minX - 0.5 <= center && center <= box.maxX + 0.5 && syllables[index].chars.contains { Khmer.isBase($0.scalar) }
                } ?? syllables.indices.last
                if let target {
                    syllables[target].chars += glyph.chars
                    syllables[target].box = syllables[target].box.union(glyph.box)
                    syllables[target].changed = true
                } else {
                    syllables.append(Syllable(chars: glyph.chars, box: glyph.box))
                }
            } else {
                var syllable = Syllable(chars: glyph.chars, box: glyph.box)
                if glyph.startsWithBase, !pendingPreBase.isEmpty {
                    syllable.chars += pendingPreBase.flatMap(\.chars)
                    syllable.changed = true
                    pendingPreBase = []
                }
                syllables.append(syllable)
            }
        }
        flush(&pendingPreBase, into: &syllables)
        return syllables.flatMap { $0.changed ? reorder($0.chars) : $0.chars }
    }

    private static func flush(_ pending: inout [Glyph], into syllables: inout [Syllable]) {
        for glyph in pending { syllables.append(Syllable(chars: glyph.chars, box: glyph.box)) }
        pending = []
    }

    /// Unicode order for a syllable this rebuilder changed: base(s), subscripts (្រ last), shifters/robat,
    /// vowels, signs; then merge split vowels.
    private static func reorder(_ chars: [PDFiumChar]) -> [PDFiumChar] {
        var bases: [PDFiumChar] = [], subscripts: [[PDFiumChar]] = [], roSubscript: [PDFiumChar] = []
        var shifters: [PDFiumChar] = [], vowels: [PDFiumChar] = [], signs: [PDFiumChar] = [], other: [PDFiumChar] = []
        var index = 0
        while index < chars.count {
            let c = chars[index]
            if c.scalar == Khmer.coeng, index + 1 < chars.count, Khmer.isBase(chars[index + 1].scalar) {
                let pair = [c, chars[index + 1]]
                if chars[index + 1].scalar == Khmer.ro { roSubscript = pair } else { subscripts.append(pair) }
                index += 2
                continue
            }
            switch c.scalar.value {
            case _ where Khmer.isBase(c.scalar) && bases.isEmpty: bases.append(c)
            case 0x17C9, 0x17CA, 0x17CC: shifters.append(c)
            case 0x17B6...0x17C5: vowels.append(c)
            case 0x17C6...0x17D1, 0x17D3, 0x17DD: signs.append(c)
            default: other.append(c)
            }
            index += 1
        }
        vowels = mergeSplitVowels(vowels)
        return bases + subscripts.flatMap { $0 } + roSubscript + shifters + vowels + signs + other
    }

    /// េ drawn separately plus the right part reported as a full vowel: keep one vowel.
    private static func mergeSplitVowels(_ vowels: [PDFiumChar]) -> [PDFiumChar] {
        guard let e = vowels.firstIndex(where: { $0.scalar == "\u{17C1}" }), vowels.count > 1 else { return vowels }
        var rest = vowels
        let left = rest.remove(at: e)
        guard let partner = rest.firstIndex(where: { [0x17B6, 0x17B8, 0x17BE, 0x17BF, 0x17C0, 0x17C4, 0x17C5].contains($0.scalar.value) }) else { return vowels }
        let merged: Unicode.Scalar? = switch rest[partner].scalar.value {
        case 0x17B6: "\u{17C4}"  // េ + ា → ោ
        case 0x17B8: "\u{17BE}"  // េ + ី → ើ
        default: nil              // ើ ឿ ៀ ោ ៅ already include េ
        }
        if let merged {
            rest[partner] = PDFiumChar(index: left.index, scalar: merged, isGenerated: false, isInvisible: false,
                                       origin: left.origin, box: left.box.union(rest[partner].box), fontSize: left.fontSize)
        }
        return rest
    }
}

nonisolated enum Khmer {
    static let coeng: Unicode.Scalar = "\u{17D2}"
    static let ro: Unicode.Scalar = "\u{179A}"
    static func isKhmer(_ s: Unicode.Scalar) -> Bool { (0x1780...0x17FF).contains(s.value) || (0x19E0...0x19FF).contains(s.value) }
    /// Consonants and independent vowels.
    static func isBase(_ s: Unicode.Scalar) -> Bool { (0x1780...0x17B3).contains(s.value) }
    static func isPreBaseVowel(_ s: Unicode.Scalar) -> Bool { (0x17C1...0x17C3).contains(s.value) }
    /// Dependent vowels, signs and coeng: never start a syllable.
    static func isMark(_ s: Unicode.Scalar) -> Bool { (0x17B6...0x17D3).contains(s.value) || s.value == 0x17DD }
}

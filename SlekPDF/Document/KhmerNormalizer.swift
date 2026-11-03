import Foundation

/// Puts Khmer text into standard Unicode order so it renders, copies and pastes correctly everywhere.
///
/// OCR engines and many PDFs produce Khmer whose characters are out of order (a vowel before a subscript, ្រ before
/// another subscript, េ + ា instead of ោ, doubled vowels…). It may look right on the page, but other apps then draw
/// dotted circles and broken words. This is a Swift port of the Khmer parts of khmernormalizer
/// (github.com/seanghay/khmernormalizer, MIT) — its core, `khnormal.py`, is SIL International's Khmer normaliser
/// (MIT; github.com/sillsdev/khmer-character-specification). Left out on purpose: stripping accents from Latin letters,
/// quote/emoji/URL rewriting and spelling “corrections”, which would change a document's text; and “។ល។” → ៘ (Unicode
/// discourages U+17D8).
nonisolated enum KhmerNormalizer {
    /// Normalises text for copy, export and OCR output. Text without Khmer is only NFC-normalised.
    static func normalize(_ text: String) -> String {
        var text = text.precomposedStringWithCanonicalMapping
        guard text.unicodeScalars.contains(where: { (0x1780...0x17FF).contains($0.value) }) else { return text }
        for (pattern, template) in cleanups { text = replace(pattern, template, in: text) }
        return reorder(text)
    }

    /// Deprecated characters, duplicates and stray spaces (before syllable reordering).
    private static let cleanups: [(String, String)] = [
        (#"[​﻿឴឵]"#, ""),                // zero-width space, BOM, deprecated invisible vowels
        (#"ឣ"#, "\u{17A2}"),                           // ឣ → អ
        (#"ឤ"#, "\u{17A2}\u{17B6}"),                   // ឤ → អា
        (#"៓"#, "\u{17C6}"),                           // deprecated BATHAMASAT → nikahit
        (#"([ា-៑៓៝])\1+"#, "$1"),       // a vowel or sign typed twice
        (#"(្[ក-ឳ])\1+"#, "$1"),             // a subscript typed twice
        (#"([។៕៖])\1+"#, "$1"),              // ។។ ៕៕ ៖៖
        (#"[^\S\r\n]+([។៕៖ៗ])"#, "$1"), // no space before ។ ៕ ៖ ៗ
        (#"[^\S\r\n]{2,}"#, " "),                           // repeated spaces (not line breaks)
    ]

    // MARK: SIL khnormal (syllable reordering)

    private enum Category: Int {
        case other = 0, base, coeng, zfCoeng, robat, shift, z, vPre, vB, vA, vPost, ms, mf
    }

    /// Categories of U+1780…U+17DD, as khnormal.py.
    private static let categories: [Category] = {
        var list = [Category](repeating: .base, count: 35)              // 1780-17A2
        list += [Category](repeating: .other, count: 2)                 // 17A3-17A4
        list += [Category](repeating: .base, count: 15)                 // 17A5-17B3
        list += [Category](repeating: .other, count: 2)                 // 17B4-17B5
        list += [.vPost]                                                // 17B6
        list += [Category](repeating: .vA, count: 4)                    // 17B7-17BA
        list += [Category](repeating: .vB, count: 3)                    // 17BB-17BD
        list += [Category](repeating: .vPre, count: 8)                  // 17BE-17C5
        list += [.ms]                                                   // 17C6
        list += [Category](repeating: .mf, count: 2)                    // 17C7-17C8
        list += [Category](repeating: .shift, count: 2)                 // 17C9-17CA
        list += [.ms, .robat]                                           // 17CB, 17CC
        list += [Category](repeating: .ms, count: 5)                    // 17CD-17D1
        list += [.coeng, .ms]                                           // 17D2, 17D3
        list += [Category](repeating: .other, count: 9)                 // 17D4-17DC
        list += [.ms]                                                   // 17DD
        return list
    }()

    private static func category(_ scalar: Unicode.Scalar) -> Category {
        switch scalar.value {
        case 0x1780...0x17DD: categories[Int(scalar.value - 0x1780)]
        case 0x200C: .z
        case 0x200D: .zfCoeng
        default: .other
        }
    }

    /// Fixes inside one sorted syllable (khnormal.py, in order).
    private static let syllableFixes: [(String, String)] = [
        (#"([‌‍]្?|្‍)[្‌‍]+"#, "$1"),  // multiple invisible characters
        (#"េ([ុ-ួ]?)ី"#, "\u{17BE}$1"),                    // េ + ី → ើ
        (#"េ([ុ-ួ]?)ា"#, "\u{17C4}$1"),                    // េ + ា → ោ
        (#"(ើ)(ុ)"#, "$2$1"),
        // ុ before an upper vowel → the consonant shifter (series 1 → ៊, series 2 → ៉)
        (#"([ក-ឃច-ឈដ-ឍត-ធផ-ភឞ-ហអ]៌?(?:្[ក-នផ-អឥ-ឳ](?:្[ក-នផ-អឥ-ឳ])?)?|[ក-នផ-អឥ-ឳ]៌?(?:្[ក-ឃច-ឈដ-ឍត-ធផ-ភឞ-ហអ](?:្[ក-នផ-អឥ-ឳ])?|្[ក-នផ-អឥ-ឳ]្[ក-ឃច-ឈដ-ឍត-ធផ-ភឞ-ហអ])(?:្‍[ក-យល-អឥ-ឳ])?[េ-ៅ]?)ុ(?=(?:[ិ-ឺើឿ៝]|ាំ)|័)"#,
         "$1\u{17CA}"),
        (#"((?:[ងកណនបម-ឝឡឣ-ឳ]៌?(?:្[ងកណនបម-ឝឡឣ-ឳ](?:្[ងកណនបម-ឝឡឣ-ឳ])?)?|ប៌?(?:(?:្[ក-យល-អឥ-ឳ])?្[ក-អឥ-ឳ◌])?|[ក-អឥ-ឳ◌]៌?(?:្[ក-យល-អឥ-ឳ]្ប|្ប(?:្[ក-អឥ-ឳ◌]))?)(?:្‍[ក-យល-អឥ-ឳ])?[េ-ៅ]?)ុ(?=(?:[ិ-ឺើឿ៝]|ាំ)|័)"#,
         "$1\u{17C9}"),
        (#"(្រ)(្[ក-ឳ])"#, "$2$1"),  // subscript ro last
        (#"(្)ដ"#, "$1\u{178F}"),                  // subscript da → ta
    ]

    /// SIL khnormal: within each syllable (a base and the marks after it) sort characters by category, then apply
    /// the syllable fixes.
    static func reorder(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var cats = scalars.map(category)
        for i in scalars.indices.dropFirst() where (scalars[i - 1].value == 0x17D2 || scalars[i - 1].value == 0x200D)
            && (cats[i] == .base || cats[i] == .zfCoeng) {
            cats[i] = .coeng
        }
        var result = String.UnicodeScalarView()
        var i = 0
        while i < scalars.count {
            guard cats[i] == .base else {
                result.append(scalars[i])
                i += 1
                continue
            }
            var j = i + 1
            while j < scalars.count, cats[j].rawValue > Category.base.rawValue { j += 1 }
            let order = (i..<j).sorted { (cats[$0].rawValue, $0) < (cats[$1].rawValue, $1) }
            var syllable = String(String.UnicodeScalarView(order.map { scalars[$0] }))
            for (pattern, template) in syllableFixes { syllable = replace(pattern, template, in: syllable) }
            result.append(contentsOf: syllable.unicodeScalars)
            i = j
        }
        return String(result)
    }

    // MARK: Regex

    private static let compiled: [String: NSRegularExpression] = {
        var all: [String: NSRegularExpression] = [:]
        for (pattern, _) in cleanups + syllableFixes { all[pattern] = try! NSRegularExpression(pattern: pattern) }
        return all
    }()

    private static func replace(_ pattern: String, _ template: String, in text: String) -> String {
        guard let regex = compiled[pattern] else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }
}

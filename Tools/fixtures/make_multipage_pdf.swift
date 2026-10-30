// Three-page A4 Khmer fixture for navigation, thumbnails and search (Core Text).
// Usage: swift Tools/fixtures/make_multipage_pdf.swift <fonts dir> <out.pdf> [crop]
// With "crop", every page gets a crop box offset from the media box (tests coordinate mapping).
import AppKit
import CoreText

let args = CommandLine.arguments
for file in try FileManager.default.contentsOfDirectory(atPath: args[1]) where file.hasSuffix(".ttf") {
    CTFontManagerRegisterFontsForURL(URL(fileURLWithPath: args[1]).appendingPathComponent(file) as CFURL, .process, nil)
}
let pages: [[String]] = [
    ["ទំព័រទី ១ · Khmer / English document", "សាលារៀនបឋមសិក្សា ភូមិថ្មី", "ឯកសារនេះត្រូវបានពិនិត្យរួចហើយ", "ឈ្មោះ សាលារៀន បឋមសិក្សា"],
    ["ទំព័រទី ២ · Report", "សាលារៀន ក្រសួងអប់រំ យុវជន និងកីឡា", "ស្ត្រី ក្រសួង ព្រះរាជាណាចក្រកម្ពុជា", "ឈ្មោះ សាលារៀន ទី ២"],
    ["ទំព័រទី ៣ · Invoice", "Invoice លេខ INV-0042 តម្លៃ 12,500 ៛", "លេខ ០១២៣៤៥៦៧៨៩ · ថ្ងៃទី ៣០ ខែតុលា ឆ្នាំ ២០២៦", "សាលារៀន ភូមិថ្មី"],
]
var mediaBox = CGRect(x: 0, y: 0, width: 595, height: 842)
let context = CGContext(URL(fileURLWithPath: args[2]) as CFURL, mediaBox: &mediaBox, nil)!
let font = NSFont(name: "NotoSansKhmer-Regular", size: 14)!
let crop = args.count > 3 && args[3] == "crop"
for lines in pages {
    if crop {
        var box = CGRect(x: 30, y: 60, width: 520, height: 740)
        let data = Data(bytes: &box, count: MemoryLayout<CGRect>.size) as CFData
        context.beginPDFPage([kCGPDFContextCropBox as String: data] as CFDictionary)
    } else {
        context.beginPDFPage(nil)
    }
    var y: CGFloat = 770
    for line in lines {
        context.textPosition = CGPoint(x: 60, y: y)
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: line, attributes: [.font: font])), context)
        y -= 34
    }
    context.endPDFPage()
}
context.closePDF()
print("wrote \(args[2])")

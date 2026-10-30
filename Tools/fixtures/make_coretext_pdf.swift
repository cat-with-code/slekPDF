// Generates a one-page A4 Khmer/English PDF with Core Text (Apple's text stack).
// Usage: swift Tools/fixtures/make_coretext_pdf.swift <lines.json> <fonts dir> <out.pdf>
import AppKit
import CoreText

let args = CommandLine.arguments
let lines = try JSONDecoder().decode([String].self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
for file in try FileManager.default.contentsOfDirectory(atPath: args[2]) where file.hasSuffix(".ttf") {
    CTFontManagerRegisterFontsForURL(URL(fileURLWithPath: args[2]).appendingPathComponent(file) as CFURL, .process, nil)
}

var mediaBox = CGRect(x: 0, y: 0, width: 595, height: 842)
let context = CGContext(URL(fileURLWithPath: args[3]) as CFURL, mediaBox: &mediaBox,
                        [kCGPDFContextTitle: "Khmer sample (Core Text)"] as CFDictionary)!
context.beginPDFPage(nil)
let font = NSFont(name: "NotoSansKhmer-Regular", size: 14)!
var y: CGFloat = 770
for line in lines {
    let attributed = NSAttributedString(string: line, attributes: [.font: font, .foregroundColor: NSColor.black])
    let ctLine = CTLineCreateWithAttributedString(attributed)
    context.textPosition = CGPoint(x: 60, y: y)
    CTLineDraw(ctLine, context)
    y -= 34
}
context.endPDFPage()
context.closePDF()
print("wrote \(args[3])")

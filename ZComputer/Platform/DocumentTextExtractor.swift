import Foundation
import PDFKit
import UniformTypeIdentifiers
import ZCore

/// Plain text out of the files the Library imports: txt / md (and other text) directly, PDF through PDFKit.
enum DocumentTextExtractor {
    /// File types the import panel offers.
    static var importableTypes: [UTType] {
        var types: [UTType] = [.plainText, .utf8PlainText, .text, .pdf]
        if let markdown = UTType(filenameExtension: "md") { types.append(markdown) }
        if let markdown = UTType("net.daringfireball.markdown") { types.append(markdown) }
        return types
    }

    /// Reads `url` (call with security-scoped access already started). Throws when nothing readable is inside.
    static func extractText(from url: URL) throws -> String {
        let isPDF = url.pathExtension.lowercased() == "pdf"
            || (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType?.conforms(to: .pdf)) == true
        let text: String
        if isPDF {
            guard let document = PDFDocument(url: url) else {
                throw ZError.decoding("\(url.lastPathComponent) is not a readable PDF")
            }
            var pages: [String] = []
            for index in 0..<document.pageCount {
                if let page = document.page(at: index), let pageText = page.string, !pageText.isEmpty {
                    pages.append(pageText)
                }
            }
            text = pages.joined(separator: "\n\n")
        } else {
            let data = try Data(contentsOf: url)
            if let utf8 = String(data: data, encoding: .utf8) {
                text = utf8
            } else if let latin1 = String(data: data, encoding: .isoLatin1) {
                text = latin1
            } else {
                throw ZError.decoding("\(url.lastPathComponent) is not a text file")
            }
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ZError.decoding("\(url.lastPathComponent) has no extractable text (a scanned PDF needs OCR first)")
        }
        return trimmed
    }

    /// A title from the file name (without the extension).
    static func title(for url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
        return name.isEmpty ? url.lastPathComponent : name
    }
}

import Foundation
import PDFKit

/// PDF metadata: title and authors only, plus the page count on read.
enum PDFIO {
    /// Fields a PDF is not used to hold.
    static let unstorable: Set<MetadataField> =
        Set(MetadataField.allCases).subtracting([.title, .authors, .cover])

    static func read(_ url: URL) throws -> FileContents {
        guard let doc = PDFDocument(url: url) else {
            throw MetadataIOError.unreadable(url.lastPathComponent)
        }
        // A locked document reports its page count but has no attributes.
        let attributes = doc.documentAttributes ?? [:]
        func text(_ key: PDFDocumentAttribute) -> String? {
            (attributes[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        var metadata = BookMetadata(
            title: text(.titleAttribute) ?? "",
            authors: NameList.split(text(.authorAttribute)))
        metadata.pageCount = doc.pageCount
        return FileContents(metadata: metadata)
    }

    /// PDFKit cannot patch metadata in place: the whole document is re-serialised
    /// into a copy, which is checked and then swapped in.
    ///
    /// Authors are stored joined in the one author field. Names are trimmed and blank ones
    /// dropped; a name that itself contains ";" will read back as several.
    @discardableResult
    static func write(_ metadata: BookMetadata, cover: CoverChange, to url: URL) throws -> WriteReport {
        let name = url.lastPathComponent
        guard let doc = PDFDocument(url: url) else { throw MetadataIOError.unreadable(name) }
        // A password-protected file, or one its owner restricted, is not ours to re-save.
        guard !doc.isLocked, !doc.isEncrypted else { throw MetadataIOError.locked(name) }
        let pagesBefore = doc.pageCount
        let title = metadata.title.isEmpty ? nil : metadata.title
        // Blank names are dropped and the rest trimmed, so no empty author string is stored.
        let names = metadata.authors.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let author = NameList.join(names)
        // All authors share one text field, so a name containing ";" (or a lone "A B, C D") comes
        // back split. That is what a later read will report, and what the check must expect.
        let authorsAsReadBack = NameList.split(author)

        var attributes = doc.documentAttributes ?? [:]
        attributes[PDFDocumentAttribute.titleAttribute] = title
        attributes[PDFDocumentAttribute.authorAttribute] = author
        doc.documentAttributes = attributes

        try SafeFileUpdate.update(url) { copy in
            // Straight into the working copy, which is beside the file. (PDFKit's own
            // `write(to:)` goes by way of the system's temporary folder, and leaves a
            // whole copy of the document there when that folder is on another disk.)
            guard let data = doc.dataRepresentation() else { throw MetadataIOError.unreadable(name) }
            try data.write(to: copy)
        } verify: { copy in
            let check = try read(copy)
            guard check.metadata.pageCount == pagesBefore,
                  check.metadata.title == (title ?? ""),
                  check.metadata.authors == authorsAsReadBack
            else { throw MetadataIOError.verificationFailed("PDF did not re-read as written") }
        }
        return WriteReport(notWritten: cover == .keep ? unstorable : unstorable.union([.cover]))
    }
}

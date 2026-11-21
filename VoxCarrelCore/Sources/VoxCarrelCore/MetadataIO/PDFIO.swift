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
    @discardableResult
    static func write(_ metadata: BookMetadata, cover: CoverChange, to url: URL) throws -> WriteReport {
        let name = url.lastPathComponent
        guard let doc = PDFDocument(url: url) else { throw MetadataIOError.unreadable(name) }
        // A password-protected file, or one its owner restricted, is not ours to re-save.
        guard !doc.isLocked, !doc.isEncrypted else { throw MetadataIOError.locked(name) }
        let pagesBefore = doc.pageCount
        let title = metadata.title.isEmpty ? nil : metadata.title
        let author = NameList.join(metadata.authors)

        var attributes = doc.documentAttributes ?? [:]
        attributes[PDFDocumentAttribute.titleAttribute] = title
        attributes[PDFDocumentAttribute.authorAttribute] = author
        doc.documentAttributes = attributes

        try SafeFileUpdate.update(url) { copy in
            guard doc.write(to: copy) else { throw MetadataIOError.unreadable(name) }
        } verify: { copy in
            let check = try read(copy)
            guard check.metadata.pageCount == pagesBefore,
                  check.metadata.title == (title ?? ""),
                  check.metadata.authors == metadata.authors
            else { throw MetadataIOError.verificationFailed("PDF did not re-read as written") }
        }
        return WriteReport(notWritten: cover == .keep ? unstorable : unstorable.union([.cover]))
    }
}

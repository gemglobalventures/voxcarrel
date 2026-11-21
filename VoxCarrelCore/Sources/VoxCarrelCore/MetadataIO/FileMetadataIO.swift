import Foundation

/// Reads and writes metadata inside book files, choosing the right module by
/// file extension. The only metadata entry point the rest of VoxCarrel uses.
///
/// Calls block while they work and a first write to a large audiobook can take
/// seconds, so call from a background task, never the main actor.
public struct FileMetadataIO: MetadataReader {
    public init() {}

    /// The fields a format can hold inside the file. Everything else stays in the
    /// app database and is shown as "saved in app only".
    public static func storableFields(for format: FileFormat) -> Set<MetadataField> {
        let all = Set(MetadataField.allCases)
        switch format {
        case .m4b, .m4a, .mp3: return all
        case .epub: return all.subtracting(EpubIO.unstorable)
        case .pdf: return all.subtracting(PDFIO.unstorable).subtracting([.cover])
        case .mobi, .azw3: return []
        }
    }

    /// Metadata, cover and chapters from one file. MOBI and AZW3 are not opened
    /// and give empty contents.
    public func read(_ url: URL) throws -> FileContents {
        switch try format(of: url) {
        case .m4b, .m4a, .mp3: return try AudioTagIO.read(url)
        case .epub: return try EpubIO.read(url)
        case .pdf: return try PDFIO.read(url)
        case .mobi, .azw3: return FileContents()
        }
    }

    public func readMetadata(at url: URL) throws -> BookMetadata {
        try read(url).metadata
    }

    /// Writes what the file's format can hold, never editing the original in place.
    /// - Parameter part: For one file of a multi-part audiobook; ignored for ebooks.
    /// - Returns: The fields that could not be stored in this file.
    @discardableResult
    public func write(
        _ metadata: BookMetadata, cover: CoverChange = .keep, part: PartPosition? = nil, to url: URL
    ) throws -> WriteReport {
        switch try format(of: url) {
        case .m4b, .m4a, .mp3:
            return try AudioTagIO.write(metadata, cover: cover, part: part, to: url)
        case .epub:
            return try EpubIO.write(metadata, cover: cover, to: url)
        case .pdf:
            return try PDFIO.write(metadata, cover: cover, to: url)
        case .mobi, .azw3:
            let fields = Set(MetadataField.allCases)
            return WriteReport(notWritten: cover == .keep ? fields.subtracting([.cover]) : fields)
        }
    }

    private func format(of url: URL) throws -> FileFormat {
        guard let format = FileFormat(url: url) else {
            throw MetadataIOError.unsupportedFormat(url.pathExtension.lowercased())
        }
        return format
    }
}

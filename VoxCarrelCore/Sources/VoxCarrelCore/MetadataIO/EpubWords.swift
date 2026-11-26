import Foundation
import ZIPFoundation

/// Counting the words of a book's text.
public enum WordCount {
    /// The words a page is taken to hold when pages are worked out from words: a
    /// printed page of a novel holds about so many.
    public static let wordsPerPage = 300

    /// The pages a text of so many words would fill; nil for none.
    public static func pages(forWords words: Int) -> Int? {
        words > 0 ? max(1, (words + wordsPerPage - 1) / wordsPerPage) : nil
    }

    /// The words in a piece of HTML, as bytes: what lies inside tags, scripts,
    /// styles and the document's own title is not text. A run of letters between spaces is one word; in writing
    /// that puts no spaces between words (Chinese, Japanese), each character is one.
    static func words(inHTML data: Data) -> Int {
        var count = 0
        var inTag = false
        var inWord = false
        // The name of the tag being read, while it is still being read.
        var tagName: [UInt8] = []
        var readingName = false
        // Inside <script>, <style> or <title>: nothing counts until it closes.
        var skipping: [UInt8]? = nil
        var wide = 0  // bytes still to come of a character counted as a word
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            for byte in bytes {
                if inTag {
                    if byte == UInt8(ascii: ">") {
                        inTag = false
                        let name = tagName.map { $0 | 0x20 }
                        if let waiting = skipping {
                            if name == [UInt8(ascii: "/")] + waiting { skipping = nil }
                        } else if name == Array("script".utf8) || name == Array("style".utf8)
                            || name == Array("title".utf8) {
                            skipping = name
                        }
                    } else if readingName {
                        if byte == UInt8(ascii: " ") || byte == 0x0A || byte == 0x0D || byte == 0x09 || tagName.count > 8 {
                            readingName = false
                        } else {
                            tagName.append(byte)
                        }
                    }
                    continue
                }
                if byte == UInt8(ascii: "<") {
                    inTag = true
                    inWord = false
                    readingName = true
                    tagName.removeAll(keepingCapacity: true)
                    continue
                }
                if skipping != nil { continue }
                if wide > 0 {
                    wide -= 1
                    continue
                }
                switch byte {
                case 0x20, 0x09, 0x0A, 0x0D:
                    inWord = false
                case 0xE3...0xE9:
                    // Kana, and the ideographs: each its own word. Three bytes long.
                    count += 1
                    wide = 2
                    inWord = false
                default:
                    if !inWord {
                        inWord = true
                        count += 1
                    }
                }
            }
        }
        return count
    }
}

extension EpubIO {
    /// The words in an EPUB's text: the documents of its reading order, each read once.
    /// - Throws: when the file is not an EPUB that can be read.
    static func wordCount(of url: URL) throws -> Int {
        do {
            let archive = try Archive(url: url, accessMode: .read)
            let package = try Package(archive: archive)
            func elements(_ parent: XMLElement?, _ name: String) -> [XMLElement] {
                (parent?.children ?? []).compactMap { $0 as? XMLElement }.filter { $0.localName == name }
            }
            func value(_ element: XMLElement, _ name: String) -> String? {
                element.attribute(forName: name)?.stringValue
            }
            var hrefs: [String: String] = [:]
            for item in elements(package.manifest, "item") {
                if let id = value(item, "id"), let href = value(item, "href") { hrefs[id] = href }
            }
            let spine = elements(elements(package.root, "spine").first, "itemref")
            var seen = Set<String>()
            var total = 0
            for reference in spine {
                guard let id = value(reference, "idref"), let href = hrefs[id],
                      let path = package.archivePath(forHref: href), seen.insert(path).inserted,
                      let entry = archive[path], entry.uncompressedSize < 64_000_000
                else { continue }
                var text = Data()
                _ = try archive.extract(entry) { text.append($0) }
                total += WordCount.words(inHTML: text)
            }
            return total
        } catch let error as MetadataIOError {
            throw error
        } catch {
            throw MetadataIOError.unreadable(url.lastPathComponent)
        }
    }
}

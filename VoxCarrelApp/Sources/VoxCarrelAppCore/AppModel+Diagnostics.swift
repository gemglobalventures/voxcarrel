import Foundation
import OSLog
import VoxCarrelCore

// Export Diagnostics: a zip of plain text the owner saves and sends themselves, for
// reporting a file that trips the app up. Nothing is sent anywhere by the app.

/// One line the app wrote to the system's log while it has been running.
public struct DiagnosticLogLine: Equatable, Sendable {
    public var date: Date
    /// "error", "notice" and so on.
    public var level: String
    public var category: String
    public var message: String

    public init(date: Date, level: String, category: String, message: String) {
        self.date = date
        self.level = level
        self.category = category
        self.message = message
    }
}

/// Where a diagnostics report gets what it says of the app, the Mac and the settings.
/// Tests give one that asks the system nothing.
@MainActor public protocol DiagnosticsSource {
    /// Lines about the app and the Mac: versions, never a name.
    func about() -> [String]
    /// The app's own settings as they are kept.
    func settings() -> [String: Any]
    /// What the app has logged while it has been running, oldest first.
    func recentLog() -> [DiagnosticLogLine]
}

/// Asks the system: the app's bundle, the Mac's version, the app's settings, and this
/// run's entries in the system log under the app's own names.
public struct SystemDiagnosticsSource: DiagnosticsSource {
    public init() {}

    public func about() -> [String] {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info["CFBundleVersion"] as? String ?? "unknown"
        var lines = ["VoxCarrel \(version) (\(build))"]
        lines.append("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        #if arch(arm64)
        lines.append("Processor: Apple silicon")
        #else
        lines.append("Processor: Intel")
        #endif
        lines.append("Memory: \(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) GB")
        lines.append("Language: \(Locale.current.identifier)")
        return lines
    }

    public func settings() -> [String: Any] {
        guard let name = Bundle.main.bundleIdentifier else { return [:] }
        return UserDefaults.standard.persistentDomain(forName: name) ?? [:]
    }

    public func recentLog() -> [DiagnosticLogLine] {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier),
              let entries = try? store.getEntries(at: store.position(timeIntervalSinceLatestBoot: 0))
        else { return [] }
        var lines: [DiagnosticLogLine] = []
        for case let entry as OSLogEntryLog in entries where entry.subsystem.hasPrefix("VoxCarrel") {
            let level: String
            switch entry.level {
            case .debug: level = "debug"
            case .info: level = "info"
            case .notice: level = "notice"
            case .error: level = "error"
            case .fault: level = "fault"
            default: level = "other"
            }
            lines.append(DiagnosticLogLine(
                date: entry.date, level: level, category: "\(entry.subsystem)/\(entry.category)",
                message: entry.composedMessage))
        }
        return Array(lines.suffix(2_000))
    }
}

public enum DiagnosticsText {
    /// The name the zip is offered under: "VoxCarrel Diagnostics 2026-11-26.zip".
    public static func fileName(on date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let day = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "VoxCarrel Diagnostics %04d-%02d-%02d.zip", day.year ?? 0, day.month ?? 0, day.day ?? 0)
    }

    static let readMe = """
        VoxCarrel diagnostics

        These files say how the app and the library were when you chose Export
        Diagnostics. They are for you to look over and send yourself: the app has
        sent nothing anywhere.

        about.txt         The app's version and the Mac's.
        settings.txt      Which settings are set. Switches and numbers are shown;
                          anything typed (a folder, an address) is shown only as
                          "text" with its length.
        library.txt       How many books and files of each kind, and the books that
                          need attention with what is the matter with their files.
        launch-check.txt  What the check made when the library was opened found.
        log.txt           What the app wrote to the system log while it was running.

        """

    static let withoutTitles = "No book title, author, file name or folder is in these files.\n"
    static let withTitles =
        "You chose to include titles: the books that need attention are named, with their files.\n"

    /// A setting as a report may show it: a switch or a number as it is, a date as a
    /// date, and anything that could hold a name (text, a list, data) by its kind and
    /// size alone.
    static func shown(_ value: Any) -> String {
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "on" : "off" }
            return number.stringValue
        }
        if let text = value as? String { return "text (\(text.count) characters)" }
        if let date = value as? Date { return ISO8601DateFormatter().string(from: date) }
        if let data = value as? Data { return "data (\(data.count) bytes)" }
        if let list = value as? [Any] { return "list (\(list.count) items)" }
        if let table = value as? [String: Any] { return "table (\(table.count) entries)" }
        return "something else"
    }

    /// The settings, one to a line, by name. A setting's name is shown only when it is
    /// made of plain letters, digits, dots, dashes and underscores: a name that holds
    /// anything else (a window's title, a path) is counted and not shown.
    static func settings(_ values: [String: Any]) -> String {
        let plain = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        var lines: [String] = []
        var unnamed = 0
        for key in values.keys.sorted() {
            guard let value = values[key] else { continue }
            guard !key.isEmpty, key.unicodeScalars.allSatisfy(plain.contains) else {
                unnamed += 1
                continue
            }
            lines.append("\(key): \(shown(value))")
        }
        if unnamed > 0 { lines.append("(\(unnamed) more, whose names are not shown)") }
        return lines.isEmpty ? "No settings are set.\n" : lines.joined(separator: "\n") + "\n"
    }

    /// Said when the check left nothing behind it to tell.
    static let nothingFound = "The check made when the library was opened found nothing to tell.\n"

    /// What the launch check found, as counts; with `includingTitles`, the reasons it
    /// gave as well.
    static func check(_ report: ReconcileReport?, includingTitles: Bool) -> String {
        guard let report else { return nothingFound }
        func kinds(_ urls: [URL]) -> String {
            var counts: [String: Int] = [:]
            for url in urls { counts[url.pathExtension.lowercased(), default: 0] += 1 }
            let parts = counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }
            return parts.isEmpty ? "" : " (" + parts.joined(separator: ", ") + ")"
        }
        var lines = [
            "Books with files missing: \(report.booksWithMissingFiles.count)",
            "Books whole again: \(report.booksRecovered.count)",
            "Book files no book uses: \(report.untrackedFiles.count)\(kinds(report.untrackedFiles))",
            "Working copies cleared away: \(report.removedWorkingCopies)",
            "Files left under a temporary name: \(report.strandedFiles.count)",
            "Folders left set aside: \(report.strandedFolders.count)",
            "Lengths corrected: \(report.correctedLengths)",
            "Files found to state the wrong length: \(report.filesWithWrongLength)",
            "A change of folder layout was put back: \(report.recoveredLayoutChange ? "yes" : "no")",
            "A merge was put back: \(report.recoveredMerge ? "yes" : "no")",
            "A change of folder layout could not be put right: \(report.layoutChangeProblem == nil ? "no" : "yes")",
            "A merge could not be put right: \(report.mergeProblem == nil ? "no" : "yes")",
        ]
        if includingTitles {
            if let reason = report.layoutChangeProblem { lines.append("  Layout: \(reason)") }
            if let reason = report.mergeProblem { lines.append("  Merge: \(reason)") }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The log, a line to an entry. What an entry says is shown only with
    /// `includingTitles`: a message may quote a name.
    static func log(_ lines: [DiagnosticLogLine], includingTitles: Bool) -> String {
        guard !lines.isEmpty else { return "Nothing was logged.\n" }
        let stamp = ISO8601DateFormatter()
        return lines.map { line in
            let head = "\(stamp.string(from: line.date)) \(line.level) \(line.category)"
            return includingTitles ? "\(head): \(line.message)" : head
        }.joined(separator: "\n") + "\n"
    }
}

extension AppModel {
    /// Whether Export Diagnostics is offered: always, library or no library.
    public var canExportDiagnostics: Bool { true }

    /// Saves a diagnostics report as a zip at `url`.
    /// - Parameter includingTitles: Whether the books that need attention are named,
    ///   with their files, and log messages are shown in full.
    /// - Returns: True when the zip was written. A failure is shown as a sentence.
    @discardableResult
    public func exportDiagnostics(to url: URL, includingTitles: Bool) async -> Bool {
        let source = diagnosticsSource
        var library = "No library is open.\n"
        if let worker {
            do {
                library = try await worker.withService { try $0.diagnosticsReport(includingTitles: includingTitles) }
            } catch {
                library = "The library could not be read.\n"
            }
        }
        let note = includingTitles ? DiagnosticsText.withTitles : DiagnosticsText.withoutTitles
        let entries: [DiagnosticsArchive.Entry] = [
            .init(name: "README.txt", text: DiagnosticsText.readMe + note),
            .init(name: "about.txt", text: source.about().joined(separator: "\n") + "\n"),
            .init(name: "settings.txt", text: DiagnosticsText.settings(source.settings())),
            .init(name: "library.txt", text: library),
            .init(name: "launch-check.txt", text: DiagnosticsText.check(libraryCheck, includingTitles: includingTitles)),
            .init(name: "log.txt", text: DiagnosticsText.log(source.recentLog(), includingTitles: includingTitles)),
        ]
        do {
            try DiagnosticsArchive.write(entries, to: url)
            return true
        } catch {
            show(error)
            return false
        }
    }
}

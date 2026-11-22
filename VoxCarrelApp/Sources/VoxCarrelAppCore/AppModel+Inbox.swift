import Foundation
import VoxCarrelCore

// Watch folders and the Inbox (rules WF10–WF24).
//
// The library looks into the watch folders whenever something may have changed: when the
// watcher reports, every minute, and a settle interval after any look that saw a file
// still arriving. A look is not an operation: it shows nothing as busy and waits for no
// one, and nothing is moved until the owner reviews an arrival in the import sheet.

extension AppModel {
    /// How often the folders are looked into whatever the watcher says: it is not to be
    /// relied on for every kind of disk.
    static let inboxTickInterval: TimeInterval = 60
    /// How long after a look that saw unsettled files the next is taken: just over the
    /// time a file must stay unchanged to count as having arrived.
    static let inboxRecheckInterval: TimeInterval = SettleTracker.settleInterval + 1

    // MARK: What is shown

    /// The books waiting to be reviewed, newest first.
    public var inboxRows: [InboxRow] {
        inboxArrivals.map { arrival in
            InboxText.row(for: arrival, folder: watchFolders.first { $0.id == arrival.folderId })
        }
    }

    /// How many books are waiting: the sidebar's badge, when above zero.
    public var inboxCount: Int {
        inboxArrivals.count
    }

    /// The watch folders as Settings lists them, oldest first.
    public var watchFolderRows: [WatchFolderRow] {
        watchFolderStatuses.map { InboxText.row(for: $0) }
    }

    /// WF13: whether the sidebar has an Inbox: there is at least one watch folder.
    public var showsInbox: Bool {
        !watchFolders.isEmpty
    }

    /// What is said above the Inbox's table: that the last check failed, and each
    /// folder that is on and cannot be watched, by name. Empty when all is well.
    public var inboxNotices: [String] {
        var notices = inboxProblem.map { [$0] } ?? []
        for status in watchFolderStatuses where status.folder.isEnabled {
            guard let note = InboxText.note(for: status) else { continue }
            notices.append("“\(status.folder.url.lastPathComponent)”: \(note)")
        }
        return notices
    }

    /// Under the window's title while the Inbox is shown.
    var inboxSubtitle: String {
        switch inboxArrivals.count {
        case 0: "Nothing waiting"
        case 1: "1 book waiting"
        default: "\(inboxArrivals.count) books waiting"
        }
    }

    /// Whether Review can be chosen: something is waiting, and an import can be begun.
    public var canReviewInbox: Bool {
        !inboxArrivals.isEmpty && canImport
    }

    /// What the Review button says: it reviews everything when nothing is selected.
    public var reviewInboxTitle: String {
        inboxSelection.isEmpty ? "Review All…" : "Review…"
    }

    /// Whether Dismiss can be chosen: something is selected.
    public var canDismissInbox: Bool {
        isLibraryOpen && !inboxSelection.isEmpty
    }

    private var watchFolderStatuses: [WatchFolderStatus] {
        watchFolders.map {
            WatchFolderStatus(folder: $0, availability: watchFolderAvailability[$0.id] ?? .available)
        }
    }

    // MARK: Opening and closing

    /// WF10: the library has opened and its launch check is over.
    func openInbox() async {
        guard let worker else { return }
        do {
            let folders = try await worker.watchFolders()
            guard worker === self.worker else { return }
            foldersChanged(to: folders)
        } catch {
            inboxProblem = InboxText.couldNotCheck
        }
        requestInboxCheck()
    }

    /// WF10: the library is closing, or another is being opened.
    func closeInbox() {
        watcher.stop()
        watchedPaths = nil
        ticker.cancelAll()
        inboxTickScheduled = false
        inboxRecheckScheduled = false
        inboxCheckWanted = false
        inboxArrivals = []
        watchFolders = []
        watchFolderAvailability = [:]
        inboxSelection = []
        inboxProblem = nil
    }

    /// The watch folders are these now: what follows from that.
    private func foldersChanged(to folders: [WatchFolder]) {
        watchFolders = folders
        let ids = Set(folders.map(\.id))
        watchFolderAvailability = watchFolderAvailability.filter { ids.contains($0.key) }
        // The books of a folder that has gone are no longer waiting anywhere.
        inboxArrivals.removeAll { !ids.contains($0.folderId) }
        inboxSelection.formIntersection(inboxArrivals.map(\.id))
        // WF13
        if !showsInbox, sidebarSelection == .inbox { sidebarSelection = .allBooks }

        // WF10, WF17: the watcher is started again only when what it watches has changed.
        let enabled = folders.filter(\.isEnabled)
        let paths = enabled.map(\.path)
        if paths.isEmpty {
            if watchedPaths != nil {
                watcher.stop()
                watchedPaths = nil
            }
        } else if paths != watchedPaths {
            // Held weakly: the model owns the watcher.
            watcher.watch(enabled.map(\.url)) { [weak self] in self?.requestInboxCheck() }
            watchedPaths = paths
        }
        scheduleInboxTick()
    }

    // MARK: Checking

    /// WF11: one check every minute while a folder is enabled. There is never more than
    /// one waiting: each schedules the next when it runs.
    private func scheduleInboxTick() {
        guard !inboxTickScheduled, watchFolders.contains(where: \.isEnabled) else { return }
        inboxTickScheduled = true
        // Held weakly: the model owns the ticker.
        ticker.schedule(after: Self.inboxTickInterval) { [weak self] in
            guard let self else { return }
            self.inboxTickScheduled = false
            guard self.watchFolders.contains(where: \.isEnabled) else { return }
            self.requestInboxCheck()
            self.scheduleInboxTick()
        }
    }

    /// WF11: one more check a settle interval on, for the files that were still arriving.
    private func scheduleInboxRecheck() {
        guard !inboxRecheckScheduled else { return }
        inboxRecheckScheduled = true
        ticker.schedule(after: Self.inboxRecheckInterval) { [weak self] in
            guard let self else { return }
            self.inboxRecheckScheduled = false
            self.requestInboxCheck()
        }
    }

    /// Asks for the watch folders to be looked into.
    ///
    /// WF11: checks never overlap; asked for during one, one more is made when it ends,
    /// however often it was asked. WF12: while an operation holds the library none is
    /// made; one is when the operation ends.
    func requestInboxCheck() {
        guard worker != nil else { return }
        guard !inboxCheckRunning, busyLabel == nil else {
            inboxCheckWanted = true
            return
        }
        inboxCheckRunning = true
        spawn { await self.runInboxChecks() }
    }

    /// WF12: an operation has ended.
    func resumeInboxCheck() {
        guard inboxCheckWanted, !inboxCheckRunning else { return }
        requestInboxCheck()
    }

    private func runInboxChecks() async {
        defer { inboxCheckRunning = false }
        repeat {
            // WF12: put off until the operation ends; `inboxCheckWanted` remembers it.
            guard busyLabel == nil, let worker else {
                inboxCheckWanted = worker != nil
                return
            }
            inboxCheckWanted = false
            inboxCheckCount += 1
            do {
                try await beforeInboxCheck?()
                let report = try await worker.checkInbox(now: inboxNow())
                // The library has been closed meanwhile: its inbox is not wanted. The one
                // that is open now may have asked for a check of its own.
                guard worker === self.worker else { continue }
                apply(report)
            } catch {
                guard worker === self.worker else { continue }
                // WF23: what was found before stays; nothing is put in the user's way.
                inboxProblem = InboxText.couldNotCheck
            }
        } while inboxCheckWanted
    }

    private func apply(_ report: InboxReport) {
        inboxProblem = nil
        inboxArrivals = report.arrivals
        watchFolderAvailability = Dictionary(
            report.folders.map { ($0.folder.id, $0.availability) }, uniquingKeysWith: { first, _ in first })
        foldersChanged(to: report.folders.map(\.folder))
        // WF22
        inboxSelection.formIntersection(report.arrivals.map(\.id))
        if report.hasUnsettled { scheduleInboxRecheck() }
    }

    // MARK: Settings

    /// WF16: starts watching a folder. What is in it already does not arrive. A folder
    /// that cannot be watched is refused, and `alert` says why.
    public func addWatchFolder(_ url: URL) async {
        guard let worker else { return }
        do {
            let folders = try await worker.addWatchFolder(url, now: inboxNow())
            guard worker === self.worker else { return }
            foldersChanged(to: folders)
            requestInboxCheck()
        } catch let problem as WatchFolderProblem {
            guard worker === self.worker else { return }
            alert = UserMessage.text(for: problem, folder: url)
        } catch {
            guard worker === self.worker else { return }
            show(error)
        }
    }

    /// WF17: whether reviewing a book from the folder moves its files or copies them,
    /// unless the owner says otherwise in the review.
    public func setWatchFolder(_ id: Int64, mode: WatchFolderMode) async {
        await changeWatchFolders { try await $0.updateWatchFolder(id: id) { $0.mode = mode } }
    }

    /// WF17: a folder that is off is not looked into, and nothing of it is in the Inbox.
    public func setWatchFolder(_ id: Int64, enabled: Bool) async {
        await changeWatchFolders { try await $0.updateWatchFolder(id: id) { $0.isEnabled = enabled } }
    }

    /// WF17: whether PDFs that arrive in the folder count as books. The PDFs in it when
    /// this is turned on do not arrive.
    public func setWatchFolder(_ id: Int64, includesPDFs: Bool) async {
        await changeWatchFolders { try await $0.updateWatchFolder(id: id) { $0.includesPDFs = includesPDFs } }
    }

    /// WF17: stops watching a folder. Its files are left as they are.
    public func removeWatchFolder(_ id: Int64) async {
        await changeWatchFolders { try await $0.removeWatchFolder(id: id) }
    }

    /// WF17: lets the books that were in the folder when it was added arrive.
    public func scanExisting(inWatchFolder id: Int64) async {
        await changeWatchFolders {
            try await $0.scanExisting(inWatchFolder: id)
            return try await $0.watchFolders()
        }
    }

    /// WF17: makes a change to the watch folders that is saved at once, then takes up
    /// the folders as they are and checks the inbox. Not an operation: it does not
    /// wait to be asked again when one is running, it takes its turn after it.
    private func changeWatchFolders(_ change: (LibraryWorker) async throws -> [WatchFolder]) async {
        guard let worker else { return }
        do {
            let folders = try await change(worker)
            guard worker === self.worker else { return }
            foldersChanged(to: folders)
        } catch {
            guard worker === self.worker else { return }
            show(error)
        }
        requestInboxCheck()
    }

    // MARK: Reviewing and dismissing

    /// WF18: opens the import review for the selected arrivals, or for all of them when
    /// none is selected. Does nothing while a review is open or an operation runs.
    public func reviewInbox() async {
        await review(
            inboxSelection.isEmpty ? inboxArrivals : inboxArrivals.filter { inboxSelection.contains($0.id) })
    }

    /// WF18: opens the import review for one arrival, whatever is selected: for a
    /// double-click on its row.
    public func reviewInbox(only id: String) async {
        await review(inboxArrivals.filter { $0.id == id })
    }

    /// The arrivals go to the review grouped as the Inbox shows them: a folder of parts
    /// is one book there, as it is here.
    private func review(_ arrivals: [InboxArrival]) async {
        guard !arrivals.isEmpty, review == nil, let worker = await begin("Reading files…") else { return }
        do {
            let seeds = try await worker.prepareImport(candidates: arrivals.map(\.candidate))
            if seeds.isEmpty {
                alert = Self.inboxFilesGone
                requestInboxCheck()
            } else {
                // WF19: Copy unless every folder the books come from is set to Move.
                let modes = Set(arrivals.compactMap { arrival in
                    watchFolders.first { $0.id == arrival.folderId }?.mode
                })
                await openReview(
                    ImportReview(
                        seeds: seeds, skipped: [], copyInsteadOfMove: modes.contains(.copy), isFromInbox: true,
                        inboxNote: modes.count > 1 ? ImportReview.mixedModesNote : nil))
            }
            // Reading changes nothing in the library, so there is nothing to reload.
            busyLabel = nil
        } catch {
            show(error)
            await finish()
        }
    }

    static let inboxFilesGone = "Those files are no longer in the watch folder, so there is nothing to review."

    /// WF20: an import from the Inbox has been made. The files of the books that were
    /// imported and are still in their watch folder (they were copied, or catalogued
    /// where they are) are remembered, so that they do not arrive again. Part of the
    /// import's operation; the check that follows is made when it ends.
    func recordInboxImport(of files: [URL], with worker: LibraryWorker) async {
        do {
            try await worker.recordImported(files)
        } catch {
            show(error)
        }
        requestInboxCheck()
    }

    /// WF21: takes the selected arrivals out of the Inbox for good. Their files are not
    /// touched; one that changes afterwards arrives again.
    public func dismissInbox() async {
        guard let worker, !inboxSelection.isEmpty else { return }
        let ids = inboxSelection
        do {
            try await worker.dismissArrivals(ids: ids.sorted())
            guard worker === self.worker else { return }
            inboxArrivals.removeAll { ids.contains($0.id) }
            inboxSelection.subtract(ids)
        } catch {
            guard worker === self.worker else { return }
            show(error)
        }
        requestInboxCheck()
    }
}

extension UserMessage {
    /// WF16: why the folder that was picked cannot be watched.
    public static func text(for problem: WatchFolderProblem, folder: URL) -> String {
        switch problem {
        case .notAFolder:
            return "That folder could not be found. Choose a folder that is there."
        case .isLibrary:
            return "That folder is your library. Choose a folder outside it."
        case .insideLibrary:
            return "That folder is inside your library. Choose a folder outside it."
        case .containsLibrary:
            return "That folder contains your library. Choose a folder that does not."
        case .overlaps(let existing):
            let picked = folder.resolvingSymlinksInPath().standardizedFileURL.pathComponents
            let watched = URL(fileURLWithPath: existing).resolvingSymlinksInPath().standardizedFileURL.pathComponents
            guard picked.count != watched.count else { return "That folder is already watched." }
            let how = picked.count > watched.count ? "is inside" : "contains"
            return "That folder \(how) “\(InboxText.abbreviated(existing))”, which is already watched. "
                + "Choose a folder that is apart from it."
        }
    }
}

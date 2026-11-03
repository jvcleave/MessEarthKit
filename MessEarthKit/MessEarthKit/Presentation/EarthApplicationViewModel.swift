import AppKit
import Foundation
import MessEarthKit
import Observation

/// Composition owns replacing the library as a unit. No existing project/store
/// changes its root beneath cached source URLs or still-active workers.
@MainActor
@Observable
final class EarthApplicationViewModel
{
    private(set) var library: EarthProjectLibraryViewModel?
    private(set) var openingError: String?
    private(set) var isMovingStorage = false
    private(set) var storageStatus = ""
    private(set) var storageMoveError: String?
    private(set) var previousStorageURL: URL?
    @ObservationIgnored private var files: EarthAppFiles?
    @ObservationIgnored private var moveTask: Task<Void, Never>?
    @ObservationIgnored private var isOpening = false
    @ObservationIgnored private var moveID = UUID()
    @ObservationIgnored private var isCopyingStorage = false

    var storageDirectoryPath: String { files?.storageRootURL.path ?? "" }
    var canMoveStorage: Bool { !isMovingStorage && library?.canMoveStorage == true }

    func openLibrary() async
    {
        guard !isOpening, !isMovingStorage, library == nil else { return }
        isOpening = true
        openingError = nil
        defer { isOpening = false }
        do
        {
            let files = try await EarthAppFiles.openDefault()
            try await installLibrary(files)
        }
        catch { openingError = error.localizedDescription }
    }

    func retryOpening() { openingError = nil }

    func chooseStorageDirectory()
    {
        guard canMoveStorage, let original = library, let files else { return }
        isMovingStorage = true
        storageMoveError = nil
        previousStorageURL = nil
        storageStatus = "Choosing storage folder…"
        let job = UUID()
        moveID = job
        moveTask = Task
        {
            var suspended = false
            var committed = false
            defer
            {
                if !committed { original.endStorageMove() }
                isMovingStorage = false
                isCopyingStorage = false
                moveTask = nil
            }
            do
            {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.allowsMultipleSelection = false
                panel.canCreateDirectories = true
                panel.prompt = "Move Storage"
                panel.message = "Choose an empty folder for the existing MessEarthKit library."
                guard await panel.begin() == .OK, let destination = panel.url else { storageStatus = ""; return }
                try Task.checkCancellation()
                guard destination.standardizedFileURL.resolvingSymlinksInPath() != files.storageRootURL.resolvingSymlinksInPath()
                else { storageStatus = ""; return }
                try original.beginStorageMove()
                await original.settings.suspendForStorageMove()
                suspended = true
                await original.exportViewer.closeAndWait()
                try Task.checkCancellation()
                isCopyingStorage = true
                let result = try await files.moveStorage(to: destination, selectionFile: EarthAppFiles.storageLocationFileURL())
                { [weak self] status in Task
                { @MainActor [weak self] in
                    guard let self, self.moveID == job, self.isCopyingStorage else { return }
                    self.storageStatus = status
                }
                }
                isCopyingStorage = false
                committed = true
                // From this point the saved root is authoritative, even if opening
                // its UI fails. Retry must never resume the retired old owners.
                library = nil
                self.files = result.files
                storageStatus = result.oldCopiesRemain ? "Storage moved. Some previous copies could not be removed; review the previous folder in Finder." : "Storage moved."
                previousStorageURL = result.oldCopiesRemain ? result.previousRoot : nil
                do { try await installLibrary(result.files, apiKey: original.settings.apiKey, showSettings: true) }
                catch { openingError = error.localizedDescription }
            }
            catch
            {
                if suspended { original.settings.resumeAfterStorageMoveFailure() }
                if error is CancellationError { storageStatus = "Storage move cancelled." }
                else { storageStatus = ""; storageMoveError = error.localizedDescription }
            }
        }
    }

    func cancelStorageMove() { moveTask?.cancel() }

    func revealPreviousStorage()
    {
        guard let files, let previousStorageURL else { return }
        Task { await files.reveal(previousStorageURL) }
    }

    private func installLibrary(_ files: EarthAppFiles, apiKey: String? = nil, showSettings: Bool = false) async throws
    {
        let usage = EarthRequestUsageStore(fileURL: try await files.requestUsageURL())
        let opened = EarthProjectLibraryViewModel(files: files, usageStore: usage)
        if let apiKey { opened.settings.setAPIKey(apiKey) }
        if showSettings { opened.path = [.settings] }
        self.files = files
        openingError = nil
        library = opened
    }
}

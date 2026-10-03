import Combine
import Foundation

/// The folder for every file the app saves (speech, recordings, practice progress): the app's
/// Documents folder, unless the user chose another one in Settings.
///
/// A chosen folder is kept with a security-scoped bookmark, so it can be anywhere in Files,
/// including iCloud Drive, where the Mac app can open the same files.
@MainActor
final class StorageFolder: ObservableObject {
    static let shared = StorageFolder()

    /// The folder the user chose, or `nil` to use the app's Documents folder.
    @Published private(set) var chosenURL: URL?

    private var isAccessingURL = false

    private static let bookmarkKey = "storageFolderBookmark"
    private static let appFolderName = "EchoLingo"
    private static let subfolders = ["speech", "recordings", "sessions"]

    private init() {
        chosenURL = resolveBookmark()
        moveAppDocuments(into: url)
    }

    private func resolveBookmark() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return nil }
        var isStale = false
        guard let resolved = try? URL(
            resolvingBookmarkData: data,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }
        isAccessingURL = resolved.startAccessingSecurityScopedResource()
        if isStale, let refreshed = try? resolved.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(refreshed, forKey: Self.bookmarkKey)
        }
        return resolved
    }

    private static var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    var url: URL {
        chosenURL ?? Self.documentsURL
    }

    /// The chosen folder's name, or `nil` when the Documents folder is used.
    var displayName: String? {
        chosenURL.map { FileManager.default.displayName(atPath: $0.path) }
    }

    /// The EchoLingo folder inside the chosen folder, which holds all of the app's subfolders.
    /// If the user picked a folder that is already called EchoLingo, it is used as is.
    private static func appFolder(in folder: URL) -> URL {
        if folder.lastPathComponent == appFolderName { return folder }
        return folder.appendingPathComponent(appFolderName, isDirectory: true)
    }

    func subfolder(_ name: String) -> URL {
        Self.appFolder(in: url).appendingPathComponent(name, isDirectory: true)
    }

    /// Remembers `newURL` (from a folder picker) as the place to save files, and moves files
    /// that earlier versions of the app kept directly in its Documents folder into it.
    func choose(_ newURL: URL) throws {
        let didStartAccess = newURL.startAccessingSecurityScopedResource()
        let bookmark: Data
        do {
            bookmark = try newURL.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        } catch {
            if didStartAccess { newURL.stopAccessingSecurityScopedResource() }
            throw error
        }
        UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey)
        stopAccessingChosenURL()
        isAccessingURL = didStartAccess
        chosenURL = newURL
        moveAppDocuments(into: newURL)
    }

    /// Goes back to saving files in the app's Documents folder.
    func useDocumentsFolder() {
        UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
        stopAccessingChosenURL()
        chosenURL = nil
    }

    private func stopAccessingChosenURL() {
        if isAccessingURL { chosenURL?.stopAccessingSecurityScopedResource() }
        isAccessingURL = false
    }

    private func moveAppDocuments(into folder: URL) {
        let fileManager = FileManager.default
        for name in Self.subfolders {
            let source = Self.documentsURL.appendingPathComponent(name, isDirectory: true)
            guard let items = try? fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) else { continue }
            let destination = Self.appFolder(in: folder).appendingPathComponent(name, isDirectory: true)
            try? fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
            for item in items {
                let target = destination.appendingPathComponent(item.lastPathComponent)
                guard !fileManager.fileExists(atPath: target.path) else { continue }
                try? fileManager.moveItem(at: item, to: target)
            }
            if (try? fileManager.contentsOfDirectory(atPath: source.path))?.isEmpty == true {
                try? fileManager.removeItem(at: source)
            }
        }
    }

    // MARK: - Coordinated file access

    // Files in iCloud Drive may be edited by the Mac app or still be downloading, so small
    // files are read and written through NSFileCoordinator.

    nonisolated static func coordinatedRead(at url: URL) throws -> Data {
        var coordinationError: NSError?
        var result: Result<Data, Error> = .failure(CocoaError(.fileReadUnknown))
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readURL in
            result = Result { try Data(contentsOf: readURL) }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }

    nonisolated static func coordinatedWrite(_ data: Data, to url: URL) throws {
        var coordinationError: NSError?
        var result: Result<Void, Error> = .failure(CocoaError(.fileWriteUnknown))
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { writeURL in
            result = Result { try data.write(to: writeURL, options: .atomic) }
        }
        if let coordinationError { throw coordinationError }
        try result.get()
    }
}

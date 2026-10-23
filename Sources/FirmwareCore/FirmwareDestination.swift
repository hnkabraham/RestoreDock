import Foundation

/// Chooses a library location without creating or modifying folders at launch.
public enum FirmwareDestination {
    public static func configuratorDirectory(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        homeDirectory.appendingPathComponent(
            "Library/Group Containers/K36BKF7T3D.group.com.apple.configurator/Library/Caches/Firmware",
            isDirectory: true)
    }

    public static func directoryExists(at url: URL, fileManager: FileManager = .default) -> Bool {
        guard url.isFileURL else { return false }
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// A saved choice always wins. Fresh settings use Configurator only when its
    /// Firmware directory already exists. An existing pre-rename download folder
    /// is reused; new libraries otherwise use Downloads/RestoreDock.
    public static func preferredDirectory(savedPath: String? = nil,
                                          homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
                                          downloadsDirectory: URL? = nil,
                                          fileManager: FileManager = .default) -> URL {
        if let savedPath, !savedPath.isEmpty {
            return URL(fileURLWithPath: savedPath, isDirectory: true)
        }
        let configurator = configuratorDirectory(homeDirectory: homeDirectory)
        if directoryExists(at: configurator, fileManager: fileManager) { return configurator }
        let downloads = downloadsDirectory
            ?? fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? homeDirectory.appendingPathComponent("Downloads", isDirectory: true)
        let previousDefault = downloads.appendingPathComponent("Firmware Shelf", isDirectory: true)
        if directoryExists(at: previousDefault, fileManager: fileManager) { return previousDefault }
        return downloads.appendingPathComponent("RestoreDock", isDirectory: true)
    }

    /// Called only after the user chooses a folder or explicitly creates the
    /// Configurator cache. A failed validation never changes the app's selection.
    @discardableResult
    public static func prepareDirectory(at url: URL, createIfNeeded: Bool,
                                        fileManager: FileManager = .default) throws -> URL {
        guard url.isFileURL else { throw DestinationError.invalidLocation }
        let directory = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw DestinationError.notDirectory(directory.path) }
        } else {
            guard createIfNeeded else { throw DestinationError.missingDirectory(directory.path) }
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        guard directoryExists(at: directory, fileManager: fileManager) else {
            throw DestinationError.notDirectory(directory.path)
        }
        guard fileManager.isWritableFile(atPath: directory.path),
              fileManager.isExecutableFile(atPath: directory.path) else {
            throw DestinationError.notWritable(directory.path)
        }
        return directory
    }

    public static func sameDirectory(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL.resolvingSymlinksInPath() == rhs.standardizedFileURL.resolvingSymlinksInPath()
    }
}

public enum DestinationError: LocalizedError, Equatable {
    case invalidLocation
    case missingDirectory(String)
    case notDirectory(String)
    case notWritable(String)

    public var errorDescription: String? {
        switch self {
        case .invalidLocation: return "Choose a local folder or a mounted drive."
        case .missingDirectory(let path): return "This folder does not exist: \(path). Use Create & Use to add it."
        case .notDirectory(let path): return "This location is a file, not a folder: \(path). Choose another location."
        case .notWritable(let path): return "RestoreDock cannot write to this folder: \(path). Choose a writable folder or update its permissions in Finder."
        }
    }
}

import Foundation

/// A current public restore image for one Apple hardware identifier.
/// Several identifiers can intentionally reference the same download URL.
public struct DeviceFirmware: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let version: String
    public let build: String
    public let downloadURL: URL
    public let fileSize: Int64?
    public let sha1: String?
    public let releaseDate: Date?

    public init(id: String, name: String, version: String, build: String,
                downloadURL: URL, fileSize: Int64? = nil, sha1: String? = nil,
                releaseDate: Date? = nil) {
        self.id = id
        self.name = name
        self.version = version
        self.build = build
        self.downloadURL = downloadURL
        self.fileSize = fileSize
        self.sha1 = sha1
        self.releaseDate = releaseDate
    }
}

public struct CatalogSnapshot: Codable, Sendable {
    public let devices: [DeviceFirmware]
    public let fetchedAt: Date
    public let sourceDescription: String
    public let warnings: [String]

    public init(devices: [DeviceFirmware], fetchedAt: Date,
                sourceDescription: String, warnings: [String] = []) {
        self.devices = devices
        self.fetchedAt = fetchedAt
        self.sourceDescription = sourceDescription
        self.warnings = warnings
    }
}

/// Apply this to the original URL and every redirect before downloading firmware.
public struct AppleDownloadPolicy: Sendable {
    public static func permits(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.user == nil, url.password == nil,
              url.port == nil || url.port == 443,
              let host = url.host?.lowercased() else { return false }
        return host == "apple.com" || host.hasSuffix(".apple.com")
            || host == "cdn-apple.com" || host.hasSuffix(".cdn-apple.com")
    }
}

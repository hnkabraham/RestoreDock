import Foundation

/// An IPSW release reported by IPSW.me. Signing status is a point-in-time hint,
/// not a guarantee that Apple will authorize a restore.
public struct FirmwareRelease: Identifiable, Sendable, Equatable {
    public var id: String { build }
    public let version: String
    public let build: String
    public let releaseDate: Date?
    public let fileSize: Int64?
    public let isSigned: Bool
    /// Contradictory records for this build make signing status unknown.
    /// Do not use either `isSigned` value to authorize downloads or cleanup.
    public let isSigningStatusConflicting: Bool
    public let downloadURL: URL?
    public let sha1: String?

    /// Metadata eligibility only. Callers should refresh signing status before
    /// queueing; Apple still makes the final restore-authorization decision.
    public var canDownload: Bool { isSigned && !isSigningStatusConflicting && downloadURL != nil && sha1 != nil }

    public init(version: String, build: String, releaseDate: Date? = nil,
                fileSize: Int64? = nil, isSigned: Bool, downloadURL: URL? = nil,
                sha1: String? = nil, isSigningStatusConflicting: Bool = false) {
        self.version = version; self.build = build; self.releaseDate = releaseDate
        self.fileSize = fileSize; self.isSigned = isSigned
        self.isSigningStatusConflicting = isSigningStatusConflicting
        self.downloadURL = downloadURL.flatMap {
            AppleDownloadPolicy.permits($0) && $0.pathExtension.lowercased() == "ipsw" ? $0 : nil
        }
        self.sha1 = sha1.flatMap { raw in
            let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard normalized.utf8.count == 40, normalized.utf8.allSatisfy({
                (48...57).contains($0) || (97...102).contains($0)
            }) else { return nil }
            return normalized
        }
    }

    /// Convert a signed history item into the same validated queue input used
    /// for current firmware. The caller supplies the history's device identity.
    public func firmware(deviceIdentifier: String, name: String) -> DeviceFirmware? {
        guard canDownload, let downloadURL, let sha1,
              deviceIdentifier.range(of: #"^(iPhone|iPad)[0-9]+,[0-9]+\z"#, options: .regularExpression) != nil else { return nil }
        return DeviceFirmware(id: deviceIdentifier, name: name, version: version, build: build,
            downloadURL: downloadURL, fileSize: fileSize, sha1: sha1, releaseDate: releaseDate)
    }
}

public struct FirmwareHistory: Sendable {
    public let deviceIdentifier: String
    public let deviceName: String
    public let releases: [FirmwareRelease]
    public let fetchedAt: Date

    public init(deviceIdentifier: String, deviceName: String,
                releases: [FirmwareRelease], fetchedAt: Date) {
        self.deviceIdentifier = deviceIdentifier; self.deviceName = deviceName
        self.releases = releases; self.fetchedAt = fetchedAt
    }
}

/// Reads historical metadata only; it never retrieves a firmware binary.
public struct FirmwareHistoryService: Sendable {
    public init() {}

    public func fetch(deviceIdentifier: String) async throws -> FirmwareHistory {
        guard Self.validIdentifier(deviceIdentifier) else { throw FirmwareHistoryError.invalidIdentifier }
        let url = URL(string: "https://api.ipsw.me/v4/device/\(deviceIdentifier)?type=ipsw")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 45
        let redirectGuard = HistoryRedirectGuard()
        let session = URLSession(configuration: configuration, delegate: redirectGuard, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("RestoreDock/1.6", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse,
              (200...299).contains(response.statusCode),
              let finalURL = response.url, HistoryRedirectGuard.permits(finalURL) else {
            throw FirmwareHistoryError.failedResponse
        }
        return try Self.parse(data: data, deviceIdentifier: deviceIdentifier)
    }

    /// Deterministic parsing for fixtures and cached metadata. Dates describe
    /// IPSW releases, so OTA-only and Rapid Security Response updates are absent.
    public static func parse(data: Data, deviceIdentifier: String, now: Date = Date()) throws -> FirmwareHistory {
        guard validIdentifier(deviceIdentifier) else { throw FirmwareHistoryError.invalidIdentifier }
        guard data.count <= 8 * 1_024 * 1_024 else { throw FirmwareHistoryError.responseTooLarge }
        let document: HistoryDocument
        do { document = try JSONDecoder().decode(HistoryDocument.self, from: data) }
        catch { throw FirmwareHistoryError.invalidResponse }
        guard document.identifier == deviceIdentifier else { throw FirmwareHistoryError.wrongDevice }
        let ordinaryDate = ISO8601DateFormatter()
        let fractionalDate = ISO8601DateFormatter()
        fractionalDate.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var candidates: [FirmwareRelease] = []
        var signingStatuses: [String: Set<Bool>] = [:]
        for record in document.firmwares {
            guard record.identifier == nil || record.identifier == deviceIdentifier,
                  !record.buildid.isEmpty else { continue }
            // Preserve contradictory signing evidence before version/date
            // filtering and deduplication. A malformed or future duplicate must
            // not make deletion of a locally saved build appear safe.
            signingStatuses[record.buildid, default: []].insert(record.signed)
            // Do not infer beta status from a build suffix: public builds can
            // share release-candidate builds. Explicit labels/flags are excluded.
            guard record.beta != true,
                  record.version.range(of: #"^[0-9]+(?:\.[0-9]+){0,3}\z"#, options: .regularExpression) != nil else { continue }
            let date = record.releasedate.flatMap { ordinaryDate.date(from: $0) ?? fractionalDate.date(from: $0) }
            // A future-dated item is not yet part of the released history.
            if let date, date > now { continue }
            candidates.append(FirmwareRelease(version: record.version, build: record.buildid,
                releaseDate: date, fileSize: record.filesize.flatMap { $0 > 0 ? $0 : nil },
                isSigned: record.signed, downloadURL: record.url.flatMap(URL.init(string:)), sha1: record.sha1sum))
        }
        candidates.sort(by: precedes)
        var seen: Set<String> = []
        let releases = candidates.filter { seen.insert($0.build).inserted }.map { release in
            guard signingStatuses[release.build]?.count == 2 else { return release }
            return FirmwareRelease(version: release.version, build: release.build,
                releaseDate: release.releaseDate, fileSize: release.fileSize,
                isSigned: release.isSigned, downloadURL: release.downloadURL,
                sha1: release.sha1, isSigningStatusConflicting: true)
        }
        guard !releases.isEmpty else { throw FirmwareHistoryError.noReleases }
        let name = document.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return FirmwareHistory(deviceIdentifier: deviceIdentifier,
            deviceName: name.isEmpty ? deviceIdentifier : name, releases: releases, fetchedAt: now)
    }

    private static func validIdentifier(_ value: String) -> Bool {
        value.range(of: #"^(iPhone|iPad)[0-9]+,[0-9]+\z"#, options: .regularExpression) != nil
    }

    private static func precedes(_ lhs: FirmwareRelease, _ rhs: FirmwareRelease) -> Bool {
        let version = lhs.version.compare(rhs.version, options: .numeric)
        if version != .orderedSame { return version == .orderedDescending }
        if lhs.releaseDate != rhs.releaseDate { return (lhs.releaseDate ?? .distantPast) > (rhs.releaseDate ?? .distantPast) }
        let build = lhs.build.compare(rhs.build, options: .numeric)
        if build != .orderedSame { return build == .orderedDescending }
        // Conservative, stable tie-breakers for contradictory duplicate records.
        if lhs.isSigned != rhs.isSigned { return !lhs.isSigned }
        if lhs.canDownload != rhs.canDownload { return lhs.canDownload }
        if lhs.fileSize != rhs.fileSize { return (lhs.fileSize ?? 0) > (rhs.fileSize ?? 0) }
        if lhs.downloadURL != rhs.downloadURL { return (lhs.downloadURL?.absoluteString ?? "") > (rhs.downloadURL?.absoluteString ?? "") }
        if lhs.sha1 != rhs.sha1 { return (lhs.sha1 ?? "") > (rhs.sha1 ?? "") }
        return lhs.version > rhs.version
    }
}

/// Apple publishes consumer release notes in one article per OS major version.
/// Article IDs below were checked against Apple's original pages. Unknown
/// versions use Apple's own search form instead of guessing an article or anchor.
public enum AppleReleaseNotes {
    public static func url(deviceIdentifier: String, version: String) -> URL {
        if let article = articleID(deviceIdentifier: deviceIdentifier, version: version) {
            return URL(string: "https://support.apple.com/en-us/\(article)")!
        }
        var components = URLComponents(string: "https://support.apple.com/kb/index")!
        let major = Int(version.split(separator: ".").first ?? "") ?? 0
        let family = deviceIdentifier.hasPrefix("iPad") && major >= 13 ? "iPadOS" : "iOS"
        components.queryItems = [URLQueryItem(name: "page", value: "search"),
            URLQueryItem(name: "locale", value: "en_US"),
            URLQueryItem(name: "q", value: "\(family) \(version) updates")]
        return components.url!
    }

    public static func isDirectArticle(deviceIdentifier: String, version: String) -> Bool {
        articleID(deviceIdentifier: deviceIdentifier, version: version) != nil
    }

    private static func articleID(deviceIdentifier: String, version: String) -> String? {
        guard let component = version.split(separator: ".").first, let major = Int(component) else { return nil }
        let iphone = [13: "118392", 14: "118390", 15: "108051", 16: "101566",
                      17: "118723", 18: "121161", 26: "123075", 27: "149076"]
        let ipad = [14: "108057", 15: "108049", 16: "108050", 17: "118702",
                    18: "121162", 26: "123074", 27: "149075"]
        return deviceIdentifier.hasPrefix("iPad") && major >= 13 ? ipad[major] : iphone[major]
    }
}

public enum FirmwareHistoryError: LocalizedError {
    case invalidIdentifier, invalidResponse, wrongDevice, failedResponse, responseTooLarge, noReleases

    public var errorDescription: String? {
        switch self {
        case .invalidIdentifier: return "This device identifier is not an iPhone or iPad model."
        case .invalidResponse: return "IPSW.me returned an unexpected firmware history format. Try again later."
        case .wrongDevice: return "IPSW.me returned history for a different device. Try again later."
        case .failedResponse: return "Firmware history could not be retrieved from IPSW.me. Try again later."
        case .responseTooLarge: return "The firmware history response exceeded the expected size."
        case .noReleases: return "No public IPSW releases were found for this model."
        }
    }
}

private struct HistoryDocument: Decodable {
    let identifier: String
    let name: String
    let firmwares: [HistoryRecord]
}

private struct HistoryRecord: Decodable {
    let identifier: String?
    let version: String
    let buildid: String
    let releasedate: String?
    let filesize: Int64?
    let signed: Bool
    let beta: Bool?
    let url: String?
    let sha1sum: String?

    enum CodingKeys: String, CodingKey {
        case identifier, version, buildid, releasedate, filesize, signed, beta, url, sha1sum
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        identifier = try values.decodeIfPresent(String.self, forKey: .identifier)
        version = try values.decode(String.self, forKey: .version)
        buildid = try values.decode(String.self, forKey: .buildid)
        releasedate = try values.decodeIfPresent(String.self, forKey: .releasedate)
        filesize = try values.decodeIfPresent(Int64.self, forKey: .filesize)
        signed = try values.decode(Bool.self, forKey: .signed)
        beta = try values.decodeIfPresent(Bool.self, forKey: .beta)
        // Broken download-only metadata must not hide an otherwise usable
        // history/changelog entry or invalidate the complete device response.
        url = try? values.decode(String.self, forKey: .url)
        sha1sum = try? values.decode(String.self, forKey: .sha1sum)
    }
}

private final class HistoryRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static func permits(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.lowercased() == "api.ipsw.me"
            && url.user == nil && url.password == nil && (url.port == nil || url.port == 443)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.map(Self.permits) == true ? request : nil)
    }
}

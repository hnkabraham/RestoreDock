import Foundation

/// Discovers devices and restore images at runtime, without a baked-in iOS version.
/// Apple supplies public release eligibility, URLs, builds, and checksums. The
/// optional IPSW.me request supplies human-readable hardware names only.
public struct CatalogService: Sendable {
    public init() {}

    public func fetch() async throws -> CatalogSnapshot {
        async let restore = Self.load(URL(string: "https://itunes.apple.com/check/version")!)
        async let releases = Self.load(URL(string: "https://gdmf.apple.com/v2/pmv")!)
        async let names = Self.loadOptionalNames()
        let (restoreData, releaseData, nameData) = try await (restore, releases, names)
        return try Self.parse(restoreCatalog: restoreData, publicReleases: releaseData,
                              deviceNames: nameData)
    }

    /// A deterministic parser also usable for offline diagnostics and fixture tests.
    public static func parse(restoreCatalog: Data, publicReleases: Data,
                             deviceNames: Data? = nil, now: Date = Date()) throws -> CatalogSnapshot {
        guard let root = try PropertyListSerialization.propertyList(
            from: restoreCatalog, options: [], format: nil) as? [String: Any],
              let buckets = root["MobileDeviceSoftwareVersionsByVersion"] as? [String: Any]
        else { throw CatalogError.invalidRestoreCatalog }

        let releaseDocument = try JSONDecoder().decode(PublicReleaseDocument.self, from: publicReleases)
        // PublicAssetSets is Apple's publicly released inventory. AssetSets can
        // include additional software and is intentionally not used here.
        guard let allReleases = releaseDocument.publicAssetSets["iOS"] else {
            throw CatalogError.invalidPublicCatalog
        }
        let today = utcDay(now)
        let eligible = allReleases.filter { release in
            guard let posted = day(release.postingDate), posted <= today else { return false }
            if let expires = release.expirationDate, let expiry = day(expires), expiry < today {
                return false
            }
            return release.productVersionExtra == nil
        }
        var publicByDevice: [String: [PublicRelease]] = [:]
        for release in eligible {
            for identifier in release.supportedDevices where isSupportedFamily(identifier) {
                publicByDevice[identifier, default: []].append(release)
            }
        }
        guard !publicByDevice.isEmpty else { throw CatalogError.noPublicDevices }

        var names: [String: String] = [:]
        var warnings: [String] = []
        if let deviceNames, let records = try? JSONDecoder().decode([HardwareName].self, from: deviceNames) {
            for record in records where isSupportedFamily(record.identifier) && !record.name.isEmpty {
                names[record.identifier] = record.name
            }
        } else {
            warnings.append("Model names could not be refreshed from IPSW.me. Hardware identifiers are shown where needed; Apple firmware discovery is unaffected.")
        }

        var candidates: [String: [RestoreCandidate]] = [:]
        // Buckets represent client compatibility, not the iOS major version.
        // Inspect every bucket to cover both current and legacy hardware.
        for bucket in buckets.values {
            guard let value = bucket as? [String: Any],
                  let devices = value["MobileDeviceSoftwareVersions"] as? [String: Any] else { continue }
            for (identifier, entry) in devices where publicByDevice[identifier] != nil {
                candidates[identifier, default: []].append(contentsOf: restoreCandidates(in: entry))
            }
        }

        var devices: [DeviceFirmware] = []
        var missing: [String] = []
        var behind: [String] = []
        for identifier in publicByDevice.keys.sorted() {
            let releases = publicByDevice[identifier] ?? []
            let matching = (candidates[identifier] ?? []).filter { candidate in
                releases.contains { $0.productVersion == candidate.version && $0.build == candidate.build }
            }
            guard let selected = matching.max(by: { lhs, rhs in
                let order = lhs.version.compare(rhs.version, options: .numeric)
                if order != .orderedSame { return order == .orderedAscending }
                return lhs.build.compare(rhs.build, options: .numeric) == .orderedAscending
            }) else {
                missing.append(names[identifier] ?? identifier)
                continue
            }
            if releases.contains(where: { $0.productVersion.compare(selected.version, options: .numeric) == .orderedDescending }) {
                behind.append(names[identifier] ?? identifier)
            }
            let date = releases.filter { $0.productVersion == selected.version && $0.build == selected.build }
                .compactMap { day($0.postingDate) }.min()
            devices.append(DeviceFirmware(id: identifier, name: names[identifier] ?? identifier,
                                          version: selected.version, build: selected.build,
                                          downloadURL: selected.url, fileSize: selected.size,
                                          sha1: selected.sha1, releaseDate: date))
        }
        if !missing.isEmpty {
            warnings.append("Apple has not yet listed a matching HTTPS restore image for \(missing.count) supported model(s): \(missing.joined(separator: ", ")). A later refresh will try again.")
        }
        if !behind.isEmpty {
            warnings.append("Apple's restore catalog is still catching up with a newer public release for \(behind.count) model(s). The newest available public restore image is shown.")
        }
        guard !devices.isEmpty else { throw CatalogError.noMatchingRestoreImages }
        devices.sort {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
        return CatalogSnapshot(devices: devices, fetchedAt: now,
            sourceDescription: "Apple public releases + Apple restore catalog; model names from IPSW.me",
            warnings: warnings)
    }

    private static func isSupportedFamily(_ identifier: String) -> Bool {
        identifier.hasPrefix("iPhone") || identifier.hasPrefix("iPad")
    }

    private static func restoreCandidates(in node: Any) -> [RestoreCandidate] {
        guard let dictionary = node as? [String: Any] else { return [] }
        var result: [RestoreCandidate] = []
        if let restore = dictionary["Restore"] as? [String: Any],
           let version = restore["ProductVersion"] as? String, !version.isEmpty,
           let build = restore["BuildVersion"] as? String, !build.isEmpty,
           let rawURL = restore["FirmwareURL"] as? String,
           let url = URL(string: rawURL), AppleDownloadPolicy.permits(url),
           url.pathExtension.lowercased() == "ipsw" {
            let rawSHA1 = (restore["FirmwareSHA1"] as? String)?.lowercased()
            let sha1 = rawSHA1.flatMap { value -> String? in
                guard value.count == 40, value.unicodeScalars.allSatisfy({
                    (48...57).contains($0.value) || (97...102).contains($0.value)
                }) else { return nil }
                return value
            }
            let size = (restore["FirmwareSize"] as? NSNumber)?.int64Value
            result.append(RestoreCandidate(version: version, build: build, url: url,
                                           sha1: sha1, size: size.flatMap { $0 > 0 ? $0 : nil }))
        }
        for value in dictionary.values where value is [String: Any] {
            result.append(contentsOf: restoreCandidates(in: value))
        }
        return result
    }

    private static func loadOptionalNames() async -> Data? {
        try? await load(URL(string: "https://api.ipsw.me/v4/devices")!, namesOnly: true)
    }

    private static func load(_ url: URL, namesOnly: Bool = false) async throws -> Data {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = namesOnly ? 12 : 45
        config.timeoutIntervalForResource = namesOnly ? 15 : 75
        let delegate = CatalogRedirectGuard(namesOnly: namesOnly)
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("RestoreDock/1.6", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let finalURL = response.url, delegate.permits(finalURL) else {
            throw CatalogError.failedResponse(url.host ?? "catalog")
        }
        guard data.count <= 32 * 1_024 * 1_024 else { throw CatalogError.catalogTooLarge }
        return data
    }

    private static func day(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)
    }

    private static func utcDay(_ date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.startOfDay(for: date)
    }
}

public enum CatalogError: LocalizedError {
    case invalidRestoreCatalog
    case invalidPublicCatalog
    case noPublicDevices
    case noMatchingRestoreImages
    case failedResponse(String)
    case catalogTooLarge

    public var errorDescription: String? {
        switch self {
        case .invalidRestoreCatalog: return "Apple's restore catalog has an unexpected format. Try refreshing later."
        case .invalidPublicCatalog: return "Apple's public release catalog has an unexpected format. Try refreshing later."
        case .noPublicDevices: return "Apple's public catalog did not contain any current iPhone or iPad releases. The previous library has been kept."
        case .noMatchingRestoreImages: return "No current public restore images could be matched between Apple's catalogs. Try refreshing later."
        case .failedResponse(let host): return "The catalog request to \(host) did not return a valid HTTPS response."
        case .catalogTooLarge: return "The catalog response exceeded the expected size."
        }
    }
}

private struct HardwareName: Decodable {
    let identifier: String
    let name: String
}

private struct PublicReleaseDocument: Decodable {
    let publicAssetSets: [String: [PublicRelease]]
    enum CodingKeys: String, CodingKey { case publicAssetSets = "PublicAssetSets" }
}

private struct PublicRelease: Decodable {
    let productVersion: String
    let build: String
    let postingDate: String
    let expirationDate: String?
    let supportedDevices: [String]
    let productVersionExtra: String?
    enum CodingKeys: String, CodingKey {
        case productVersion = "ProductVersion", build = "Build", postingDate = "PostingDate"
        case expirationDate = "ExpirationDate", supportedDevices = "SupportedDevices"
        case productVersionExtra = "ProductVersionExtra"
    }
}

private struct RestoreCandidate {
    let version: String
    let build: String
    let url: URL
    let sha1: String?
    let size: Int64?
}

private final class CatalogRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let namesOnly: Bool
    init(namesOnly: Bool) { self.namesOnly = namesOnly }

    func permits(_ url: URL) -> Bool {
        if namesOnly {
            return url.scheme?.lowercased() == "https" && url.host?.lowercased() == "api.ipsw.me"
                && url.user == nil && url.password == nil && (url.port == nil || url.port == 443)
        }
        return AppleDownloadPolicy.permits(url)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.map(permits) == true ? request : nil)
    }
}

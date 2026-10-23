import Foundation

public enum DeviceSortOrder: String, Codable, CaseIterable, Identifiable, Sendable {
    case newest
    case name
    case followed

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .newest: return "Newest models"
        case .name: return "Name (A–Z)"
        case .followed: return "Followed first"
        }
    }
}

/// Model introduction metadata, independent of the firmware currently available.
/// The precision and source preserve the limits and provenance of historical dates.
public struct DeviceModelRecord: Codable, Equatable, Sendable {
    public let name: String
    public let identifiers: [String]
    public let introduced: String
    public let precision: String
    public let source: String

    public init(name: String, identifiers: [String], introduced: String,
                precision: String = "day", source: String) {
        self.name = name
        self.identifiers = identifiers
        self.introduced = introduced
        self.precision = precision
        self.source = source
    }
}

public enum DeviceSorter {
    /// All dates use ISO calendar order (YYYY-MM-DD), with unknown month/day set
    /// to 01 and their actual precision retained in the metadata.
    public static let bundledModels: [DeviceModelRecord] = loadBundledModels()
    private static let bundledIndex = index(bundledModels)

    public static func sort(_ devices: [DeviceFirmware], order: DeviceSortOrder,
                            followedIDs: Set<String>) -> [DeviceFirmware] {
        sort(devices, order: order, followedIDs: followedIDs, index: bundledIndex)
    }

    /// An explicit metadata collection also supports catalog validation and tests.
    public static func sort(_ devices: [DeviceFirmware], order: DeviceSortOrder,
                            followedIDs: Set<String>, models: [DeviceModelRecord]) -> [DeviceFirmware] {
        sort(devices, order: order, followedIDs: followedIDs, index: index(models))
    }

    public static func model(for identifier: String) -> DeviceModelRecord? {
        bundledIndex[identifier]
    }

    private static func sort(_ devices: [DeviceFirmware], order: DeviceSortOrder,
                             followedIDs: Set<String>, index: [String: DeviceModelRecord]) -> [DeviceFirmware] {
        devices.sorted { left, right in
            if order == .followed {
                let leftFollowed = followedIDs.contains(left.id)
                let rightFollowed = followedIDs.contains(right.id)
                if leftFollowed != rightFollowed { return leftFollowed }
            }

            let leftModel = index[left.id]
            let rightModel = index[right.id]
            if order != .name {
                let leftFamily = family(left.id)
                let rightFamily = family(right.id)
                if leftFamily != rightFamily { return leftFamily < rightFamily }

                // A newly discovered device must remain visible before bundled
                // introduction metadata catches up. An identifier is only a
                // deterministic fallback, never an inferred introduction date.
                if (leftModel == nil) != (rightModel == nil) { return leftModel == nil }
                if leftModel == nil, rightModel == nil, left.id != right.id {
                    return naturalCompare(left.id, right.id) == .orderedDescending
                }
                if let leftDate = leftModel?.introduced, let rightDate = rightModel?.introduced,
                   leftDate != rightDate {
                    return leftDate > rightDate
                }
            }

            // Compare the shared model name before a catalog's variant name:
            // "iPad (Cellular, 9th generation)" stays beside its Wi-Fi version.
            let groupComparison = naturalCompare(leftModel?.name ?? left.name,
                                                 rightModel?.name ?? right.name)
            if groupComparison != .orderedSame { return groupComparison == .orderedAscending }
            let leftVariant = variant(left.name)
            let rightVariant = variant(right.name)
            if leftVariant != rightVariant { return leftVariant < rightVariant }
            let nameComparison = naturalCompare(left.name, right.name)
            if nameComparison != .orderedSame { return nameComparison == .orderedAscending }
            return naturalCompare(left.id, right.id) == .orderedAscending
        }
    }

    private static func naturalCompare(_ left: String, _ right: String) -> ComparisonResult {
        let result = left.localizedStandardCompare(right)
        // Keep a total order for case/punctuation variants that a localized
        // comparison regards as equivalent.
        return result == .orderedSame ? left.compare(right) : result
    }

    private static func family(_ identifier: String) -> Int {
        if identifier.hasPrefix("iPhone") { return 0 }
        if identifier.hasPrefix("iPad") { return 1 }
        return 2
    }

    private static func variant(_ name: String) -> Int {
        let compact = name.lowercased().filter { $0.isLetter || $0.isNumber }
        if compact.contains("cellular") { return 2 }
        if compact.contains("wifi") { return 0 }
        return 1
    }

    private static func index(_ models: [DeviceModelRecord]) -> [String: DeviceModelRecord] {
        var result: [String: DeviceModelRecord] = [:]
        for model in models {
            for identifier in model.identifiers where result[identifier] == nil {
                result[identifier] = model
            }
        }
        return result
    }

    private static func loadBundledModels() -> [DeviceModelRecord] {
        let directory: URL?
        let packaged = Bundle.main.resourceURL?.appendingPathComponent("ModelOrder", isDirectory: true)
        if let packaged, FileManager.default.fileExists(atPath: packaged.path) {
            directory = packaged
        } else if Bundle.main.bundleURL.pathExtension != "app" {
            // A copied directory named Resources becomes the flat bundle's
            // resourceURL on macOS, so resolve from bundleURL to avoid adding
            // Resources twice.
            directory = Bundle.module.bundleURL.appendingPathComponent("Resources", isDirectory: true)
        } else {
            directory = nil
        }
        guard let directory else { return [] }
        return ["iPhoneModelOrder", "iPadModelOrder"].flatMap { name -> [DeviceModelRecord] in
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(name + ".json")),
                  let records = try? JSONDecoder().decode([DeviceModelRecord].self, from: data) else { return [] }
            return records
        }
    }
}

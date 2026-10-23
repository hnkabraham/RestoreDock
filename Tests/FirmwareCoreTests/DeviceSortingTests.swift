import Foundation
import XCTest
@testable import FirmwareCore

final class DeviceSortingTests: XCTestCase {
    func testNewestUsesModelIntroductionWithinYearRatherThanHardwareNumberOrFirmwareDate() {
        let earlier = device("iPhone40,1", "iPhone earlier", firmwareDate: "2026-12-01")
        let later = device("iPhone30,1", "iPhone later", firmwareDate: "2025-01-01")
        let models = [model("iPhone earlier", ids: [earlier.id], date: "2026-03-03"),
                      model("iPhone later", ids: [later.id], date: "2026-09-09")]
        XCTAssertEqual(sorted([earlier, later], models: models), [later.id, earlier.id])
    }

    func testNewestGroupsPhoneFamilyBeforeNewerIPad() {
        let phone = device("iPhone20,1", "iPhone")
        let pad = device("iPad20,1", "iPad")
        let models = [model("iPhone", ids: [phone.id], date: "2025-09-09"),
                      model("iPad", ids: [pad.id], date: "2026-03-03")]
        XCTAssertEqual(sorted([pad, phone], models: models), [phone.id, pad.id])
    }

    func testSameDayModelGroupsStayTogetherWithWiFiBeforeCellular() {
        let wifi = device("iPad12,1", "iPad (WiFi, 9th generation)")
        let cellular = device("iPad12,2", "iPad (Cellular, 9th generation)")
        let mini = device("iPad14,1", "iPad mini (6th generation)")
        let models = [model("iPad (9th generation)", ids: [wifi.id, cellular.id], date: "2021-09-14"),
                      model("iPad mini (6th generation)", ids: [mini.id], date: "2021-09-14")]
        for order in [DeviceSortOrder.newest, .name] {
            XCTAssertEqual(sorted([cellular, mini, wifi], order: order, models: models),
                           [wifi.id, cellular.id, mini.id])
        }
    }

    func testFollowedDevicesHaveGlobalPriorityThenUseNewestFamilyOrder() {
        let phoneOld = device("iPhone10,1", "Older phone")
        let phoneNew = device("iPhone20,1", "Newer phone")
        let padOld = device("iPad10,1", "Older tablet")
        let padNew = device("iPad20,1", "Newer tablet")
        let devices = [padNew, phoneNew, padOld, phoneOld]
        let models = [model("Older phone", ids: [phoneOld.id], date: "2017-09-12"),
                      model("Newer phone", ids: [phoneNew.id], date: "2025-09-09"),
                      model("Older tablet", ids: [padOld.id], date: "2020-03-18"),
                      model("Newer tablet", ids: [padNew.id], date: "2026-03-03")]
        XCTAssertEqual(sorted(devices, order: .followed, followed: [phoneOld.id, padOld.id], models: models),
                       [phoneOld.id, padOld.id, phoneNew.id, padNew.id])
        XCTAssertEqual(sorted(devices, order: .followed, followed: [padOld.id], models: models).first, padOld.id)
    }

    func testNameSortUsesNaturalNumbersAndGlobalAlphabeticalOrder() {
        let nine = device("iPhone11,1", "iPhone 9")
        let ten = device("iPhone10,1", "iPhone 10")
        let pad = device("iPad20,1", "iPad")
        XCTAssertEqual(sorted([ten, nine, pad], order: .name, models: []), [pad.id, nine.id, ten.id])
    }

    func testUnknownModelsStayVisibleFirstInTheirFamilyWithDeterministicNumericFallback() {
        let knownPhone = device("iPhone20,1", "Known phone")
        let unknownNine = device("iPhone999,9", "New phone")
        let unknownTen = device("iPhone999,10", "New phone")
        let knownPad = device("iPad20,1", "Known tablet")
        let unknownPad = device("iPad999,1", "New tablet")
        let models = [model("Known phone", ids: [knownPhone.id], date: "2025-09-09"),
                      model("Known tablet", ids: [knownPad.id], date: "2026-03-03")]
        let devices = [knownPad, unknownNine, unknownPad, knownPhone, unknownTen]
        let expected = [unknownTen.id, unknownNine.id, knownPhone.id, unknownPad.id, knownPad.id]
        XCTAssertEqual(sorted(devices, models: models), expected)
        XCTAssertEqual(sorted(Array(devices.reversed()), models: models), expected)
    }

    func testVariantAndIdentifierTiesAreStableRegardlessOfInputOrder() {
        let cellular = device("iPad99,3", "iPad (Wi-Fi + Cellular)")
        let wifiTwo = device("iPad99,2", "iPad (Wi-Fi)")
        let wifiOne = device("iPad99,1", "iPad (Wi-Fi)")
        let models = [model("iPad", ids: [cellular.id, wifiTwo.id, wifiOne.id], date: "2025-01-01")]
        let expected = [wifiOne.id, wifiTwo.id, cellular.id]
        XCTAssertEqual(sorted([cellular, wifiTwo, wifiOne], models: models), expected)
        XCTAssertEqual(sorted([wifiOne, wifiTwo, cellular], models: models), expected)
    }

    func testSortOrdersRoundTripStablePreferenceValues() throws {
        for order in DeviceSortOrder.allCases {
            XCTAssertEqual(try JSONDecoder().decode(DeviceSortOrder.self, from: JSONEncoder().encode(order)), order)
            XCTAssertFalse(order.title.isEmpty)
        }
    }

    func testBundledMetadataLoadsCompleteUniqueIdentifiersAndValidSourcedDates() throws {
        let models = DeviceSorter.bundledModels
        let identifiers = models.flatMap(\.identifiers)
        XCTAssertEqual(identifiers.filter { $0.hasPrefix("iPhone") }.count, 67)
        XCTAssertEqual(identifiers.filter { $0.hasPrefix("iPad") }.count, 105)
        XCTAssertEqual(Set(identifiers).count, identifiers.count, "Each hardware identifier must belong to one model group.")

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        for record in models {
            XCTAssertFalse(record.name.isEmpty)
            XCTAssertFalse(record.identifiers.isEmpty, record.name)
            XCTAssertTrue(["day", "month", "year"].contains(record.precision), record.name)
            let date = try XCTUnwrap(formatter.date(from: record.introduced), record.name)
            XCTAssertEqual(formatter.string(from: date), record.introduced, record.name)
            let source = try XCTUnwrap(URL(string: record.source), record.name)
            XCTAssertEqual(source.scheme, "https", record.name)
            let host = try XCTUnwrap(source.host, record.name)
            XCTAssertTrue(host == "apple.com" || host.hasSuffix(".apple.com"), record.name)
        }
    }

    func testBundledModelDatesOrderDifferentIPadFamiliesAndMidCycleIPhone() {
        let padIdentifiers = ["iPad16,3", "iPad17,1", "iPad16,1", "iPad16,8"]
        let pads = padIdentifiers.map { device($0, $0) }
        XCTAssertEqual(DeviceSorter.sort(pads, order: .newest, followedIDs: []).map(\.id),
                       ["iPad16,8", "iPad17,1", "iPad16,1", "iPad16,3"],
                       "Air M4 is newer than Pro M5; mini A17 Pro is newer than Pro M4.")
        let phones = [device("iPhone17,3", "iPhone 16"), device("iPhone17,5", "iPhone 16e")]
        XCTAssertEqual(DeviceSorter.sort(phones, order: .newest, followedIDs: []).map(\.id),
                       ["iPhone17,5", "iPhone17,3"])
    }

    private func sorted(_ devices: [DeviceFirmware], order: DeviceSortOrder = .newest,
                        followed: Set<String> = [], models: [DeviceModelRecord]) -> [String] {
        DeviceSorter.sort(devices, order: order, followedIDs: followed, models: models).map(\.id)
    }

    private func model(_ name: String, ids: [String], date: String) -> DeviceModelRecord {
        DeviceModelRecord(name: name, identifiers: ids, introduced: date,
                          source: "https://www.apple.com/newsroom/")
    }

    private func device(_ id: String, _ name: String, firmwareDate: String = "2026-10-01") -> DeviceFirmware {
        DeviceFirmware(id: id, name: name, version: "26.0", build: "23A1",
                       downloadURL: URL(string: "https://updates.cdn-apple.com/test.ipsw")!,
                       releaseDate: ISO8601DateFormatter().date(from: firmwareDate + "T00:00:00Z"))
    }
}

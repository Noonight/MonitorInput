import Foundation
import XCTest

final class MonitorPreferencesTests: XCTestCase {
    func testAutomaticMirroringIsOptInAndPersistsAcrossLaunches() throws {
        let (defaults, domain) = try testDefaults()
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = MonitorPreferences(defaults: defaults)
        XCTAssertFalse(preferences.mirrorsOtherInputs)
        preferences.mirrorsOtherInputs = true
        XCTAssertTrue(MonitorPreferences(defaults: defaults).mirrorsOtherInputs)
    }

    func testLeftClickDefaultsToMacAndTheMenuPreferencePersists() throws {
        let (defaults, domain) = try testDefaults()
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = MonitorPreferences(defaults: defaults)
        XCTAssertEqual(preferences.leftClickAction, .selectMac)
        preferences.leftClickAction = .showMenu
        XCTAssertEqual(MonitorPreferences(defaults: defaults).leftClickAction, .showMenu)
    }

    func testAnUnreadableInputDoesNotOverwriteTheLastVerifiedInput() throws {
        let (defaults, domain) = try testDefaults()
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = MonitorPreferences(defaults: defaults)
        let verifiedAt = Date(timeIntervalSince1970: 100)
        let identity = DisplayIdentity(fingerprint: "monitor-edid", serialNumber: 123)
        let connection = MonitorConnection(identity: identity, registryID: 1)
        preferences.remember(MonitorReading(connection: connection, input: .displayPort), at: verifiedAt)
        preferences.remember(
            MonitorReading(connection: connection, input: nil),
            at: verifiedAt.addingTimeInterval(15)
        )
        XCTAssertEqual(
            MonitorPreferences(defaults: defaults).lastSeen,
            LastMonitorState(identity: identity, input: .displayPort, observedAt: verifiedAt)
        )
    }

    func testAnUnreadableInputOnADifferentMonitorDoesNotInheritAnOldInput() throws {
        let (defaults, domain) = try testDefaults()
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = MonitorPreferences(defaults: defaults)
        let old = DisplayIdentity(fingerprint: "original", serialNumber: 123)
        let replacement = DisplayIdentity(fingerprint: "replacement", serialNumber: 456)
        let date = Date(timeIntervalSince1970: 100)
        preferences.remember(
            MonitorReading(connection: MonitorConnection(identity: old, registryID: 1), input: .usbC),
            at: date
        )
        preferences.remember(
            MonitorReading(connection: MonitorConnection(identity: replacement, registryID: 2), input: nil),
            at: date
        )
        XCTAssertEqual(preferences.lastSeen, LastMonitorState(identity: replacement, input: nil, observedAt: date))
    }

    private func testDefaults() throws -> (UserDefaults, String) {
        let domain = "local.monitorinput.test.\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: domain)), domain)
    }
}

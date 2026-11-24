import Foundation
import XCTest

final class MonitorPreferencesTests: XCTestCase {
    func testEnglishAndRussianTranslationsAreBundled() {
        let bundle = Bundle(for: MonitorPreferencesTests.self)
        XCTAssertTrue(Set(["en", "ru"]).isSubset(of: Set(bundle.localizations)), "\(bundle.localizations)")
    }

    func testAppLanguageDefaultsToSystemAndPersistsAnOverride() throws {
        let (defaults, domain) = try testDefaults()
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = MonitorPreferences(defaults: defaults)
        XCTAssertEqual(preferences.language, .system)

        preferences.language = .russian
        XCTAssertEqual(MonitorPreferences(defaults: defaults).language, .russian)
        preferences.language = .english
        XCTAssertEqual(MonitorPreferences(defaults: defaults).language, .english)
        preferences.language = .system
        XCTAssertEqual(MonitorPreferences(defaults: defaults).language, .system)
    }

    func testLanguageOverrideSelectsTranslationsAndFormatsArguments() {
        let bundle = Bundle(for: MonitorPreferencesTests.self)
        let russian = AppLocalization(language: .russian, bundle: bundle)
        let english = AppLocalization(language: .english, bundle: bundle)

        XCTAssertEqual(russian.text("MonitorInput Settings"), "Настройки MonitorInput")
        XCTAssertEqual(english.text("MonitorInput Settings"), "MonitorInput Settings")
        XCTAssertEqual(russian.text("Input %@", "0x1B"), "Вход 0x1B")
        XCTAssertEqual(english.text("Input %@", "0x1B"), "Input 0x1B")
    }

    func testSystemLanguageFollowsBundleLocalization() {
        let bundle = Bundle(for: MonitorPreferencesTests.self)
        let system = AppLocalization(language: .system, bundle: bundle)
        let expected = bundle.preferredLocalizations.first == "ru" ? "Настройки…" : "Settings…"
        XCTAssertEqual(system.text("Settings…"), expected)
    }

    func testCustomNamesAndMacInputAreStoredPerDisplay() throws {
        let (defaults, domain) = try testDefaults()
        defer { defaults.removePersistentDomain(forName: domain) }
        let first = DisplayIdentity(fingerprint: "first", serialNumber: 10)
        let second = DisplayIdentity(fingerprint: "second", serialNumber: 20)
        let preferences = MonitorPreferences(defaults: defaults)
        preferences.assignMacInput(.hdmi2, for: first)
        preferences.renameInput(.displayPort, for: first, to: " Linux ")
        preferences.renameInput(.displayPort, for: second, to: "Консоль")
        preferences.preferredMonitor = second.fingerprint

        let reloaded = MonitorPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.configuration(for: first).macInput, .hdmi2)
        XCTAssertEqual(reloaded.configuration(for: first).aliases[0x0F], "Linux")
        XCTAssertEqual(reloaded.configuration(for: second).aliases[0x0F], "Консоль")
        XCTAssertNil(reloaded.configuration(for: second).macInput)
        XCTAssertEqual(reloaded.preferredMonitor, second.fingerprint)

        reloaded.renameInput(.displayPort, for: first, to: " ")
        XCTAssertNil(reloaded.configuration(for: first).aliases[0x0F])
    }

    func testOldHuaweiCacheRetainsMacUsbCOnUpgrade() throws {
        let (defaults, domain) = try testDefaults()
        defer { defaults.removePersistentDomain(forName: domain) }
        let legacy = #"{"identity":{"fingerprint":"existing-edid","serialNumber":42},"input":15,"observedAt":100}"#
        defaults.set(Data(legacy.utf8), forKey: "lastMonitorState")
        let preferences = MonitorPreferences(defaults: defaults)
        let huawei = DisplayIdentity(
            fingerprint: "existing-edid",
            serialNumber: 42,
            product: DisplayProduct(vendorID: 0x22F6, modelID: 0x6A25, name: "ZQE-CAA")
        )
        XCTAssertEqual(preferences.configuration(for: huawei).macInput, .usbC)
        XCTAssertEqual(preferences.configuration(for: huawei).observedInputs, [.displayPort])
        XCTAssertNil(preferences.configuration(for: DisplayIdentity(fingerprint: "new", serialNumber: nil)).macInput)
        XCTAssertEqual(preferences.lastSeen?.input, .displayPort)
    }

    func testManuallySelectedInputIsAvailableWhenCapabilitiesAreMissing() {
        var configuration = MonitorConfiguration()
        configuration.observedInputs = [.hdmi1]
        XCTAssertEqual(configuration.inputs(advertised: [], profile: nil), [.hdmi1])
        XCTAssertEqual(configuration.inputs(advertised: [.displayPort], profile: nil), [.hdmi1, .displayPort])
    }

    func testUpdatingAMonitorWithHiddenInputsKeepsVisibilityAndOtherProfiles() throws {
        let (defaults, domain) = try testDefaults()
        defer { defaults.removePersistentDomain(forName: domain) }
        let first = DisplayIdentity(fingerprint: "first", serialNumber: 10)
        let second = DisplayIdentity(fingerprint: "second", serialNumber: 20)
        let stored = """
        {
          "first": {"macInput":16,"aliases":[],"observedInputs":[15,16,17,18],"hiddenInputs":[17,18]},
          "second": {"macInput":15,"aliases":[],"observedInputs":[15,16]}
        }
        """
        defaults.set(Data(stored.utf8), forKey: "monitorConfigurations")
        let preferences = MonitorPreferences(defaults: defaults)
        preferences.renameInput(.displayPort, for: first, to: "Windows")

        let data = try XCTUnwrap(defaults.data(forKey: "monitorConfigurations"))
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: [String: Any]])
        XCTAssertEqual(Set(encoded["first"]?["hiddenInputs"] as? [Int] ?? []), [17, 18])
        let reloaded = MonitorPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.configuration(for: first).aliases[15], "Windows")
        XCTAssertEqual(reloaded.configuration(for: first).macInput, .usbC)
        XCTAssertEqual(reloaded.configuration(for: second).macInput, .displayPort)
        XCTAssertTrue(reloaded.configuration(for: second).isInputVisible(.hdmi1))
    }

    func testHidingAnInputOnlyAffectsTheMenuAndCanBeUndone() throws {
        let (defaults, domain) = try testDefaults()
        defer { defaults.removePersistentDomain(forName: domain) }
        let monitor = DisplayIdentity(fingerprint: "monitor", serialNumber: 10)
        let preferences = MonitorPreferences(defaults: defaults)
        preferences.assignMacInput(.usbC, for: monitor)
        preferences.setInputVisibility(.usbC, visible: false, for: monitor)
        preferences.setInputVisibility(.usbC, visible: false, for: monitor)

        let reloaded = MonitorPreferences(defaults: defaults)
        let configuration = reloaded.configuration(for: monitor)
        XCTAssertFalse(configuration.isInputVisible(.usbC))
        XCTAssertTrue(configuration.isInputVisible(.displayPort))
        XCTAssertEqual(configuration.macInput, .usbC)
        XCTAssertEqual(configuration.inputs(advertised: [.displayPort], profile: nil), [.usbC, .displayPort])

        reloaded.setInputVisibility(.usbC, visible: true, for: monitor)
        XCTAssertTrue(MonitorPreferences(defaults: defaults).configuration(for: monitor).isInputVisible(.usbC))
    }

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

    func testSavedToggleModeIsRestored() throws {
        let (defaults, domain) = try testDefaults()
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set("toggleInputs", forKey: "leftClickAction")

        XCTAssertEqual(MonitorPreferences(defaults: defaults).leftClickAction, .toggleInputs)
    }

    func testTogglePairPersistsPerMonitorAndDoesNotReplaceTheMacInput() throws {
        let (defaults, domain) = try testDefaults()
        defer { defaults.removePersistentDomain(forName: domain) }
        let first = DisplayIdentity(fingerprint: "first", serialNumber: 10)
        let second = DisplayIdentity(fingerprint: "second", serialNumber: 20)
        let preferences = MonitorPreferences(defaults: defaults)
        let pair = InputTogglePair(first: .usbC, second: .displayPort)
        preferences.assignMacInput(.hdmi1, for: first)
        preferences.setToggleInputs(pair, for: first)
        preferences.setToggleInputs(InputTogglePair(first: .hdmi2, second: nil), for: second)
        preferences.leftClickAction = .toggleInputs

        let reloaded = MonitorPreferences(defaults: defaults)
        let configuration = reloaded.configuration(for: first)
        XCTAssertEqual(reloaded.leftClickAction, .toggleInputs)
        XCTAssertEqual(configuration.toggleInputs, pair)
        XCTAssertEqual(configuration.selection(for: reloaded.leftClickAction),
                       .alternate(first: .usbC, second: .displayPort))
        XCTAssertEqual(configuration.selection(for: .selectMac), .fixed(.hdmi1))
        XCTAssertNil(configuration.selection(for: .showMenu))
        XCTAssertEqual(configuration.inputs(advertised: [], profile: nil), [.usbC, .displayPort, .hdmi1])
        XCTAssertEqual(reloaded.configuration(for: second).toggleInputs, InputTogglePair(first: .hdmi2, second: nil))
        XCTAssertNil(reloaded.configuration(for: second).selection(for: .toggleInputs))

        reloaded.setToggleInputs(InputTogglePair(first: .usbC, second: .usbC), for: first)
        XCTAssertEqual(MonitorPreferences(defaults: defaults).configuration(for: first).toggleInputs, pair)
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

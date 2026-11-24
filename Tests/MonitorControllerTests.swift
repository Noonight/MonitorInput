import XCTest

final class MonitorControllerTests: XCTestCase {
    func testSelectingMacWhileItIsAlreadyShownSendsNoWrite() {
        let reading = makeReading(.usbC)
        let monitor = StubTransport([.connected(reading)])
        let result = select(.usbC, on: monitor)
        XCTAssertEqual(result, .alreadySelected(reading))
        XCTAssertEqual(result.status, .connected(reading))
        XCTAssertEqual(monitor.probeCount, 1)
        XCTAssertTrue(monitor.requests.isEmpty)
    }

    func testNoWriteWithoutAnUnambiguousLiveInput() {
        for status in [MonitorStatus.disconnected, .unavailable, .ambiguous, .connected(makeReading(nil))] {
            let monitor = StubTransport([status])
            XCTAssertEqual(select(.usbC, on: monitor), .blocked(status))
            XCTAssertTrue(monitor.requests.isEmpty, "\(status)")
        }
    }

    func testAlternatingReadsTheActiveInputForBothDirections() {
        let mac = makeReading(.usbC)
        let windows = makeReading(.displayPort)
        let monitor = StubTransport([.connected(mac), .connected(windows), .connected(windows), .connected(mac)])
        let controller = MonitorController(transport: monitor, pause: { _ in })
        let selection = InputSelection.alternate(first: .usbC, second: .displayPort)
        let allowed: Set<DisplayInput> = [.usbC, .displayPort]

        XCTAssertEqual(controller.select(
            selection, allowed: allowed, expected: mac.connection, preferredFingerprint: nil
        ).result, .selected(windows))
        XCTAssertEqual(controller.select(
            selection, allowed: allowed, expected: mac.connection, preferredFingerprint: nil
        ).result, .selected(mac))
        XCTAssertEqual(monitor.requests, [
            .init(target: .displayPort, connection: mac.connection),
            .init(target: .usbC, connection: mac.connection)
        ])
    }

    func testAlternatingSelectsFirstConfiguredPortFromAnInputOutsideThePair() {
        let mac = makeReading(.usbC)
        let hdmi = makeReading(.hdmi1)
        let monitor = StubTransport([.connected(mac), .connected(hdmi)])
        let result = MonitorController(transport: monitor, pause: { _ in }).select(
            .alternate(first: .hdmi1, second: .displayPort), allowed: [.hdmi1, .displayPort],
            expected: mac.connection, preferredFingerprint: nil
        )

        XCTAssertEqual(result.result, .selected(hdmi))
        XCTAssertEqual(monitor.requests, [.init(target: .hdmi1, connection: mac.connection)])
    }

    func testAlternatingDoesNotGuessWhenTheActiveInputIsUnreadable() {
        let unknown = makeReading(nil)
        let monitor = StubTransport([.connected(unknown)])
        let result = MonitorController(transport: monitor, pause: { _ in }).select(
            .alternate(first: .usbC, second: .displayPort), allowed: [.usbC, .displayPort],
            expected: unknown.connection, preferredFingerprint: nil
        )

        XCTAssertEqual(result.result, .blocked(.connected(unknown)))
        XCTAssertTrue(monitor.requests.isEmpty)
    }

    func testAlternatingRequiresTwoDistinctAllowedPorts() {
        let mac = makeReading(.usbC)
        let monitor = StubTransport([.connected(mac)])
        let controller = MonitorController(transport: monitor, pause: { _ in })

        XCTAssertEqual(controller.select(
            .alternate(first: .usbC, second: .displayPort), allowed: [.displayPort],
            expected: mac.connection, preferredFingerprint: nil
        ).result, .blocked(.connected(mac)))
        XCTAssertEqual(controller.select(
            .alternate(first: .displayPort, second: .displayPort), allowed: [.usbC, .displayPort],
            expected: mac.connection, preferredFingerprint: nil
        ).result, .blocked(.connected(mac)))
        XCTAssertTrue(monitor.requests.isEmpty)
    }

    func testReadbackConfirmsAMacSwitchAfterATransientDisconnect() {
        let windows = makeReading(.displayPort)
        let mac = makeReading(.usbC)
        let monitor = StubTransport([.connected(windows), .disconnected, .connected(mac)])
        XCTAssertEqual(select(.usbC, on: monitor), .selected(mac))
        XCTAssertEqual(monitor.requests, [.init(target: .usbC, connection: windows.connection)])
    }

    func testReturningToTheMacRetriesATransientReadFailureBeforeAnyWrite() {
        let displayPort = makeReading(.displayPort)
        let usbC = makeReading(.usbC)
        let monitor = StubTransport([.unavailable, .connected(displayPort), .connected(usbC)])
        XCTAssertEqual(select(.usbC, on: monitor), .selected(usbC))
        XCTAssertEqual(monitor.requests, [.init(target: .usbC, connection: displayPort.connection)])
    }

    func testUnchangedSourceStopsAfterTwoWrites() {
        let windows = makeReading(.displayPort)
        let monitor = StubTransport([.connected(windows)])
        XCTAssertEqual(select(.usbC, on: monitor), .unconfirmed(.connected(windows)))
        XCTAssertEqual(monitor.requests, Array(repeating: .init(target: .usbC, connection: windows.connection), count: 2))
    }

    func testUnavailableInputAfterTheFirstWriteCannotAuthorizeARetry() {
        let monitor = StubTransport([.connected(makeReading(.usbC)), .connected(makeReading(nil))])
        XCTAssertEqual(select(.displayPort, on: monitor), .unconfirmed(.connected(makeReading(nil))))
        XCTAssertEqual(monitor.requests.count, 1)
    }

    func testNeverRetriesAWriteOnANewEndpoint() {
        let first = makeReading(.usbC)
        let replacement = makeReading(.usbC, registryID: 78)
        let monitor = StubTransport([.connected(first), .connected(replacement)])
        XCTAssertEqual(select(.displayPort, on: monitor), .unconfirmed(.connected(replacement)))
        XCTAssertEqual(monitor.requests, [.init(target: .displayPort, connection: first.connection)])
    }

    func testReadbackOnTheSameMonitorSurvivesReenumerationWithoutAnotherWrite() {
        let first = makeReading(.usbC)
        let reenumerated = makeReading(.displayPort, registryID: 78)
        let monitor = StubTransport([.connected(first), .connected(reenumerated)])
        let outcome = MonitorController(transport: monitor, pause: { _ in }).select(
            .fixed(.displayPort), allowed: [.displayPort], expected: first.connection, preferredFingerprint: nil
        )
        XCTAssertEqual(outcome.result, .selected(reenumerated))
        XCTAssertEqual(outcome.inventory.connections, [reenumerated.connection])
        XCTAssertEqual(monitor.requests, [.init(target: .displayPort, connection: first.connection)])
    }

    func testASelectionFromAnOldMenuDoesNotWriteToAReconnectedMonitor() {
        let previous = makeReading(.usbC).connection
        let reconnected = makeReading(.usbC, registryID: 78)
        let monitor = StubTransport([.connected(reconnected)])
        XCTAssertEqual(select(.displayPort, on: monitor, expected: previous), .blocked(.connected(reconnected)))
        XCTAssertTrue(monitor.requests.isEmpty)
    }

    func testSelectingWindowsKeepsAnHDMIInputDistinctUntilTheMonitorChanges() {
        let hdmi = makeReading(.hdmi1)
        let windows = makeReading(.displayPort)
        let monitor = StubTransport([.connected(hdmi), .connected(windows)])
        XCTAssertEqual(select(.displayPort, on: monitor), .selected(windows))
        XCTAssertEqual(monitor.requests, [.init(target: .displayPort, connection: hdmi.connection)])
    }

    func testAnUnlistedCodeCannotBeWritten() throws {
        let reading = makeReading(.usbC)
        let monitor = StubTransport([.connected(reading)])
        let code = try XCTUnwrap(DisplayInput(rawValue: 0x1B))
        XCTAssertEqual(select(code, on: monitor), .blocked(.connected(reading)))
        XCTAssertTrue(monitor.requests.isEmpty)
    }

    func testASupportedCodeCanBeSelectedEvenWithoutAPredefinedPortName() throws {
        let initial = makeReading(.usbC)
        let code = try XCTUnwrap(DisplayInput(rawValue: 0x1B))
        let selected = makeReading(code)
        let monitor = StubTransport([.connected(initial), .connected(selected)])
        let fingerprint = initial.connection.identity.fingerprint
        XCTAssertEqual(select(code, on: monitor, allowed: [code], preferredFingerprint: fingerprint), .selected(selected))
        XCTAssertEqual(monitor.requests, [.init(target: code, connection: initial.connection)])
        XCTAssertEqual(monitor.probeSelections, [fingerprint, fingerprint])
        XCTAssertEqual(monitor.writeSelections, [fingerprint])
    }

    func testAutoSelectionStopsWhenAnotherDisplayAppearsBeforeVerification() {
        let first = makeReading(.usbC)
        let monitor = StubTransport([.connected(first), .ambiguous])
        XCTAssertEqual(select(.displayPort, on: monitor), .unconfirmed(.ambiguous))
        XCTAssertEqual(monitor.probeSelections, [nil, nil])
        XCTAssertEqual(monitor.writeSelections, [nil])
    }

    func testAutoSelectionRequiresOneUnambiguousDisplay() {
        let connection = makeReading(nil).connection
        let fingerprint = connection.identity.fingerprint
        let second = MonitorConnection(
            identity: DisplayIdentity(fingerprint: "another-display", serialNumber: nil), registryID: 85
        )
        let multiple = MonitorInventory(connections: [connection, second], hasUnreadableDisplays: false)
        let partial = MonitorInventory(connections: [connection], hasUnreadableDisplays: true)
        XCTAssertEqual(multiple.resolve(preferredFingerprint: nil), .ambiguous)
        XCTAssertEqual(partial.resolve(preferredFingerprint: nil), .unavailable)
        XCTAssertEqual(multiple.resolve(preferredFingerprint: fingerprint), .connected(makeReading(nil)))
        XCTAssertEqual(partial.resolve(preferredFingerprint: fingerprint), .connected(makeReading(nil)))
    }

    func testMirroringNeedsAUniqueModelAndSerialAmongDiscoveredMonitors() {
        let product = DisplayProduct(vendorID: 42, modelID: 255, name: "Test")
        let first = DisplayIdentity(fingerprint: "first-display", serialNumber: 10, product: product)
        let second = DisplayIdentity(fingerprint: "second-display", serialNumber: 10, product: product)
        let a = MonitorConnection(identity: first, registryID: 80)
        let b = MonitorConnection(identity: second, registryID: 81)
        XCTAssertTrue(MonitorInventory(connections: [a], hasUnreadableDisplays: false).hasUniqueDisplayMatch(for: first))
        XCTAssertFalse(MonitorInventory(connections: [a, b], hasUnreadableDisplays: false).hasUniqueDisplayMatch(for: first))
    }

    private func select(
        _ target: DisplayInput, on transport: StubTransport,
        allowed: Set<DisplayInput> = [.displayPort, .usbC, .hdmi1, .hdmi2], expected: MonitorConnection? = nil,
        preferredFingerprint: String? = nil
    ) -> SwitchResult {
        MonitorController(transport: transport, pause: { _ in }).select(
            .fixed(target), allowed: allowed, expected: expected ?? makeReading(nil).connection,
            preferredFingerprint: preferredFingerprint
        ).result
    }

    private func makeReading(_ input: DisplayInput?, registryID: UInt64 = 77) -> MonitorReading {
        MonitorReading(
            connection: MonitorConnection(
                identity: DisplayIdentity(fingerprint: "monitor-id", serialNumber: 2026),
                registryID: registryID
            ),
            input: input
        )
    }
}

private final class StubTransport: MonitorTransport {
    struct Request: Equatable {
        let target: DisplayInput
        let connection: MonitorConnection
    }

    private let statuses: [MonitorStatus]
    private(set) var probeCount = 0
    private(set) var requests: [Request] = []
    private(set) var probeSelections: [String?] = []
    private(set) var writeSelections: [String?] = []

    init(_ statuses: [MonitorStatus]) {
        self.statuses = statuses
    }

    func probe(preferredFingerprint: String?) -> (inventory: MonitorInventory, status: MonitorStatus) {
        probeSelections.append(preferredFingerprint)
        defer { probeCount += 1 }
        let status = statuses[min(probeCount, statuses.count - 1)]
        let connections: [MonitorConnection]
        if case .connected(let reading) = status {
            connections = [reading.connection]
        } else {
            connections = []
        }
        return (MonitorInventory(connections: connections, hasUnreadableDisplays: status == .unavailable), status)
    }

    func requestInput(_ target: DisplayInput, on connection: MonitorConnection, preferredFingerprint: String?) {
        writeSelections.append(preferredFingerprint)
        requests.append(Request(target: target, connection: connection))
    }
}

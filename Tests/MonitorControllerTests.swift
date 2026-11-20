import XCTest

final class MonitorControllerTests: XCTestCase {
    func testSelectingMacWhileItIsAlreadyShownSendsNoWrite() {
        let reading = makeReading(.usbC)
        let monitor = StubTransport([.connected(reading)])
        let result = controller(monitor).select(.mac)
        XCTAssertEqual(result, .alreadySelected(reading))
        XCTAssertEqual(result.status, .connected(reading))
        XCTAssertEqual(monitor.probeCount, 1)
        XCTAssertTrue(monitor.requests.isEmpty)
    }

    func testNoWriteWithoutAnUnambiguousLiveInput() {
        for status in [MonitorStatus.disconnected, .unavailable, .ambiguous, .connected(makeReading(nil))] {
            let monitor = StubTransport([status])
            XCTAssertEqual(controller(monitor).select(.mac), .blocked(status))
            XCTAssertTrue(monitor.requests.isEmpty, "\(status)")
        }
    }

    func testReadbackConfirmsAMacSwitchAfterATransientDisconnect() {
        let windows = makeReading(.displayPort)
        let mac = makeReading(.usbC)
        let monitor = StubTransport([.connected(windows), .disconnected, .connected(mac)])
        XCTAssertEqual(controller(monitor).select(.mac), .selected(mac))
        XCTAssertEqual(monitor.requests, [.init(target: .mac, connection: windows.connection)])
    }

    func testUnchangedSourceStopsAfterTwoWrites() {
        let windows = makeReading(.displayPort)
        let monitor = StubTransport([.connected(windows)])
        XCTAssertEqual(controller(monitor).select(.mac), .unconfirmed(.connected(windows)))
        XCTAssertEqual(monitor.requests, Array(repeating: .init(target: .mac, connection: windows.connection), count: 2))
    }

    func testUnavailableInputAfterTheFirstWriteCannotAuthorizeARetry() {
        let monitor = StubTransport([.connected(makeReading(.usbC)), .connected(makeReading(nil))])
        XCTAssertEqual(controller(monitor).select(.windows), .unconfirmed(.connected(makeReading(nil))))
        XCTAssertEqual(monitor.requests.count, 1)
    }

    func testNeverRetriesAWriteOnANewEndpoint() {
        let first = makeReading(.usbC)
        let replacement = makeReading(.usbC, registryID: 78)
        let monitor = StubTransport([.connected(first), .connected(replacement)])
        XCTAssertEqual(controller(monitor).select(.windows), .unconfirmed(.connected(replacement)))
        XCTAssertEqual(monitor.requests, [.init(target: .windows, connection: first.connection)])
    }

    func testReadbackOnTheSameMonitorSurvivesReenumerationWithoutAnotherWrite() {
        let first = makeReading(.usbC)
        let reenumerated = makeReading(.displayPort, registryID: 78)
        let monitor = StubTransport([.connected(first), .connected(reenumerated)])
        XCTAssertEqual(controller(monitor).select(.windows), .selected(reenumerated))
        XCTAssertEqual(monitor.requests, [.init(target: .windows, connection: first.connection)])
    }

    func testASelectionFromAnOldMenuDoesNotWriteToAReconnectedMonitor() {
        let previous = makeReading(.usbC).connection
        let reconnected = makeReading(.usbC, registryID: 78)
        let monitor = StubTransport([.connected(reconnected)])
        XCTAssertEqual(controller(monitor).select(.windows, expected: previous), .blocked(.connected(reconnected)))
        XCTAssertTrue(monitor.requests.isEmpty)
    }

    func testSelectingWindowsKeepsAnHDMIInputDistinctUntilTheMonitorChanges() {
        let hdmi = makeReading(.hdmi1)
        let windows = makeReading(.displayPort)
        let monitor = StubTransport([.connected(hdmi), .connected(windows)])
        XCTAssertEqual(controller(monitor).select(.windows), .selected(windows))
        XCTAssertEqual(monitor.requests, [.init(target: .windows, connection: hdmi.connection)])
    }

    private func controller(_ transport: StubTransport) -> MonitorController {
        MonitorController(transport: transport, pause: { _ in })
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
        let target: SwitchTarget
        let connection: MonitorConnection
    }

    private let statuses: [MonitorStatus]
    private(set) var probeCount = 0
    private(set) var requests: [Request] = []

    init(_ statuses: [MonitorStatus]) {
        self.statuses = statuses
    }

    func probe() -> MonitorStatus {
        defer { probeCount += 1 }
        return statuses[min(probeCount, statuses.count - 1)]
    }

    func requestInput(_ target: SwitchTarget, on connection: MonitorConnection) {
        requests.append(Request(target: target, connection: connection))
    }
}

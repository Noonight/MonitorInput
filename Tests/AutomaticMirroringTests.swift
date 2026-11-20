import XCTest

final class AutomaticMirroringTests: XCTestCase {
    private let identity = DisplayIdentity(fingerprint: "huawei-edid", serialNumber: 32)

    func testEachVerifiedNonMacInputMirrorsTheIdentifiedMonitor() {
        for input in [DisplayInput.displayPort, .hdmi1, .hdmi2] {
            let desktop = RecordingDesktop()
            let mirroring = AutomaticMirroring(desktop: desktop)
            XCTAssertEqual(mirroring.update(status(input), enabled: true), .active)
            XCTAssertEqual(desktop.calls, [.mirror(identity)])
        }
    }

    func testReturningToUsbCRestoresTheLayout() {
        let desktop = RecordingDesktop()
        let mirroring = AutomaticMirroring(desktop: desktop)
        _ = mirroring.update(status(.displayPort), enabled: true)
        XCTAssertEqual(mirroring.update(status(.usbC), enabled: true), .inactive)
        XCTAssertEqual(desktop.calls, [.mirror(identity), .restore])
    }

    func testUnknownOrAmbiguousInputDoesNotReconfigureTheDesktop() {
        let desktop = RecordingDesktop()
        let mirroring = AutomaticMirroring(desktop: desktop)
        for unverified in [nil, .disconnected, .unavailable, .ambiguous, status(nil)] as [MonitorStatus?] {
            XCTAssertNil(mirroring.update(unverified, enabled: true))
        }
        XCTAssertTrue(desktop.calls.isEmpty)
    }

    func testTurningOffRestoresWithoutWaitingForTheMonitor() {
        let desktop = RecordingDesktop()
        let mirroring = AutomaticMirroring(desktop: desktop)
        XCTAssertEqual(mirroring.update(nil, enabled: false), .inactive)
        XCTAssertEqual(desktop.calls, [.restore])
    }

    func testAReportedWindowsInputDoesNotMirrorWithTheSettingOff() {
        let desktop = RecordingDesktop()
        let mirroring = AutomaticMirroring(desktop: desktop)
        XCTAssertEqual(mirroring.update(status(.displayPort), enabled: false), .inactive)
        XCTAssertEqual(desktop.calls, [.restore])
    }

    private func status(_ input: DisplayInput?) -> MonitorStatus {
        let connection = MonitorConnection(identity: identity, registryID: 50)
        return .connected(MonitorReading(connection: connection, input: input))
    }
}

private final class RecordingDesktop: DesktopMirroring {
    enum Call: Equatable {
        case mirror(DisplayIdentity)
        case restore
    }

    private(set) var calls: [Call] = []

    func mirrorHuawei(_ identity: DisplayIdentity) -> DesktopMirrorState {
        calls.append(.mirror(identity))
        return .active
    }

    func restoreLayout() -> DesktopMirrorState {
        calls.append(.restore)
        return .inactive
    }
}

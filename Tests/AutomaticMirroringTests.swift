import XCTest

final class AutomaticMirroringTests: XCTestCase {
    private let identity = DisplayIdentity(fingerprint: "huawei-edid", serialNumber: 32)

    func testEachVerifiedNonMacInputMirrorsTheIdentifiedMonitor() {
        for input in [DisplayInput.displayPort, .hdmi1, .hdmi2] {
            let desktop = RecordingDesktop()
            let mirroring = AutomaticMirroring(desktop: desktop)
            XCTAssertEqual(mirroring.update(status(input), enabled: true, macInput: .usbC, hasUniqueDisplayMatch: true), .active)
            XCTAssertEqual(desktop.calls, [.mirror(identity)])
        }
    }

    func testReturningToUsbCRestoresTheLayout() {
        let desktop = RecordingDesktop()
        let mirroring = AutomaticMirroring(desktop: desktop)
        _ = mirroring.update(status(.displayPort), enabled: true, macInput: .usbC, hasUniqueDisplayMatch: true)
        XCTAssertEqual(mirroring.update(status(.usbC), enabled: true, macInput: .usbC), .inactive)
        XCTAssertEqual(desktop.calls, [.mirror(identity), .restore])
    }

    func testAnUnknownInputDoesNotReconfigureTheDesktop() {
        let desktop = RecordingDesktop()
        let mirroring = AutomaticMirroring(desktop: desktop)
        for unverified in [nil, .disconnected, .unavailable, status(nil)] as [MonitorStatus?] {
            XCTAssertNil(mirroring.update(unverified, enabled: true, macInput: .usbC))
        }
        XCTAssertTrue(desktop.calls.isEmpty)
    }

    func testLosingAutomaticSelectionRestoresTheOwnedLayout() {
        let desktop = RecordingDesktop()
        let mirroring = AutomaticMirroring(desktop: desktop)
        _ = mirroring.update(status(.displayPort), enabled: true, macInput: .usbC, hasUniqueDisplayMatch: true)
        XCTAssertEqual(mirroring.update(.ambiguous, enabled: true, macInput: .usbC), .inactive)
        XCTAssertEqual(desktop.calls, [.mirror(identity), .restore])
    }

    func testAnUncertainDisplayMatchNeverStartsMirroring() {
        let desktop = RecordingDesktop()
        let mirroring = AutomaticMirroring(desktop: desktop)
        XCTAssertEqual(mirroring.update(status(.displayPort), enabled: true, macInput: .usbC), .unavailable)
        XCTAssertEqual(desktop.calls, [.restore])
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

    func testTheConfiguredMacInputCanBeDisplayPort() {
        let desktop = RecordingDesktop()
        let mirroring = AutomaticMirroring(desktop: desktop)
        XCTAssertEqual(mirroring.update(status(.usbC), enabled: true, macInput: .displayPort, hasUniqueDisplayMatch: true), .active)
        XCTAssertEqual(mirroring.update(status(.displayPort), enabled: true, macInput: .displayPort), .inactive)
        XCTAssertEqual(desktop.calls, [.mirror(identity), .restore])
    }

    func testNoMacInputConfiguredDoesNotMirror() {
        let desktop = RecordingDesktop()
        let mirroring = AutomaticMirroring(desktop: desktop)
        XCTAssertEqual(mirroring.update(status(.displayPort), enabled: true), .inactive)
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

    func mirrorDisplay(_ identity: DisplayIdentity) -> DesktopMirrorState {
        calls.append(.mirror(identity))
        return .active
    }

    func restoreLayout() -> DesktopMirrorState {
        calls.append(.restore)
        return .inactive
    }
}

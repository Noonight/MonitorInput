enum DesktopMirrorState: Equatable {
    case inactive
    case active
    case unavailable
    case restoreFailed
}

protocol DesktopMirroring {
    func mirrorHuawei(_ identity: DisplayIdentity) -> DesktopMirrorState
    func restoreLayout() -> DesktopMirrorState
}

struct AutomaticMirroring {
    let desktop: any DesktopMirroring

    func update(_ status: MonitorStatus?, enabled: Bool) -> DesktopMirrorState? {
        guard enabled else { return desktop.restoreLayout() }
        guard case .connected(let reading) = status, let input = reading.input else { return nil }

        switch input {
        case .usbC:
            return desktop.restoreLayout()
        case .displayPort, .hdmi1, .hdmi2:
            return desktop.mirrorHuawei(reading.connection.identity)
        }
    }
}

enum DesktopMirrorState: Equatable {
    case inactive
    case active
    case unavailable
    case restoreFailed
}

protocol DesktopMirroring {
    func mirrorDisplay(_ identity: DisplayIdentity) -> DesktopMirrorState
    func restoreLayout() -> DesktopMirrorState
}

struct AutomaticMirroring {
    let desktop: any DesktopMirroring

    func update(
        _ status: MonitorStatus?, enabled: Bool, macInput: DisplayInput? = nil, hasUniqueDisplayMatch: Bool = false
    ) -> DesktopMirrorState? {
        guard enabled else { return desktop.restoreLayout() }
        if status == .ambiguous { return desktop.restoreLayout() }
        guard case .connected(let reading) = status, let input = reading.input else { return nil }

        guard let macInput, input != macInput else { return desktop.restoreLayout() }
        guard hasUniqueDisplayMatch else {
            return desktop.restoreLayout() == .restoreFailed ? .restoreFailed : .unavailable
        }
        return desktop.mirrorDisplay(reading.connection.identity)
    }
}

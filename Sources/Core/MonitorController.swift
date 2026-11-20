import Foundation

struct MonitorConnection: Equatable, Sendable {
    let identity: DisplayIdentity
    let registryID: UInt64
}

struct MonitorReading: Equatable, Sendable {
    let connection: MonitorConnection
    let input: DisplayInput?
}

enum MonitorStatus: Equatable, Sendable {
    case disconnected
    case unavailable
    case ambiguous
    case connected(MonitorReading)
}

struct MonitorInventory: Sendable {
    let connections: [MonitorConnection]
    let hasUnreadableDisplays: Bool

    func resolve(preferredFingerprint: String?) -> MonitorStatus {
        let matches = preferredFingerprint.map { fingerprint in
            connections.filter { $0.identity.fingerprint == fingerprint }
        } ?? connections
        guard let candidate = matches.first else {
            return hasUnreadableDisplays ? .unavailable : .disconnected
        }
        guard matches.count == 1 else { return .ambiguous }
        guard preferredFingerprint != nil || !hasUnreadableDisplays else { return .unavailable }
        return .connected(MonitorReading(connection: candidate, input: nil))
    }

    func hasUniqueDisplayMatch(for identity: DisplayIdentity) -> Bool {
        guard !hasUnreadableDisplays, let product = identity.product, let serial = identity.serialNumber
        else { return false }
        let matching = connections.filter {
            $0.identity.product?.vendorID == product.vendorID
                && $0.identity.product?.modelID == product.modelID
                && $0.identity.serialNumber == serial
        }
        return matching.count == 1 && matching.first?.identity == identity
    }
}

struct MonitorScan: Sendable {
    let inventory: MonitorInventory
    let status: MonitorStatus
    let advertisedInputs: Set<DisplayInput>
}

enum SwitchResult: Equatable, Sendable {
    case selected(MonitorReading)
    case alreadySelected(MonitorReading)
    case blocked(MonitorStatus)
    case unconfirmed(MonitorStatus)

    var status: MonitorStatus {
        switch self {
        case .selected(let reading), .alreadySelected(let reading): .connected(reading)
        case .blocked(let status), .unconfirmed(let status): status
        }
    }
}

protocol MonitorTransport {
    func probe(preferredFingerprint: String?) -> (inventory: MonitorInventory, status: MonitorStatus)
    func requestInput(_ target: DisplayInput, on connection: MonitorConnection, preferredFingerprint: String?)
}

struct MonitorController {
    let transport: any MonitorTransport
    var pause: (TimeInterval) -> Void = Thread.sleep(forTimeInterval:)

    func select(
        _ target: DisplayInput, allowed: Set<DisplayInput>, expected: MonitorConnection, preferredFingerprint: String?
    ) -> (result: SwitchResult, inventory: MonitorInventory) {
        var probe = transport.probe(preferredFingerprint: preferredFingerprint)
        for delay in [0.15, 0.35] {
            guard probe.status.needsInputRetry else { break }
            pause(delay)
            probe = transport.probe(preferredFingerprint: preferredFingerprint)
        }
        guard case .connected(let initial) = probe.status,
              let input = initial.input, initial.connection == expected, allowed.contains(target)
        else { return (.blocked(probe.status), probe.inventory) }

        if input == target { return (.alreadySelected(initial), probe.inventory) }

        // USB-C can be unavailable briefly during the display's input change.
        // Poll before retrying, and never retry against a different endpoint.
        for _ in 0..<2 {
            guard case .connected(let reading) = probe.status, reading.input != nil else { break }
            transport.requestInput(target, on: initial.connection, preferredFingerprint: preferredFingerprint)
            for delay in [0.25, 0.50, 0.75, 1.0] {
                pause(delay)
                probe = transport.probe(preferredFingerprint: preferredFingerprint)
                switch probe.status {
                case .connected(let verified):
                    if verified.connection.identity == initial.connection.identity, verified.input == target {
                        return (.selected(verified), probe.inventory)
                    }
                    guard verified.connection == initial.connection else {
                        return (.unconfirmed(probe.status), probe.inventory)
                    }
                case .ambiguous:
                    return (.unconfirmed(probe.status), probe.inventory)
                case .disconnected, .unavailable:
                    continue
                }
            }
        }
        return (.unconfirmed(probe.status), probe.inventory)
    }
}

private extension MonitorStatus {
    var needsInputRetry: Bool {
        switch self {
        case .unavailable: true
        case .connected(let reading): reading.input == nil
        case .disconnected, .ambiguous: false
        }
    }
}

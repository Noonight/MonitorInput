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
    func probe() -> MonitorStatus
    func requestInput(_ target: SwitchTarget, on connection: MonitorConnection)
}

struct MonitorController {
    let transport: any MonitorTransport
    var pause: (TimeInterval) -> Void = Thread.sleep(forTimeInterval:)

    func select(_ target: SwitchTarget, expected: MonitorConnection? = nil) -> SwitchResult {
        var status = transport.probe()
        guard case .connected(let initial) = status,
              let input = initial.input, expected == nil || expected == initial.connection
        else { return .blocked(status) }

        if input == target.input { return .alreadySelected(initial) }

        // USB-C can be unavailable briefly during the display's input change.
        // Poll before retrying, and never retry against a different endpoint.
        for _ in 0..<2 {
            guard case .connected(let reading) = status, reading.input != nil else { break }
            transport.requestInput(target, on: initial.connection)
            for delay in [0.25, 0.50, 0.75, 1.0] {
                pause(delay)
                status = transport.probe()
                switch status {
                case .connected(let verified):
                    if verified.connection.identity == initial.connection.identity, verified.input == target.input {
                        return .selected(verified)
                    }
                    guard verified.connection == initial.connection else { return .unconfirmed(status) }
                case .ambiguous:
                    return .unconfirmed(status)
                case .disconnected, .unavailable:
                    continue
                }
            }
        }
        return .unconfirmed(status)
    }
}

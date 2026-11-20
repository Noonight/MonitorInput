import Foundation

enum LeftClickAction: String {
    case selectMac
    case showMenu
}

struct LastMonitorState: Codable, Equatable {
    let identity: DisplayIdentity
    let input: DisplayInput?
    let observedAt: Date
}

final class MonitorPreferences {
    private let defaults: UserDefaults
    private static let leftClickKey = "leftClickAction"
    private static let mirrorKey = "mirrorsOtherInputs"
    private let lastSeenKey = "lastMonitorState"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var leftClickAction: LeftClickAction {
        get { defaults.string(forKey: Self.leftClickKey).flatMap(LeftClickAction.init(rawValue:)) ?? .selectMac }
        set { defaults.set(newValue.rawValue, forKey: Self.leftClickKey) }
    }

    var mirrorsOtherInputs: Bool {
        get { defaults.bool(forKey: Self.mirrorKey) }
        set { defaults.set(newValue, forKey: Self.mirrorKey) }
    }

    var lastSeen: LastMonitorState? {
        guard let data = defaults.data(forKey: lastSeenKey) else { return nil }
        return try? JSONDecoder().decode(LastMonitorState.self, from: data)
    }

    func remember(_ reading: MonitorReading, at date: Date = Date()) {
        let identity = reading.connection.identity
        if reading.input == nil, let previous = lastSeen, previous.identity == identity, previous.input != nil {
            return
        }
        let record = LastMonitorState(identity: identity, input: reading.input, observedAt: date)
        if let data = try? JSONEncoder().encode(record) {
            defaults.set(data, forKey: lastSeenKey)
        }
    }
}

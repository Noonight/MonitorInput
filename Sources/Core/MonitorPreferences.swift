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

struct MonitorConfiguration: Codable {
    var macInput: DisplayInput?
    var aliases: [UInt8: String] = [:]
    var observedInputs: Set<DisplayInput> = []
    var lastSeen: LastMonitorState?
    var hiddenInputs: Set<DisplayInput>?

    func inputs(advertised: Set<DisplayInput>, profile: MonitorProfile?) -> Set<DisplayInput> {
        var inputs = observedInputs.union(advertised)
        if let profile { inputs.formUnion(profile.ports.keys) }
        if let macInput { inputs.insert(macInput) }
        return inputs
    }

    func isInputVisible(_ input: DisplayInput) -> Bool {
        hiddenInputs?.contains(input) != true
    }
}

final class MonitorPreferences {
    private let defaults: UserDefaults
    private static let leftClickKey = "leftClickAction"
    private static let mirrorKey = "mirrorsOtherInputs"
    private static let lastSeenKey = "lastMonitorState"
    private static let monitorKey = "monitorConfigurations"
    private static let preferredKey = "preferredMonitor"
    private var configurations: [String: MonitorConfiguration]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        configurations = defaults.data(forKey: Self.monitorKey).flatMap {
            try? JSONDecoder().decode([String: MonitorConfiguration].self, from: $0)
        } ?? [:]
        if let old = decodeLastSeen(), old.identity.product == nil,
           configurations[old.identity.fingerprint] == nil {
            // Before model discovery, the app only saved data for ZQE-CAA over USB-C.
            configurations[old.identity.fingerprint] = MonitorConfiguration(
                macInput: DisplayInput(rawValue: 0x10),
                observedInputs: Set([old.input].compactMap { $0 }),
                lastSeen: old
            )
            saveConfigurations()
        }
    }

    var leftClickAction: LeftClickAction {
        get { defaults.string(forKey: Self.leftClickKey).flatMap(LeftClickAction.init(rawValue:)) ?? .selectMac }
        set { defaults.set(newValue.rawValue, forKey: Self.leftClickKey) }
    }

    var mirrorsOtherInputs: Bool {
        get { defaults.bool(forKey: Self.mirrorKey) }
        set { defaults.set(newValue, forKey: Self.mirrorKey) }
    }

    var preferredMonitor: String? {
        get { defaults.string(forKey: Self.preferredKey) }
        set { defaults.set(newValue, forKey: Self.preferredKey) }
    }

    var lastSeen: LastMonitorState? {
        if let preferredMonitor { return configurations[preferredMonitor]?.lastSeen }
        return decodeLastSeen()
    }

    private func decodeLastSeen() -> LastMonitorState? {
        guard let data = defaults.data(forKey: Self.lastSeenKey) else { return nil }
        return try? JSONDecoder().decode(LastMonitorState.self, from: data)
    }

    func configuration(for identity: DisplayIdentity) -> MonitorConfiguration {
        configurations[identity.fingerprint] ?? MonitorConfiguration()
    }

    func assignMacInput(_ input: DisplayInput, for identity: DisplayIdentity) {
        var config = configuration(for: identity)
        config.macInput = input
        config.observedInputs.insert(input)
        configurations[identity.fingerprint] = config
        saveConfigurations()
    }

    func renameInput(_ input: DisplayInput, for identity: DisplayIdentity, to title: String) {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var config = configuration(for: identity)
        let alias = name.isEmpty ? nil : String(name.prefix(60))
        guard config.aliases[input.rawValue] != alias else { return }
        config.aliases[input.rawValue] = alias
        configurations[identity.fingerprint] = config
        saveConfigurations()
    }

    func setInputVisibility(_ input: DisplayInput, visible: Bool, for identity: DisplayIdentity) {
        var config = configuration(for: identity)
        guard config.isInputVisible(input) != visible else { return }
        var hidden = config.hiddenInputs ?? []
        if visible {
            hidden.remove(input)
        } else {
            hidden.insert(input)
        }
        config.hiddenInputs = hidden.isEmpty ? nil : hidden
        configurations[identity.fingerprint] = config
        saveConfigurations()
    }

    func remember(_ reading: MonitorReading, at date: Date = Date()) {
        let identity = reading.connection.identity
        var config = configuration(for: identity)
        if let input = reading.input {
            config.observedInputs.insert(input)
        }
        if reading.input != nil || config.lastSeen?.input == nil {
            config.lastSeen = LastMonitorState(identity: identity, input: reading.input, observedAt: date)
        }
        configurations[identity.fingerprint] = config
        saveConfigurations()
        if let record = config.lastSeen, let data = try? JSONEncoder().encode(record) {
            defaults.set(data, forKey: Self.lastSeenKey)
        }
    }

    private func saveConfigurations() {
        if let data = try? JSONEncoder().encode(configurations) {
            defaults.set(data, forKey: Self.monitorKey)
        }
    }
}

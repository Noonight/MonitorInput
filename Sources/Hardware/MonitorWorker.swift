import Dispatch

actor MonitorWorker {
    private let queue = DispatchSerialQueue(label: "local.monitorinput.ddc", qos: .userInitiated)
    private let transport = DDCTransport()
    private var capabilities: (connection: MonitorConnection, inputs: Set<DisplayInput>?, attemptedAt: ContinuousClock.Instant)?

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    func scan(preferredFingerprint: String?) -> MonitorScan {
        let (inventory, status) = transport.probe(preferredFingerprint: preferredFingerprint)
        var inputs: Set<DisplayInput> = []
        if case .connected(let reading) = status {
            if capabilities?.connection != reading.connection { capabilities = nil }
            let canRetry = capabilities.map { $0.attemptedAt.duration(to: .now) >= .seconds(60) } ?? true
            if reading.input != nil, capabilities?.inputs == nil, canRetry {
                let advertised = transport.advertisedInputs(on: reading.connection)
                capabilities = (reading.connection, advertised, .now)
            }
            inputs = capabilities?.inputs ?? []
        }
        return MonitorScan(inventory: inventory, status: status, advertisedInputs: inputs)
    }

    func select(
        _ target: DisplayInput, allowed: Set<DisplayInput>, expected: MonitorConnection, preferredFingerprint: String?
    ) -> (result: SwitchResult, inventory: MonitorInventory) {
        MonitorController(transport: transport).select(
            target, allowed: allowed, expected: expected, preferredFingerprint: preferredFingerprint
        )
    }
}

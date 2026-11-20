import Dispatch

actor MonitorWorker {
    private let queue = DispatchSerialQueue(label: "local.monitorinput.ddc", qos: .userInitiated)
    private let controller = MonitorController(transport: HuaweiTransport())

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    func probe() -> MonitorStatus {
        controller.transport.probe()
    }

    func select(_ target: SwitchTarget, expected: MonitorConnection?) -> SwitchResult {
        controller.select(target, expected: expected)
    }
}

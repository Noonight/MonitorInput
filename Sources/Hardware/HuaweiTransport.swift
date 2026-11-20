import Darwin
import Foundation
import IOKit

struct HuaweiTransport: MonitorTransport {
    private let io = AVAccess()

    func probe() -> MonitorStatus {
        switch findEndpoint() {
        case .found(let endpoint):
            .connected(MonitorReading(connection: endpoint.connection, input: readInput(from: endpoint)))
        case .disconnected: .disconnected
        case .unavailable: .unavailable
        case .ambiguous: .ambiguous
        }
    }

    func requestInput(_ target: SwitchTarget, on connection: MonitorConnection) {
        guard let io, case .found(let endpoint) = findEndpoint(), endpoint.connection == connection,
              let currentInput = readInput(from: endpoint), currentInput != target.input,
              identity(at: endpoint.service, io: io) == connection.identity
        else { return }

        // This is the only setting write. The frame cannot encode a different VCP feature.
        _ = io.send(DisplayProtocol.setInputFrame(target), to: endpoint.service)
    }

    private func findEndpoint() -> Discovery {
        guard let io else { return .unavailable }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator
        ) == KERN_SUCCESS else { return .unavailable }
        defer { IOObjectRelease(iterator) }

        var match: Endpoint?
        var unreadable = false
        while true {
            let entry = IOIteratorNext(iterator)
            guard entry != IO_OBJECT_NULL else { break }
            defer { IOObjectRelease(entry) }

            let location = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, nil, 0)?
                .takeRetainedValue() as? String
            guard location == "External" else { continue }

            var registryID: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(entry, &registryID) == KERN_SUCCESS,
                  let service = io.open(entry),
                  let edid = io.read(from: service, address: 0x50, offset: 0, count: 128),
                  DisplayProtocol.isValidBaseEDID(edid)
            else {
                unreadable = true
                continue
            }
            guard let identity = DisplayProtocol.huaweiIdentity(in: edid) else { continue }
            if match != nil { return .ambiguous }
            match = Endpoint(connection: MonitorConnection(identity: identity, registryID: registryID), service: service)
        }

        // An unreadable display cannot be ruled out as a second Huawei.
        if unreadable { return .unavailable }
        if let match { return .found(match) }
        return .disconnected
    }

    private func identity(at service: AVService, io: AVAccess) -> DisplayIdentity? {
        guard let edid = io.read(from: service, address: 0x50, offset: 0, count: 128) else { return nil }
        return DisplayProtocol.huaweiIdentity(in: edid)
    }

    private func readInput(from endpoint: Endpoint) -> DisplayInput? {
        guard let io else { return nil }
        for _ in 0..<2 {
            guard io.send(DisplayProtocol.getInputFrame, to: endpoint.service) else { continue }
            Thread.sleep(forTimeInterval: 0.050)
            if let reply = io.read(from: endpoint.service, address: 0x37, offset: 0x51, count: 12),
               let input = DisplayProtocol.selectedInput(in: reply) {
                return input
            }
        }
        return nil
    }

    private struct Endpoint {
        let connection: MonitorConnection
        let service: AVService
    }

    private enum Discovery {
        case found(Endpoint)
        case disconnected
        case unavailable
        case ambiguous
    }
}

private final class AVService {
    let reference: UnsafeMutableRawPointer

    init(_ reference: UnsafeMutableRawPointer) {
        self.reference = reference
    }

    deinit {
        Unmanaged<AnyObject>.fromOpaque(reference).release()
    }
}

private final class AVAccess {
    // The IOAV I2C entry points have no public header. Load by name so that a
    // system that removes them can still launch the app and show "unavailable".
    private typealias CreateService = @convention(c) (UnsafeRawPointer?, io_service_t) -> UnsafeMutableRawPointer?
    private typealias ReadI2C = @convention(c) (
        UnsafeMutableRawPointer, UInt32, UInt32, UnsafeMutableRawPointer, UInt32
    ) -> IOReturn
    private typealias WriteI2C = @convention(c) (
        UnsafeMutableRawPointer, UInt32, UInt32, UnsafeRawPointer, UInt32
    ) -> IOReturn

    private let framework: UnsafeMutableRawPointer
    private let createService: CreateService
    private let readI2C: ReadI2C
    private let writeI2C: WriteI2C

    init?() {
        guard let framework = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW | RTLD_LOCAL)
        else { return nil }
        guard let create = dlsym(framework, "IOAVServiceCreateWithService"),
              let read = dlsym(framework, "IOAVServiceReadI2C"),
              let write = dlsym(framework, "IOAVServiceWriteI2C")
        else {
            dlclose(framework)
            return nil
        }
        self.framework = framework
        self.createService = unsafeBitCast(create, to: CreateService.self)
        self.readI2C = unsafeBitCast(read, to: ReadI2C.self)
        self.writeI2C = unsafeBitCast(write, to: WriteI2C.self)
    }

    deinit {
        dlclose(framework)
    }

    func open(_ entry: io_service_t) -> AVService? {
        createService(nil, entry).map(AVService.init)
    }

    func read(from service: AVService, address: UInt32, offset: UInt32, count: Int) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: count)
        let result = bytes.withUnsafeMutableBytes { buffer -> IOReturn in
            guard let start = buffer.baseAddress else { return kIOReturnBadArgument }
            return readI2C(service.reference, address, offset, start, UInt32(buffer.count))
        }
        return result == KERN_SUCCESS ? bytes : nil
    }

    func send(_ frame: [UInt8], to service: AVService) -> Bool {
        frame.withUnsafeBytes { buffer in
            guard let start = buffer.baseAddress else { return false }
            return writeI2C(service.reference, 0x37, 0x51, start, UInt32(buffer.count)) == KERN_SUCCESS
        }
    }
}

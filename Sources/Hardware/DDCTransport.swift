import Darwin
import Foundation
import IOKit

struct DDCTransport: MonitorTransport {
    private let io = AVAccess()

    func probe(preferredFingerprint: String?) -> (inventory: MonitorInventory, status: MonitorStatus) {
        let discovery = discover()
        let inventory = discovery.inventory
        let status = inventory.resolve(preferredFingerprint: preferredFingerprint)
        guard case .connected(let target) = status,
              let endpoint = discovery.endpoints.first(where: { $0.connection == target.connection })
        else { return (inventory, status) }
        return (inventory, .connected(MonitorReading(connection: target.connection, input: readInput(from: endpoint))))
    }

    func advertisedInputs(on connection: MonitorConnection) -> Set<DisplayInput>? {
        guard let io, let endpoint = boundEndpoint(connection, preferredFingerprint: connection.identity.fingerprint)
        else { return nil }
        var bytes: [UInt8] = []
        for _ in 0..<66 {
            let offset = UInt16(bytes.count)
            guard let reply = readDDC(
                DisplayProtocol.capabilitiesRequest(offset: offset), from: endpoint, count: 38, io: io
            ), let fragment = DisplayProtocol.capabilitiesFragment(in: reply, offset: offset) else { return nil }

            let end = fragment.firstIndex(of: 0)
            bytes.append(contentsOf: fragment[..<(end ?? fragment.endIndex)])
            guard bytes.count <= 2048 else { return nil }
            if fragment.isEmpty || end != nil {
                guard let capabilities = String(bytes: bytes, encoding: .ascii) else { return nil }
                let codes = DDCCapabilities.inputValues(in: capabilities)
                return Set(codes.compactMap(DisplayInput.init(rawValue:)))
            }
        }
        return nil
    }

    func requestInput(_ target: DisplayInput, on connection: MonitorConnection, preferredFingerprint: String?) {
        guard let io, let endpoint = boundEndpoint(connection, preferredFingerprint: preferredFingerprint),
              let currentInput = readInput(from: endpoint), currentInput != target,
              identity(at: endpoint.service, io: io) == connection.identity
        else { return }

        // This is the only setting write. The frame cannot encode a different VCP feature.
        _ = io.send(DisplayProtocol.setInputFrame(target), to: endpoint.service)
    }

    private func boundEndpoint(_ connection: MonitorConnection, preferredFingerprint: String?) -> Endpoint? {
        let discovery = discover()
        guard case .connected(let selected) = discovery.inventory.resolve(preferredFingerprint: preferredFingerprint),
              selected.connection == connection
        else { return nil }
        return discovery.endpoints.first { $0.connection == connection }
    }

    private func discover() -> Discovery {
        guard let io else { return Discovery(endpoints: [], hasUnreadableDisplays: true) }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator
        ) == KERN_SUCCESS else { return Discovery(endpoints: [], hasUnreadableDisplays: true) }
        defer { IOObjectRelease(iterator) }

        var endpoints: [Endpoint] = []
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
                  let identity = identity(at: service, io: io)
            else {
                unreadable = true
                continue
            }
            endpoints.append(Endpoint(connection: MonitorConnection(identity: identity, registryID: registryID), service: service))
        }
        return Discovery(endpoints: endpoints, hasUnreadableDisplays: unreadable)
    }

    private func identity(at service: AVService, io: AVAccess) -> DisplayIdentity? {
        guard let edid = io.read(from: service, address: 0x50, offset: 0, count: 128) else { return nil }
        return DisplayProtocol.identity(in: edid)
    }

    private func readInput(from endpoint: Endpoint) -> DisplayInput? {
        guard let io else { return nil }
        for _ in 0..<2 {
            if let reply = readDDC(DisplayProtocol.getInputFrame, from: endpoint, count: 12, io: io),
               let input = DisplayProtocol.selectedInput(in: reply) {
                return input
            }
        }
        return nil
    }

    private func readDDC(_ request: [UInt8], from endpoint: Endpoint, count: Int, io: AVAccess) -> [UInt8]? {
        guard io.send(request, to: endpoint.service) else { return nil }
        Thread.sleep(forTimeInterval: 0.050)
        return io.read(from: endpoint.service, address: 0x37, offset: 0x51, count: count)
    }

    private struct Endpoint {
        let connection: MonitorConnection
        let service: AVService
    }

    private struct Discovery {
        let endpoints: [Endpoint]
        let hasUnreadableDisplays: Bool

        var inventory: MonitorInventory {
            MonitorInventory(connections: endpoints.map(\.connection), hasUnreadableDisplays: hasUnreadableDisplays)
        }
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

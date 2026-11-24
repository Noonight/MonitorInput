import Foundation

struct MonitorProfile {
    let vendorID: UInt32
    let modelID: UInt32
    let name: String
    let ports: [DisplayInput: String]

    func matches(_ product: DisplayProduct) -> Bool {
        product.vendorID == vendorID && product.modelID == modelID
    }

    static func portName(for input: DisplayInput) -> String? {
        switch input.rawValue {
        case 0x01: "VGA"
        case 0x03: "DVI 1"
        case 0x04: "DVI 2"
        case 0x0F: "DisplayPort 1"
        case 0x10: "DisplayPort 2"
        case 0x11: "HDMI 1"
        case 0x12: "HDMI 2"
        default: nil
        }
    }
}

struct MonitorProfiles {
    private let entries: [MonitorProfile]

    init(data: Data) {
        let records = (try? JSONDecoder().decode([Record].self, from: data)) ?? []
        entries = records.compactMap { record in
            guard let vendor = UInt16(record.vendorID, radix: 16), let model = UInt16(record.modelID, radix: 16),
                  !record.name.isEmpty else { return nil }
            var ports: [DisplayInput: String] = [:]
            for (code, title) in record.ports {
                guard code.count == 2, let byte = UInt8(code, radix: 16),
                      let input = DisplayInput(rawValue: byte), !title.isEmpty else { continue }
                ports[input] = title
            }
            return MonitorProfile(vendorID: UInt32(vendor), modelID: UInt32(model), name: record.name, ports: ports)
        }
    }

    static func bundled() -> MonitorProfiles {
        let url = Bundle.main.url(forResource: "MonitorProfiles", withExtension: "json")
        let data = url.flatMap { try? Data(contentsOf: $0) } ?? Data()
        return MonitorProfiles(data: data)
    }

    func profile(for identity: DisplayIdentity) -> MonitorProfile? {
        guard let product = identity.product else { return nil }
        return entries.first { $0.matches(product) }
    }

    private struct Record: Decodable {
        let vendorID: String
        let modelID: String
        let name: String
        let ports: [String: String]
    }
}

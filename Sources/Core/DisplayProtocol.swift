import CryptoKit
import Foundation

struct DisplayIdentity: Codable, Equatable, Sendable {
    let fingerprint: String
    let serialNumber: UInt32?
}

enum DisplayInput: UInt8, Codable, Sendable {
    case displayPort = 15
    case usbC = 16
    case hdmi1 = 17
    case hdmi2 = 18
}

enum SwitchTarget: UInt8, Sendable {
    case windows = 15
    case mac = 16

    var input: DisplayInput { self == .mac ? .usbC : .displayPort }
}

enum DisplayProtocol {
    static let modelName = "ZQE-CAA"
    static let vendorID: UInt32 = 0x22F6 // HWV
    static let modelID: UInt32 = 0x6A25
    private static let inputFeature: UInt8 = 0x60
    private static let monitorAddress: UInt8 = 0x6E
    private static let hostAddress: UInt8 = 0x51
    private static let replyChecksumAddress: UInt8 = 0x50

    static let getInputFrame = requestFrame([0x82, 0x01, inputFeature])

    static func setInputFrame(_ target: SwitchTarget) -> [UInt8] {
        requestFrame([0x84, 0x03, inputFeature, 0, target.rawValue])
    }

    static func selectedInput(in bytes: [UInt8]) -> DisplayInput? {
        guard bytes.count >= 11, bytes[0] == monitorAddress, bytes[1] == 0x88,
              bytes[2] == 0x02, bytes[3] == 0, bytes[4] == inputFeature, bytes[8] == 0,
              bytes.prefix(11).reduce(replyChecksumAddress, ^) == 0
        else { return nil }
        return DisplayInput(rawValue: bytes[9])
    }

    static func isValidBaseEDID(_ edid: [UInt8]) -> Bool {
        let header: [UInt8] = [0, 255, 255, 255, 255, 255, 255, 0]
        return edid.count == 128 && edid.starts(with: header) && edid.reduce(0, &+) == 0
    }

    static func huaweiIdentity(in edid: [UInt8]) -> DisplayIdentity? {
        guard isValidBaseEDID(edid) else { return nil }
        let vendor = (UInt32(edid[8]) << 8) | UInt32(edid[9])
        let model = UInt32(edid[10]) | (UInt32(edid[11]) << 8)
        guard vendor == vendorID, model == modelID,
              edid[18] == 1, edid[19] >= 4, edid[20] & 0x8F == 0x85,
              containsModelName(edid)
        else { return nil }

        let serial = UInt32(edid[12]) | (UInt32(edid[13]) << 8)
            | (UInt32(edid[14]) << 16) | (UInt32(edid[15]) << 24)
        let fingerprint = SHA256.hash(data: Data(edid)).map { String(format: "%02x", $0) }.joined()
        return DisplayIdentity(
            fingerprint: fingerprint,
            serialNumber: serial == 0 || serial == .max ? nil : serial
        )
    }

    private static func requestFrame(_ payload: [UInt8]) -> [UInt8] {
        payload + [payload.reduce(monitorAddress ^ hostAddress, ^)]
    }

    private static func containsModelName(_ edid: [UInt8]) -> Bool {
        let nameDescriptor: [UInt8] = [0, 0, 0, 0xFC, 0]
        for start in stride(from: 54, through: 108, by: 18) {
            guard edid[start..<(start + 5)].elementsEqual(nameDescriptor) else { continue }
            let bytes = edid[(start + 5)..<(start + 18)].prefix { $0 != 0x0A && $0 != 0 }
            let name = String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces)
            if name == modelName { return true }
        }
        return false
    }
}

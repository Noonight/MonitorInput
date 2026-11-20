import CryptoKit
import Foundation

enum DDCCapabilities {
    static func inputValues(in capabilities: String) -> Set<UInt8> {
        let text = capabilities.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.first == "(", text.last == ")",
              let vcp = group("vcp", in: text.dropFirst().dropLast()),
              let inputs = group("60", in: vcp) else { return [] }

        return Set(inputs.split(whereSeparator: \.isWhitespace).compactMap { token in
            guard token.count <= 2, let code = UInt8(token, radix: 16), code != 0 else { return nil }
            return code
        })
    }

    private static func group(_ name: String, in text: Substring) -> Substring? {
        var index = text.startIndex
        while index < text.endIndex {
            if text[index].isWhitespace {
                text.formIndex(after: &index)
                continue
            }
            let start = index
            while index < text.endIndex, !text[index].isWhitespace, text[index] != "(", text[index] != ")" {
                text.formIndex(after: &index)
            }
            guard index != start else { return nil }
            let field = text[start..<index]
            while index < text.endIndex, text[index].isWhitespace { text.formIndex(after: &index) }
            guard index < text.endIndex, text[index] == "(" else { continue }

            text.formIndex(after: &index)
            let valueStart = index
            var depth = 1
            while index < text.endIndex, depth > 0 {
                if text[index] == "(" { depth += 1 }
                if text[index] == ")" { depth -= 1 }
                if depth == 0, field.lowercased() == name { return text[valueStart..<index] }
                text.formIndex(after: &index)
            }
            guard depth == 0 else { return nil }
        }
        return nil
    }
}

struct DisplayProduct: Codable, Equatable, Sendable {
    let vendorID: UInt32
    let modelID: UInt32
    let name: String
}

struct DisplayIdentity: Codable, Equatable, Sendable {
    let fingerprint: String
    let serialNumber: UInt32?
    let product: DisplayProduct?

    init(fingerprint: String, serialNumber: UInt32?, product: DisplayProduct? = nil) {
        self.fingerprint = fingerprint
        self.serialNumber = serialNumber
        self.product = product
    }
}

struct DisplayInput: RawRepresentable, Hashable, Codable, Sendable {
    let rawValue: UInt8

    init?(rawValue: UInt8) {
        guard rawValue != 0 else { return nil }
        self.rawValue = rawValue
    }

    var hexCode: String { String(format: "0x%02X", rawValue) }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(UInt8.self)
        guard let input = DisplayInput(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid input value")
        }
        self = input
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum DisplayProtocol {
    private static let inputFeature: UInt8 = 0x60
    private static let monitorAddress: UInt8 = 0x6E
    private static let hostAddress: UInt8 = 0x51
    private static let replyChecksumAddress: UInt8 = 0x50

    static let getInputFrame = requestFrame([0x82, 0x01, inputFeature])

    static func setInputFrame(_ target: DisplayInput) -> [UInt8] {
        requestFrame([0x84, 0x03, inputFeature, 0, target.rawValue])
    }

    static func capabilitiesRequest(offset: UInt16) -> [UInt8] {
        requestFrame([0x83, 0xF3, UInt8(offset >> 8), UInt8(truncatingIfNeeded: offset)])
    }

    static func capabilitiesFragment(in bytes: [UInt8], offset: UInt16) -> ArraySlice<UInt8>? {
        guard bytes.count >= 6, bytes[0] == monitorAddress, bytes[1] & 0x80 != 0
        else { return nil }
        let length = Int(bytes[1] & 0x7F)
        guard (3...35).contains(length), bytes.count >= length + 3, bytes[2] == 0xE3,
              ((UInt16(bytes[3]) << 8) | UInt16(bytes[4])) == offset,
              bytes.prefix(length + 3).reduce(replyChecksumAddress, ^) == 0
        else { return nil }
        return bytes[5..<(length + 2)]
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

    static func identity(in edid: [UInt8]) -> DisplayIdentity? {
        guard isValidBaseEDID(edid), edid[18] == 1 else { return nil }
        let vendor = (UInt32(edid[8]) << 8) | UInt32(edid[9])
        let model = UInt32(edid[10]) | (UInt32(edid[11]) << 8)
        let name = modelName(in: edid) ?? String(format: "Монитор %04X:%04X", vendor, model)
        let serial = UInt32(edid[12]) | (UInt32(edid[13]) << 8)
            | (UInt32(edid[14]) << 16) | (UInt32(edid[15]) << 24)
        let fingerprint = SHA256.hash(data: Data(edid)).map { String(format: "%02x", $0) }.joined()
        return DisplayIdentity(
            fingerprint: fingerprint,
            serialNumber: serial == 0 || serial == .max ? nil : serial,
            product: DisplayProduct(vendorID: vendor, modelID: model, name: name)
        )
    }

    private static func requestFrame(_ payload: [UInt8]) -> [UInt8] {
        payload + [payload.reduce(monitorAddress ^ hostAddress, ^)]
    }

    private static func modelName(in edid: [UInt8]) -> String? {
        let nameDescriptor: [UInt8] = [0, 0, 0, 0xFC, 0]
        for start in stride(from: 54, through: 108, by: 18) {
            guard edid[start..<(start + 5)].elementsEqual(nameDescriptor) else { continue }
            let bytes = edid[(start + 5)..<(start + 18)].prefix { $0 != 0x0A && $0 != 0 }
            if let name = String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces),
               !name.isEmpty, name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
                return name
            }
        }
        return nil
    }
}

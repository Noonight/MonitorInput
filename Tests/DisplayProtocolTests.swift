import XCTest

final class DisplayProtocolTests: XCTestCase {
    func testOnlyTheTwoVerifiedInputsCanBeEncodedForWriting() {
        XCTAssertEqual(DisplayProtocol.setInputFrame(.windows), [0x84, 0x03, 0x60, 0, 15, 0xD7])
        XCTAssertEqual(DisplayProtocol.setInputFrame(.mac), [0x84, 0x03, 0x60, 0, 16, 0xC8])
        XCTAssertNil(SwitchTarget(rawValue: 17))
        XCTAssertEqual(DisplayProtocol.getInputFrame, [0x82, 0x01, 0x60, 0xDC])
    }

    func testReadsTheSelectedSourceFromAValidVCPReply() {
        XCTAssertEqual(DisplayProtocol.selectedInput(in: usbCReply), .usbC)
        XCTAssertEqual(
            DisplayProtocol.selectedInput(in: [0x6E, 0x88, 0x02, 0, 0x60, 0, 0, 0x12, 0, 15, 0xC9]),
            .displayPort
        )
    }

    func testRejectsTruncatedAndCorruptedRepliesInsteadOfGuessing() {
        XCTAssertNil(DisplayProtocol.selectedInput(in: Array(usbCReply.dropLast())))
        var corrupted = usbCReply
        corrupted[10] ^= 1
        XCTAssertNil(DisplayProtocol.selectedInput(in: corrupted))
    }

    func testRejectsNonSuccessfulRepliesAndUnknownSourceValues() {
        var unsupported = usbCReply
        unsupported[3] = 1
        unsupported[10] ^= 1
        XCTAssertNil(DisplayProtocol.selectedInput(in: unsupported))
        let unknown = [0x6E, 0x88, 0x02, 0, 0x60, 0, 0, 0x12, 0, 0x1B, 0xDD] as [UInt8]
        XCTAssertNil(DisplayProtocol.selectedInput(in: unknown))
    }

    func testRecognizesTheHuaweiAndDerivesItsIdentityFromEDID() throws {
        let identity = try XCTUnwrap(DisplayProtocol.huaweiIdentity(in: makeEDID()))
        XCTAssertEqual(identity.serialNumber, 0x78563412)
        XCTAssertEqual(identity.fingerprint.count, 64)
        XCTAssertNotEqual(identity.fingerprint, DisplayProtocol.huaweiIdentity(in: makeEDID(serial: 99))?.fingerprint)
    }

    func testRejectsTheSameNameWithADifferentVendorOrProduct() {
        XCTAssertNil(DisplayProtocol.huaweiIdentity(in: makeEDID(vendor: 0x22F5)))
        XCTAssertNil(DisplayProtocol.huaweiIdentity(in: makeEDID(product: 0x6A24)))
        XCTAssertNil(DisplayProtocol.huaweiIdentity(in: makeEDID(name: "ZQE-CBA")))
    }

    func testRejectsTheHuaweiEDIDForAnHDMIConnection() {
        XCTAssertNil(DisplayProtocol.huaweiIdentity(in: makeEDID(inputByte: 0xA2)))
    }

    func testRejectsDamagedEDIDAndHandlesAnAbsentSerialNumber() throws {
        var damaged = makeEDID()
        damaged[127] ^= 1
        XCTAssertNil(DisplayProtocol.huaweiIdentity(in: damaged))
        XCTAssertNil(DisplayProtocol.huaweiIdentity(in: Array(damaged.prefix(64))))
        let identity = try XCTUnwrap(DisplayProtocol.huaweiIdentity(in: makeEDID(serial: 0)))
        XCTAssertNil(identity.serialNumber)
        XCTAssertFalse(identity.fingerprint.isEmpty)
    }

    private let usbCReply: [UInt8] = [0x6E, 0x88, 0x02, 0, 0x60, 0, 0, 0x12, 0, 16, 0xD6]

    private func makeEDID(
        vendor: UInt16 = 0x22F6,
        product: UInt16 = 0x6A25,
        name: String = "ZQE-CAA",
        serial: UInt32 = 0x78563412,
        inputByte: UInt8 = 0xA5
    ) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 128)
        bytes.replaceSubrange(0..<8, with: [0, 255, 255, 255, 255, 255, 255, 0])
        bytes[8] = UInt8(vendor >> 8)
        bytes[9] = UInt8(truncatingIfNeeded: vendor)
        bytes[10] = UInt8(truncatingIfNeeded: product)
        bytes[11] = UInt8(product >> 8)
        for offset in 0..<4 {
            bytes[12 + offset] = UInt8(truncatingIfNeeded: serial >> (8 * offset))
        }
        bytes[18] = 1
        bytes[19] = 4
        bytes[20] = inputByte
        bytes[57] = 0xFC
        let descriptor = Array((name + "\n").utf8)
        bytes.replaceSubrange(59..<(59 + descriptor.count), with: descriptor)
        bytes[127] = 0 &- bytes.dropLast().reduce(0, &+)
        return bytes
    }
}

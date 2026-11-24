import XCTest

final class DisplayProtocolTests: XCTestCase {
    func testCapabilitiesOnlyReadInputCodesFromTheVCPInputField() {
        let capabilities = "(prot(monitor)model(ZQ)cmds(01 02 03 E3 F3)vcp(14(60 05) 60(0F 10 11 12 11) AC))"
        XCTAssertEqual(DDCCapabilities.inputValues(in: capabilities), [0x0F, 0x10, 0x11, 0x12])
    }

    func testCapabilitiesWithoutInputValuesDoNotInventSources() {
        XCTAssertTrue(DDCCapabilities.inputValues(in: "(vcp(60 14(60 11)))").isEmpty)
        XCTAssertTrue(DDCCapabilities.inputValues(in: "(vcp(60(0F 11)").isEmpty)
    }

    func testFramesOnlyEncodeTheInputSourceFeature() throws {
        XCTAssertEqual(DisplayProtocol.setInputFrame(.displayPort), [0x84, 0x03, 0x60, 0, 15, 0xD7])
        XCTAssertEqual(DisplayProtocol.setInputFrame(.usbC), [0x84, 0x03, 0x60, 0, 16, 0xC8])
        let extra = try XCTUnwrap(DisplayInput(rawValue: 0x1B))
        XCTAssertEqual(DisplayProtocol.setInputFrame(extra), [0x84, 0x03, 0x60, 0, 0x1B, 0xC3])
        XCTAssertNil(DisplayInput(rawValue: 0))
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

    func testUnknownCodesRemainReadableButUnsuccessfulRepliesAreRejected() {
        var unsupported = usbCReply
        unsupported[3] = 1
        unsupported[10] ^= 1
        XCTAssertNil(DisplayProtocol.selectedInput(in: unsupported))
        let unknown = [0x6E, 0x88, 0x02, 0, 0x60, 0, 0, 0x12, 0, 0x1B, 0xDD] as [UInt8]
        XCTAssertEqual(DisplayProtocol.selectedInput(in: unknown)?.rawValue, 0x1B)
    }

    func testRecognizesTheHuaweiAndDerivesItsIdentityFromEDID() throws {
        let identity = try XCTUnwrap(DisplayProtocol.identity(in: makeEDID()))
        XCTAssertEqual(identity.serialNumber, 0x78563412)
        XCTAssertEqual(identity.fingerprint.count, 64)
        XCTAssertNotEqual(identity.fingerprint, DisplayProtocol.identity(in: makeEDID(serial: 99))?.fingerprint)
    }

    func testDiscoversAnotherVendorAndAnHDMIConnectedMonitor() throws {
        let identity = try XCTUnwrap(
            DisplayProtocol.identity(in: makeEDID(vendor: 0x10AC, product: 0x1234, name: "U2720Q", inputByte: 0xA2))
        )
        XCTAssertEqual(identity.product, DisplayProduct(vendorID: 0x10AC, modelID: 0x1234, name: "U2720Q"))
    }

    func testOnlyReportedNamesAreUsedFromCurrentAndLegacyEDIDRecords() throws {
        let identity = try XCTUnwrap(
            DisplayProtocol.identity(in: makeEDID(vendor: 0x10AC, product: 0x1234, name: ""))
        )
        let unnamed = try XCTUnwrap(identity.product)
        let legacy = DisplayProduct(vendorID: 0x10AC, modelID: 0x1234, name: "Монитор 10AC:1234")
        let named = DisplayProduct(vendorID: 0x10AC, modelID: 0x1234, name: "U2720Q")
        XCTAssertNil(unnamed.reportedName)
        XCTAssertNil(legacy.reportedName)
        XCTAssertEqual(legacy.vendorModelCode, "10AC:1234")
        XCTAssertEqual(named.reportedName, "U2720Q")
    }

    func testCapabilityPacketsValidateTheChecksumAndTheRequestedOffset() {
        XCTAssertEqual(DisplayProtocol.capabilitiesRequest(offset: 0x20), [0x83, 0xF3, 0x00, 0x20, 0x6F])
        let frame: [UInt8] = [0x6E, 0x86, 0xE3, 0, 0x20, 0x61, 0x62, 0x63, 0x1B]
        XCTAssertEqual(DisplayProtocol.capabilitiesFragment(in: frame, offset: 0x20).map(Array.init), [0x61, 0x62, 0x63])
        XCTAssertNil(DisplayProtocol.capabilitiesFragment(in: frame, offset: 0x21))
        XCTAssertNil(DisplayProtocol.capabilitiesFragment(in: Array(frame.dropLast()), offset: 0x20))
        var invalid = frame
        invalid[8] ^= 1
        XCTAssertNil(DisplayProtocol.capabilitiesFragment(in: invalid, offset: 0x20))
    }

    func testTheModelProfileCanOverrideTheStandardMeaningOfACode() {
        let fixture = #"[{"vendorID":"22F6","modelID":"6A25","name":"MateView GT","ports":{"0F":"DisplayPort","10":"USB-C","00":"Invalid"}}]"#
        let catalog = MonitorProfiles(data: Data(fixture.utf8))
        let identity = DisplayProtocol.identity(in: makeEDID())
        let profile = identity.flatMap { catalog.profile(for: $0) }
        XCTAssertEqual(profile?.ports[.usbC], "USB-C")
        XCTAssertEqual(profile?.ports.count, 2)
        let different = DisplayProtocol.identity(in: makeEDID(product: 0x1234))
        XCTAssertNil(different.flatMap { catalog.profile(for: $0) })
    }

    func testRejectsDamagedEDIDAndHandlesAnAbsentSerialNumber() throws {
        var damaged = makeEDID()
        damaged[127] ^= 1
        XCTAssertNil(DisplayProtocol.identity(in: damaged))
        XCTAssertNil(DisplayProtocol.identity(in: Array(damaged.prefix(64))))
        let identity = try XCTUnwrap(DisplayProtocol.identity(in: makeEDID(serial: 0)))
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

extension DisplayInput {
    static let displayPort = DisplayInput(rawValue: 0x0F)!
    static let usbC = DisplayInput(rawValue: 0x10)!
    static let hdmi1 = DisplayInput(rawValue: 0x11)!
    static let hdmi2 = DisplayInput(rawValue: 0x12)!
}

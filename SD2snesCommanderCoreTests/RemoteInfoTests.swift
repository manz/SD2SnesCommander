import Foundation
import Testing
@testable import SD2snesCommanderCore

struct RemoteInfoTests {
    @Test func decodesNullTerminatedTuplesIntoStrings() {
        var info = sd2snes_info_t()
        info.firmware_version = 0x010B
        info.current_features = 0x0001
        info.current_configuration = 0x0002
        info.firmware_version2 = 0x01_0B_00_01

        // Fill rom_name with "/sd2snes/menu.bin\0..."
        let romName = "/sd2snes/menu.bin"
        copy(romName, into: &info.rom_name)
        copy("v1.11.1", into: &info.firmware_string)
        copy("sd2snes Mk.II", into: &info.device_name)

        let parsed = RemoteInfo(from: info)
        #expect(parsed.firmwareVersion == 0x010B)
        #expect(parsed.romName == romName)
        #expect(parsed.firmwareString == "v1.11.1")
        #expect(parsed.deviceName == "sd2snes Mk.II")
    }

    @Test func codableRoundTripPreservesAllFields() throws {
        let original = RemoteInfo(
            firmwareVersion: 0x010B,
            currentFeatures: 0x0001,
            currentConfiguration: 0x0002,
            romName: "/sd2snes/m3nu.bin",
            firmwareVersion2: 0xDEADBEEF,
            firmwareString: "v1.12.0",
            deviceName: "FXPAK PRO STM32"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RemoteInfo.self, from: data)

        #expect(decoded.firmwareVersion == original.firmwareVersion)
        #expect(decoded.currentFeatures == original.currentFeatures)
        #expect(decoded.currentConfiguration == original.currentConfiguration)
        #expect(decoded.romName == original.romName)
        #expect(decoded.firmwareVersion2 == original.firmwareVersion2)
        #expect(decoded.firmwareString == original.firmwareString)
        #expect(decoded.deviceName == original.deviceName)
    }

    // Copy a Swift String into a fixed-size C tuple of Int8 by interpreting
    // the tuple as a contiguous CChar buffer.
    private func copy<T>(_ string: String, into tuple: inout T) {
        let size = MemoryLayout<T>.size
        withUnsafeMutablePointer(to: &tuple) {
            $0.withMemoryRebound(to: CChar.self, capacity: size) { buffer in
                let bytes = Array(string.utf8CString)
                let copyCount = min(bytes.count, size)
                for i in 0..<copyCount { buffer[i] = bytes[i] }
                if copyCount < size { buffer[copyCount] = 0 }
            }
        }
    }
}

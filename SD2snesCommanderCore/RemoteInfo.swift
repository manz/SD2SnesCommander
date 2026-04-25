import Foundation

public struct RemoteInfo: Codable, Sendable {
    public let firmwareVersion: UInt16
    public let currentFeatures: UInt16
    public let currentConfiguration: UInt16
    public let romName: String?
    public let firmwareVersion2: UInt32
    public let firmwareString: String?
    public let deviceName: String?

    public init(firmwareVersion: UInt16,
                currentFeatures: UInt16,
                currentConfiguration: UInt16,
                romName: String?,
                firmwareVersion2: UInt32,
                firmwareString: String?,
                deviceName: String?) {
        self.firmwareVersion = firmwareVersion
        self.currentFeatures = currentFeatures
        self.currentConfiguration = currentConfiguration
        self.romName = romName
        self.firmwareVersion2 = firmwareVersion2
        self.firmwareString = firmwareString
        self.deviceName = deviceName
    }

    public init(from cStruct: sd2snes_info_t) {
        self.firmwareVersion = cStruct.firmware_version
        self.currentFeatures = cStruct.current_features
        self.currentConfiguration = cStruct.current_configuration
        self.firmwareVersion2 = cStruct.firmware_version2

        self.romName = Self.cStringFromTuple(cStruct.rom_name)
        self.firmwareString = Self.cStringFromTuple(cStruct.firmware_string)
        self.deviceName = Self.cStringFromTuple(cStruct.device_name)
    }

    private static func cStringFromTuple<T>(_ tuple: T) -> String? {
        let size = MemoryLayout<T>.size
        return withUnsafePointer(to: tuple) {
            $0.withMemoryRebound(to: CChar.self, capacity: size) {
                String(cString: $0, encoding: .utf8)
            }
        }
    }
}

import Foundation
import os.log

// SD2SNES USB Client - Swift wrapper for C implementation.
// The C layer holds process-wide globals for the USB device, so all access
// must funnel through a single client instance per process.
public actor SD2SnesUSBClient {
    public static let shared = SD2SnesUSBClient()

    private let logger = Logger(subsystem: "SD2SnesCommanderCore", category: "USB")

    private init() {}

    deinit {
        sd2snes_disconnect()
    }

    // MARK: - Connection Management

    public func connect() async throws {
        logger.info("Attempting to connect to SD2SNES device...")

        let result = sd2snes_connect()
        guard result == SD2SNES_SUCCESS else {
            logger.error("Failed to connect to SD2SNES device: \(result.rawValue)")
            throw SD2SnesUSBError(from: result)
        }

        logger.info("Successfully connected to SD2SNES device")
    }

    public func disconnect() async {
        logger.info("Disconnecting from SD2SNES device")
        sd2snes_disconnect()
    }

    public var isConnected: Bool {
        return sd2snes_is_connected()
    }

    // MARK: - Device Info

    public func info() async throws -> RemoteInfo {
        var deviceInfo = sd2snes_info_t()
        let result = sd2snes_get_info(&deviceInfo)

        guard result == SD2SNES_SUCCESS else {
            logger.error("Failed to get device info: \(result.rawValue)")
            throw SD2SnesUSBError(from: result)
        }

        return RemoteInfo(from: deviceInfo)
    }

    // MARK: - File Operations

    public func listFiles(path: String = "") async throws -> [RemoteFileItem] {
        logger.info("Listing files at path: '\(path)'")

        // Grow the buffer until the C side stops returning BUFFER_OVERFLOW.
        // Capped so a runaway listing can't allocate forever.
        var capacity = 256
        let maxCapacity = 16384
        while true {
            var files = Array(repeating: sd2snes_file_info_t(), count: capacity)
            var fileCount: Int = 0
            let result = sd2snes_list_files(path, &files, capacity, &fileCount)

            if result == SD2SNES_SUCCESS {
                logger.info("Found \(fileCount) entries")
                return Self.unpackFileEntries(files, count: fileCount)
            }

            if result == SD2SNES_ERROR_BUFFER_OVERFLOW && capacity < maxCapacity {
                capacity = min(capacity * 2, maxCapacity)
                logger.info("List buffer overflow, retrying with capacity \(capacity)")
                continue
            }

            logger.error("Failed to list files: \(result.rawValue)")
            throw SD2SnesUSBError(from: result)
        }
    }

    private static func unpackFileEntries(_ files: [sd2snes_file_info_t], count: Int) -> [RemoteFileItem] {
        var out: [RemoteFileItem] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            let fileInfo = files[i]
            let nameSize = MemoryLayout.size(ofValue: fileInfo.name)
            let fileName = withUnsafePointer(to: fileInfo.name) {
                $0.withMemoryRebound(to: CChar.self, capacity: nameSize) {
                    String(cString: $0, encoding: .utf8) ?? "Unknown"
                }
            }
            out.append(RemoteFileItem(name: fileName, isDirectory: fileInfo.is_directory))
        }
        return out
    }

    public func uploadFile(
        localPath: String,
        remotePath: String,
        progressHandler: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        logger.info("Uploading file from '\(localPath)' to '\(remotePath)'")

        let result = withProgressTrampoline(progressHandler) { cb, ud in
            sd2snes_upload_file(localPath, remotePath, cb, ud)
        }
        guard result == SD2SNES_SUCCESS else {
            logger.error("Failed to upload file: \(result.rawValue)")
            throw SD2SnesUSBError(from: result)
        }

        logger.info("File upload completed")
    }

    public func downloadFile(
        remotePath: String,
        localPath: String,
        progressHandler: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        logger.info("Downloading file from '\(remotePath)' to '\(localPath)'")

        let result = withProgressTrampoline(progressHandler) { cb, ud in
            sd2snes_download_file(remotePath, localPath, cb, ud)
        }
        guard result == SD2SNES_SUCCESS else {
            logger.error("Failed to download file: \(result.rawValue)")
            throw SD2SnesUSBError(from: result)
        }

        logger.info("File download completed")
    }

    private func withProgressTrampoline(
        _ handler: (@Sendable (Double) -> Void)?,
        _ body: (sd2snes_progress_callback_t?, UnsafeMutableRawPointer?) -> sd2snes_error_t
    ) -> sd2snes_error_t {
        guard let handler else {
            return body(nil, nil)
        }
        let box = Unmanaged.passRetained(ProgressBox(handler: handler))
        defer { box.release() }
        let trampoline: sd2snes_progress_callback_t = { progress, userdata in
            guard let userdata else { return }
            let box = Unmanaged<ProgressBox>.fromOpaque(userdata).takeUnretainedValue()
            box.handler(progress)
        }
        return body(trampoline, box.toOpaque())
    }

    public func deleteFile(path: String) async throws {
        logger.info("Deleting file: \(path)")

        let result = sd2snes_delete_file(path)
        guard result == SD2SNES_SUCCESS else {
            logger.error("Failed to delete file: \(result.rawValue)")
            throw SD2SnesUSBError(from: result)
        }

        logger.info("File deleted successfully")
    }

    // MARK: - Device Control

    public func bootRom(path: String) async throws {
        logger.info("Booting ROM: \(path)")

        let result = sd2snes_boot_rom(path)
        guard result == SD2SNES_SUCCESS else {
            logger.error("Failed to boot ROM: \(result.rawValue)")
            throw SD2SnesUSBError(from: result)
        }

        logger.info("ROM boot completed")
    }

    public func reset() async throws {
        logger.info("Resetting device")

        let result = sd2snes_reset_device()
        guard result == SD2SNES_SUCCESS else {
            logger.error("Failed to reset device: \(result.rawValue)")
            throw SD2SnesUSBError(from: result)
        }

        logger.info("Device reset completed")
    }

    public func menu() async throws {
        logger.info("Returning to menu")

        let result = sd2snes_menu_reset()
        guard result == SD2SNES_SUCCESS else {
            logger.error("Failed to return to menu: \(result.rawValue)")
            throw SD2SnesUSBError(from: result)
        }

        logger.info("Returned to menu")
    }
}

// MARK: - Remote Info

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

private final class ProgressBox: @unchecked Sendable {
    let handler: @Sendable (Double) -> Void
    init(handler: @escaping @Sendable (Double) -> Void) { self.handler = handler }
}

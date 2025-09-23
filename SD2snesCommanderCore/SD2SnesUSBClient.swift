import Foundation
import os.log

// SD2SNES USB Client - Swift wrapper for C implementation
public actor SD2SnesUSBClient {
    private let logger = Logger(subsystem: "SD2SnesCommanderCore", category: "USB")

    public init() {}

    deinit {
        Task { [weak self] in
            await self?.disconnect()
        }
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
        logger.info("🔍 Swift: Requesting file list for path: '\(path)'")

        let maxFiles = 100
        var files = Array(repeating: sd2snes_file_info_t(), count: maxFiles)
        var fileCount: Int = 0

        let result = sd2snes_list_files(path, &files, maxFiles, &fileCount)
        guard result == SD2SNES_SUCCESS else {
            logger.error("Failed to list files: \(result.rawValue)")
            throw SD2SnesUSBError(from: result)
        }

        logger.info("Found \(fileCount) files/directories")

        var remoteFiles: [RemoteFileItem] = []
        for i in 0..<fileCount {
            let fileInfo = files[i]

            let fileName = withUnsafePointer(to: fileInfo.name) {
                $0.withMemoryRebound(to: CChar.self, capacity: 256) {
                    String(cString: $0, encoding: .utf8) ?? "Unknown"
                }
            }

            let isDirectory = fileInfo.is_directory
            remoteFiles.append(RemoteFileItem(name: fileName, isDirectory: isDirectory))
        }

        return remoteFiles
    }

    public func uploadFile(localPath: String, remotePath: String, progressHandler: @escaping (Double) -> Void = { _ in }) async throws {
        logger.info("Uploading file from '\(localPath)' to '\(remotePath)'")

        let result = sd2snes_upload_file(localPath, remotePath, nil)
        guard result == SD2SNES_SUCCESS else {
            logger.error("Failed to upload file: \(result.rawValue)")
            throw SD2SnesUSBError(from: result)
        }

        logger.info("File upload completed")
    }

    public func downloadFile(remotePath: String, localPath: String, progressHandler: @escaping (Double) -> Void = { _ in }) async throws {
        logger.info("Downloading file from '\(remotePath)' to '\(localPath)'")

        let result = sd2snes_download_file(remotePath, localPath, nil)
        guard result == SD2SNES_SUCCESS else {
            logger.error("Failed to download file: \(result.rawValue)")
            throw SD2SnesUSBError(from: result)
        }

        logger.info("File download completed")
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

public struct RemoteInfo {
    public let firmwareVersion: UInt16
    public let currentFeatures: UInt16
    public let currentConfiguration: UInt16
    public let romName: String?
    public let firmwareVersion2: UInt32
    public let firmwareString: String?
    public let deviceName: String?

    public init(from cStruct: sd2snes_info_t) {
        self.firmwareVersion = cStruct.firmware_version
        self.currentFeatures = cStruct.current_features
        self.currentConfiguration = cStruct.current_configuration
        self.firmwareVersion2 = cStruct.firmware_version2

        self.romName = withUnsafePointer(to: cStruct.rom_name) {
            $0.withMemoryRebound(to: CChar.self, capacity: 256) {
                String(cString: $0, encoding: .utf8)
            }
        }
        self.firmwareString = withUnsafePointer(to: cStruct.firmware_string) {
            $0.withMemoryRebound(to: CChar.self, capacity: 64) {
                String(cString: $0, encoding: .utf8)
            }
        }
        self.deviceName = withUnsafePointer(to: cStruct.device_name) {
            $0.withMemoryRebound(to: CChar.self, capacity: 64) {
                String(cString: $0, encoding: .utf8)
            }
        }
    }
}

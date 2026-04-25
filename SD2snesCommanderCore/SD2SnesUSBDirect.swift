import Foundation
import os.log

// Direct USB client. Talks to the C layer that owns the IOKit handles in
// process-global state. Intended for use *only* inside the XPC daemon
// process — instantiating this in the app or CLI would race the daemon
// for exclusive access to the cart.
public actor SD2SnesUSBDirect {
    public static let shared = SD2SnesUSBDirect()

    private let logger = Logger(subsystem: "SD2snesCommanderCore", category: "USBDirect")

    private init() {}

    deinit {
        sd2snes_disconnect()
    }

    // MARK: - Connection Management

    public func connect() async throws {
        logger.info("Attempting to connect to SD2SNES device...")

        let result = sd2snes_connect()
        guard result == SD2SNES_SUCCESS else {
            logger.error("Failed to connect: \(result.rawValue)")
            throw SD2SnesUSBError(from: result)
        }
    }

    public func disconnect() async {
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
            throw SD2SnesUSBError(from: result)
        }

        return RemoteInfo(from: deviceInfo)
    }

    // MARK: - File Operations

    public func listFiles(path: String = "") async throws -> [RemoteFileItem] {
        // Grow the buffer until the C side stops returning BUFFER_OVERFLOW.
        // Capped so a runaway listing can't allocate forever.
        var capacity = 256
        let maxCapacity = 16384
        while true {
            var files = Array(repeating: sd2snes_file_info_t(), count: capacity)
            var fileCount: Int = 0
            let result = sd2snes_list_files(path, &files, capacity, &fileCount)

            if result == SD2SNES_SUCCESS {
                return Self.unpackFileEntries(files, count: fileCount)
            }

            if result == SD2SNES_ERROR_BUFFER_OVERFLOW && capacity < maxCapacity {
                capacity = min(capacity * 2, maxCapacity)
                continue
            }

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
        let result = withProgressTrampoline(progressHandler) { cb, ud in
            sd2snes_upload_file(localPath, remotePath, cb, ud)
        }
        guard result == SD2SNES_SUCCESS else {
            throw SD2SnesUSBError(from: result)
        }
    }

    public func downloadFile(
        remotePath: String,
        localPath: String,
        progressHandler: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        let result = withProgressTrampoline(progressHandler) { cb, ud in
            sd2snes_download_file(remotePath, localPath, cb, ud)
        }
        guard result == SD2SNES_SUCCESS else {
            throw SD2SnesUSBError(from: result)
        }
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
        let result = sd2snes_delete_file(path)
        guard result == SD2SNES_SUCCESS else {
            throw SD2SnesUSBError(from: result)
        }
    }

    // MARK: - Device Control

    public func bootRom(path: String) async throws {
        let result = sd2snes_boot_rom(path)
        guard result == SD2SNES_SUCCESS else {
            throw SD2SnesUSBError(from: result)
        }
    }

    public func reset() async throws {
        let result = sd2snes_reset_device()
        guard result == SD2SNES_SUCCESS else {
            throw SD2SnesUSBError(from: result)
        }
    }

    public func menu() async throws {
        let result = sd2snes_menu_reset()
        guard result == SD2SNES_SUCCESS else {
            throw SD2SnesUSBError(from: result)
        }
    }
}

private final class ProgressBox: @unchecked Sendable {
    let handler: @Sendable (Double) -> Void
    init(handler: @escaping @Sendable (Double) -> Void) { self.handler = handler }
}

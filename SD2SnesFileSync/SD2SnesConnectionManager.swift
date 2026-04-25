import Foundation
import Observation
import os.log
import SD2snesCommanderCore

@MainActor
@Observable
class SD2SnesConnectionManager {
    static let shared = SD2SnesConnectionManager()

    var isConnected = false
    var currentPath = ""
    var files: [RemoteFileItem] = []

    @ObservationIgnored private let logger = Logger(subsystem: "SD2SnesFileSync", category: "Connection")
    @ObservationIgnored private let usbClient = SD2SnesUSBClient.shared
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    private init() {}

    func connect() async throws {
        logger.info("Connecting to SD2Snes device...")

        try await usbClient.connect()
        isConnected = await usbClient.isConnected
        currentPath = ""
        await refreshFiles()

        startPeriodicRefresh()

        logger.info("Connected to SD2Snes device")
    }

    func disconnect() async {
        logger.info("Disconnecting from SD2Snes device")
        await usbClient.disconnect()
        isConnected = false
        files = []
        currentPath = ""
        stopPeriodicRefresh()
    }

    func refreshFiles() async {
        guard isConnected else { return }

        do {
            files = try await usbClient.listFiles(path: currentPath)
            logger.info("Refreshed file list: \(self.files.count) items at path '\(self.currentPath)'")
        } catch {
            logger.error("Failed to refresh files: \(error)")
            files = []
        }
    }

    func navigateToDirectory(_ dirName: String) async {
        let newPath = currentPath.isEmpty ? dirName : "\(currentPath)/\(dirName)"
        currentPath = newPath
        await refreshFiles()
    }

    func navigateToParent() async {
        if !currentPath.isEmpty {
            let components = currentPath.components(separatedBy: "/")
            if components.count > 1 {
                currentPath = components.dropLast().joined(separator: "/")
            } else {
                currentPath = ""
            }
            await refreshFiles()
        }
    }

    func uploadFile(localPath: String, fileName: String? = nil) async throws {
        let targetFileName = fileName ?? URL(fileURLWithPath: localPath).lastPathComponent
        let remotePath = currentPath.isEmpty ? targetFileName : "\(currentPath)/\(targetFileName)"

        var actualFilePath = localPath
        var tempFilePath: String? = nil

        let localURL = URL(fileURLWithPath: localPath)
        if localURL.pathExtension.lowercased() == "smc" || localURL.pathExtension.lowercased() == "sfc" {
            if let ipsPath = IPSPatcher.findIPSPatch(for: localPath) {
                logger.info("Found IPS patch: \(ipsPath)")
                do {
                    tempFilePath = try IPSPatcher.createTemporaryPatchedFile(romPath: localPath, ipsPath: ipsPath)
                    actualFilePath = tempFilePath!
                    logger.info("Applied IPS patch, using temporary file")
                } catch {
                    logger.error("IPS patching failed: \(error), using original file")
                }
            }
        }

        try await usbClient.uploadFile(localPath: actualFilePath, remotePath: remotePath)

        if let tempPath = tempFilePath {
            try? FileManager.default.removeItem(atPath: tempPath)
        }

        await refreshFiles()
    }

    func bootROM(fileName: String) async throws {
        let romPath = currentPath.isEmpty ? fileName : "\(currentPath)/\(fileName)"
        try await usbClient.bootRom(path: romPath)
    }

    func deleteFile(fileName: String) async throws {
        let filePath = currentPath.isEmpty ? fileName : "\(currentPath)/\(fileName)"
        try await usbClient.deleteFile(path: filePath)
        await refreshFiles()
    }

    func downloadFile(remotePath: String, localPath: String) async throws {
        try await usbClient.downloadFile(remotePath: remotePath, localPath: localPath)
    }

    private func startPeriodicRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard !Task.isCancelled else { return }
                await self?.refreshFiles()
            }
        }
    }

    private func stopPeriodicRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
    }
}

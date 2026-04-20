import SwiftUI
import Foundation
import AppKit
import Observation
import SD2snesCommanderCore

@MainActor
@Observable
class MainViewModel {
    var isConnected = false
    var connectionStatus = "Disconnected"
    var isConnecting = false
    var deviceName: String = "SD2Snes Commander"

    var localFiles: [LocalFileItem] = []
    var remoteFiles: [RemoteFileItem] = []
    var currentLocalPath = ""
    var currentRemotePath = ""
    var remoteBreadcrumbs: [String] = []

    var remoteNavigationHistory: [String] = []
    var remoteHistoryIndex: Int = -1
    var canGoBack: Bool = false
    var canGoForward: Bool = false

    var selectedLocalFile: String? = nil
    var selectedRemoteFile: String? = nil

    var isTransferInProgress = false
    var transferProgress: Double = 0.0
    var transferStatus = ""

    @ObservationIgnored private let usbClient = SD2SnesUSBClient()
    @ObservationIgnored private let fileManager = LocalFileManager()
    @ObservationIgnored private var transferTask: Task<Void, Never>?

    init() {}

    func initialize() {
        loadInitialLocalFiles()
    }

    // MARK: - Connection Management

    func connect() {
        guard !isConnecting else { return }

        Task {
            isConnecting = true
            connectionStatus = "Searching for SD2SNES device..."

            do {
                try await usbClient.connect()

                let info = try await usbClient.info()

                deviceName = info.deviceName ?? "SD2SNES USB"
                connectionStatus = "Connected to \(deviceName) via USB"
                isConnected = true

                await refreshRemoteFiles()
            } catch {
                connectionStatus = "Failed to connect"
                isConnected = false

                let alert = NSAlert()
                alert.messageText = "USB Connection Failed"
                alert.informativeText = "Could not find or connect to SD2SNES device via USB. Make sure the device is connected and powered on.\n\nError: \(error.localizedDescription)"
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }

            isConnecting = false
        }
    }

    func disconnect() {
        Task {
            await usbClient.disconnect()
            isConnected = false
            connectionStatus = "Disconnected"
            deviceName = "SD2Snes Commander"
            remoteFiles = []
        }
    }

    func toggleConnection() {
        if isConnected {
            disconnect()
        } else {
            connect()
        }
    }

    // MARK: - Local File Management

    func browseLocalFiles() {
        Task {
            guard let url = await fileManager.browseForDirectory() else { return }
            currentLocalPath = url.path
            loadLocalFiles(at: url)
        }
    }

    func loadInitialLocalFiles() {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        currentLocalPath = documentsURL.path
        loadLocalFiles(at: documentsURL)
    }

    func loadLocalFiles(at url: URL) {
        localFiles = fileManager.getFiles(at: url)
        clearLocalSelection()
    }

    func openDirectory(_ file: LocalFileItem) {
        guard file.isDirectory else { return }
        let url = URL(fileURLWithPath: file.path)
        currentLocalPath = url.path
        loadLocalFiles(at: url)
    }

    func showInFinder(_ file: LocalFileItem) {
        let url = URL(fileURLWithPath: file.path)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Remote File Management

    func refreshRemoteFiles() async {
        guard isConnected else { return }

        do {
            let files = try await usbClient.listFiles(path: currentRemotePath)
            remoteFiles = files.filter { !$0.name.hasPrefix(".") }

            if remoteNavigationHistory.isEmpty {
                addToNavigationHistory(currentRemotePath)
            }
        } catch {
            print("Failed to refresh remote files: \(error)")
        }
    }

    func openRemoteDirectory(_ file: RemoteFileItem) {
        guard file.isDirectory else { return }

        Task {
            let newPath = currentRemotePath.isEmpty ? file.name : "\(currentRemotePath)/\(file.name)"
            await navigateToPath(newPath)
        }
    }

    func navigateToRemoteParent() {
        guard !remoteBreadcrumbs.isEmpty else { return }

        Task {
            let parentBreadcrumbs = Array(remoteBreadcrumbs.dropLast())
            let parentPath = parentBreadcrumbs.joined(separator: "/")
            await navigateToPath(parentPath)
        }
    }

    func navigateToRemoteRoot() {
        Task {
            await navigateToPath("")
        }
    }

    // MARK: - File Transfer Operations

    func uploadFile(_ file: LocalFileItem) {
        guard !file.isDirectory && isConnected else { return }

        transferTask?.cancel()
        transferTask = Task {
            var actualFilePath = file.path
            var tempFilePath: String? = nil

            do {
                isTransferInProgress = true
                transferProgress = 0.0

                if file.isRomFile, let ipsPath = IPSPatcher.findIPSPatch(for: file.path) {
                    transferStatus = "Applying IPS patch..."

                    do {
                        tempFilePath = try IPSPatcher.createTemporaryPatchedFile(
                            romPath: file.path,
                            ipsPath: ipsPath
                        )
                        actualFilePath = tempFilePath!
                        transferStatus = "Uploading patched \(file.name)..."
                    } catch {
                        transferStatus = "IPS patch failed: \(error.localizedDescription). Uploading \(file.name)..."
                    }
                } else {
                    transferStatus = "Uploading \(file.name)..."
                }

                let fullRemotePath = currentRemotePath.isEmpty
                    ? file.name
                    : "\(currentRemotePath)/\(file.name)"

                try await usbClient.uploadFile(
                    localPath: actualFilePath,
                    remotePath: fullRemotePath
                )

                transferStatus = "Upload completed"
                await refreshRemoteFiles()

                if let tempPath = tempFilePath {
                    try? FileManager.default.removeItem(atPath: tempPath)
                }

                try await Task.sleep(nanoseconds: 2_000_000_000)
                isTransferInProgress = false
                transferStatus = ""

            } catch {
                if let tempPath = tempFilePath {
                    try? FileManager.default.removeItem(atPath: tempPath)
                }

                transferStatus = "Upload failed: \(error.localizedDescription)"
                isTransferInProgress = false
            }
        }
    }

    func downloadFile(_ file: RemoteFileItem) {
        guard !file.isDirectory else { return }

        transferTask?.cancel()
        transferTask = Task {
            guard let url = await fileManager.saveFile(suggestedName: file.name) else { return }

            do {
                isTransferInProgress = true
                transferProgress = 0.0
                transferStatus = "Downloading \(file.name)..."

                let fullRemotePath = currentRemotePath.isEmpty
                    ? file.name
                    : "\(currentRemotePath)/\(file.name)"

                try await usbClient.downloadFile(
                    remotePath: fullRemotePath,
                    localPath: url.path
                )

                transferStatus = "Download completed"

                try await Task.sleep(nanoseconds: 2_000_000_000)
                isTransferInProgress = false
                transferStatus = ""

            } catch {
                transferStatus = "Download failed: \(error.localizedDescription)"
                isTransferInProgress = false
            }
        }
    }

    func deleteRemoteFile(_ file: RemoteFileItem) {
        guard isConnected else { return }

        let alert = NSAlert()
        alert.messageText = "Delete File"
        alert.informativeText = "Are you sure you want to delete \"\(file.name)\"? This action cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            Task {
                do {
                    let fullRemotePath = currentRemotePath.isEmpty
                        ? file.name
                        : "\(currentRemotePath)/\(file.name)"
                    try await usbClient.deleteFile(path: fullRemotePath)
                    await refreshRemoteFiles()
                } catch {
                    print("Failed to delete file: \(error)")
                }
            }
        }
    }

    // MARK: - Device Control

    func bootRom(_ file: RemoteFileItem) {
        guard isConnected && file.isRomFile else { return }

        Task {
            do {
                let fullRemotePath = currentRemotePath.isEmpty
                    ? file.name
                    : "\(currentRemotePath)/\(file.name)"
                try await usbClient.bootRom(path: fullRemotePath)
            } catch {
                print("Failed to boot ROM: \(error)")
            }
        }
    }

    func resetDevice() {
        guard isConnected else { return }

        Task {
            do {
                try await usbClient.reset()
            } catch {
                print("Failed to reset device: \(error)")
            }
        }
    }

    func menuToDevice() {
        guard isConnected else { return }

        Task {
            do {
                try await usbClient.menu()
            } catch {
                print("Failed to return to menu: \(error)")
            }
        }
    }

    // MARK: - Selection Management

    func selectLocalFile(_ fileName: String) { selectedLocalFile = fileName }
    func selectRemoteFile(_ fileName: String) { selectedRemoteFile = fileName }
    func clearLocalSelection() { selectedLocalFile = nil }
    func clearRemoteSelection() { selectedRemoteFile = nil }

    // MARK: - Navigation History Management

    private func addToNavigationHistory(_ path: String) {
        if remoteHistoryIndex < remoteNavigationHistory.count - 1 {
            remoteNavigationHistory.removeSubrange((remoteHistoryIndex + 1)...)
        }

        if remoteNavigationHistory.last != path {
            remoteNavigationHistory.append(path)
            remoteHistoryIndex = remoteNavigationHistory.count - 1
        }

        updateNavigationButtons()
    }

    private func updateNavigationButtons() {
        canGoBack = remoteHistoryIndex > 0
        canGoForward = remoteHistoryIndex < remoteNavigationHistory.count - 1
    }

    func navigateBack() {
        guard canGoBack else { return }

        remoteHistoryIndex -= 1
        let targetPath = remoteNavigationHistory[remoteHistoryIndex]

        Task {
            await navigateToPath(targetPath, addToHistory: false)
        }
    }

    func navigateForward() {
        guard canGoForward else { return }

        remoteHistoryIndex += 1
        let targetPath = remoteNavigationHistory[remoteHistoryIndex]

        Task {
            await navigateToPath(targetPath, addToHistory: false)
        }
    }

    private func navigateToPath(_ path: String, addToHistory: Bool = true) async {
        currentRemotePath = path
        remoteBreadcrumbs = path.isEmpty ? [] : path.components(separatedBy: "/")
        clearRemoteSelection()

        if addToHistory {
            addToNavigationHistory(path)
        } else {
            updateNavigationButtons()
        }

        await refreshRemoteFiles()
    }
}

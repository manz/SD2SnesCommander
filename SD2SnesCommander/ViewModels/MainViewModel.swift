import SwiftUI
import Foundation
import AppKit
import Combine
import SD2snesCommanderCore

/*
struct LocalFileItem {
    let name: String
    let path: String
    let size: Int64
    let isDirectory: Bool
    
    var formattedSize: String {
        if isDirectory { return "" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }

    var isRomFile: Bool {
        let romExtensions = ["smc", "sfc", "fig", "swc", "bs"]
        return romExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }
}

struct RemoteFileItem {
    let name: String
    let isDirectory: Bool
    
    var isRomFile: Bool {
        let romExtensions = ["smc", "sfc", "fig", "swc", "bs", "gb"]
        return romExtensions.contains(URL(fileURLWithPath: name).pathExtension.lowercased())
    }
}
*/


@MainActor
class MainViewModel: ObservableObject {
    // Connection state
    @Published var isConnected = false
    @Published var connectionStatus = "Disconnected"
    @Published var isConnecting = false
    @Published var deviceName: String = "SD2Snes Commander"
    
    // File data
    @Published var localFiles: [LocalFileItem] = []
    @Published var remoteFiles: [RemoteFileItem] = []
    @Published var currentLocalPath = ""
    @Published var currentRemotePath = ""
    @Published var remoteBreadcrumbs: [String] = []

    // Navigation history
    @Published var remoteNavigationHistory: [String] = []
    @Published var remoteHistoryIndex: Int = -1
    @Published var canGoBack: Bool = false
    @Published var canGoForward: Bool = false

    // Selection state
    @Published var selectedLocalFile: String? = nil
    @Published var selectedRemoteFile: String? = nil
    
    // Transfer state
    @Published var isTransferInProgress = false
    @Published var transferProgress: Double = 0.0
    @Published var transferStatus = ""
    
    // Dependencies
    private let usbClient = SD2SnesUSBClient()
    private let fileManager = LocalFileManager()
    
    private var transferTask: Task<Void, Never>?
    
    init() {
        setupClient()
    }
    
    deinit {
        transferTask?.cancel()
    }
    
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
                
                var info = try await usbClient.info()

                deviceName = info.deviceName ?? "SD2SNES USB"
                connectionStatus = "Connected to \(deviceName) via USB"
                
                isConnected = true
                
                await refreshRemoteFiles()
            } catch {
                connectionStatus = "Failed to connect"
                isConnected = false
                
                // Show user-friendly error
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
        fileManager.browseForDirectory { [weak self] url in
            guard let self = self, let url = url else { return }
            
            Task { @MainActor in
                self.currentLocalPath = url.path
                self.loadLocalFiles(at: url)
            }
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
            // Filter out dot directories
            remoteFiles = files.filter { !$0.name.hasPrefix(".") }
            
            // Initialize history on first load
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

                // Check for IPS patch if this is a ROM file
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
                        transferStatus = "IPS patch failed: \(error.localizedDescription)"
                        // Continue with original file if patching fails
                        transferStatus = "Uploading \(file.name)..."
                    }
                } else {
                    transferStatus = "Uploading \(file.name)..."
                }

                // Construct remote path without leading slash (SD2SNES format)
                let fullRemotePath: String
                if currentRemotePath.isEmpty {
                    fullRemotePath = file.name
                } else {
                    fullRemotePath = "\(currentRemotePath)/\(file.name)"
                }

                try await usbClient.uploadFile(
                    localPath: actualFilePath,
                    remotePath: fullRemotePath,
                    progressHandler: { [weak self] progress in
                        print("Upload progress: \(progress)")
                        Task { @MainActor in
                            self?.transferProgress = progress
                        }
                    }
                )

                transferStatus = "Upload completed"
                await self.refreshRemoteFiles()

                // Clean up temporary file if it was created
                if let tempPath = tempFilePath {
                    try? FileManager.default.removeItem(atPath: tempPath)
                }

                // Clear transfer state after a delay
                try await Task.sleep(nanoseconds: 2_000_000_000)
                isTransferInProgress = false
                transferStatus = ""

            } catch {
                // Clean up temporary file on error
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
        
        fileManager.saveFile(suggestedName: file.name) { [weak self] url in
            guard let self = self, let url = url else { return }
            
            self.transferTask?.cancel()
            self.transferTask = Task {
                do {
                    await MainActor.run {
                        self.isTransferInProgress = true
                        self.transferProgress = 0.0
                        self.transferStatus = "Downloading \(file.name)..."
                    }
                    
                    // Construct remote path without leading slash (SD2SNES format)
                    let fullRemotePath: String
                    if self.currentRemotePath.isEmpty {
                        fullRemotePath = file.name
                    } else {
                        fullRemotePath = "\(self.currentRemotePath)/\(file.name)"
                    }
                    
                    try await self.usbClient.downloadFile(
                        remotePath: fullRemotePath,
                        localPath: url.path,
                        progressHandler: { [weak self] progress in
                            print("Download progress: \(progress)")
                            Task { @MainActor in
                                self?.transferProgress = progress
                            }
                        }
                    )
                    
                    await MainActor.run {
                        self.transferStatus = "Download completed"
                    }
                    
                    // Clear transfer state after a delay
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    await MainActor.run {
                        self.isTransferInProgress = false
                        self.transferStatus = ""
                    }
                    
                } catch {
                    await MainActor.run {
                        self.transferStatus = "Download failed: \(error.localizedDescription)"
                        self.isTransferInProgress = false
                    }
                }
            }
        }
    }
    
    func deleteRemoteFile(_ file: RemoteFileItem) {
        guard isConnected else { return }
        
        // Show confirmation dialog
        let alert = NSAlert()
        alert.messageText = "Delete File"
        alert.informativeText = "Are you sure you want to delete \"\(file.name)\"? This action cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        
        if alert.runModal() == .alertFirstButtonReturn {
            Task {
                do {
                    // Construct remote path without leading slash (SD2SNES format)
                    let fullRemotePath: String
                    if currentRemotePath.isEmpty {
                        fullRemotePath = file.name
                    } else {
                        fullRemotePath = "\(currentRemotePath)/\(file.name)"
                    }
                    try await usbClient.deleteFile(path: fullRemotePath)
                    await self.refreshRemoteFiles()
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
                // Construct remote path without leading slash (SD2SNES format)
                let fullRemotePath: String
                if currentRemotePath.isEmpty {
                    fullRemotePath = file.name
                } else {
                    fullRemotePath = "\(currentRemotePath)/\(file.name)"
                }
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

    func selectLocalFile(_ fileName: String) {
        selectedLocalFile = fileName
    }

    func selectRemoteFile(_ fileName: String) {
        selectedRemoteFile = fileName
    }

    func clearLocalSelection() {
        selectedLocalFile = nil
    }

    func clearRemoteSelection() {
        selectedRemoteFile = nil
    }

    // MARK: - Navigation History Management

    private func addToNavigationHistory(_ path: String) {
        // Remove any forward history beyond current index
        if remoteHistoryIndex < remoteNavigationHistory.count - 1 {
            remoteNavigationHistory.removeSubrange((remoteHistoryIndex + 1)...)
        }

        // Don't add the same path consecutively
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

    // MARK: - Private Methods

    private func setupClient() {
        // Configure client callbacks if needed
    }
}

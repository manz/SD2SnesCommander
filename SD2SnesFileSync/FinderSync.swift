import Cocoa
import FinderSync
import Foundation
import Combine
import os.log
import SD2snesCommanderCore

// MARK: - SD2Snes Connection Manager

@MainActor
class SD2SnesConnectionManager: ObservableObject {
    static let shared = SD2SnesConnectionManager()

    @Published var isConnected = false
    @Published var currentPath = ""
    @Published var files: [RemoteFileItem] = []

    private let logger = Logger(subsystem: "SD2SnesFileSync", category: "Connection")
    private let usbClient = SD2SnesUSBClient()
    private var refreshTimer: Timer?

    private init() {}

    func connect() async throws {
        logger.info("Connecting to SD2Snes device...")

        try await usbClient.connect()
        isConnected = await usbClient.isConnected
        currentPath = ""
        await refreshFiles()

        // Start periodic refresh
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

        // Handle IPS patching for ROM files
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

        // Upload the file (original or patched)
        try await usbClient.uploadFile(localPath: actualFilePath, remotePath: remotePath)

        // Clean up temporary file
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
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { _ in
            Task { @MainActor in
                await self.refreshFiles()
            }
        }
    }

    private func stopPeriodicRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }
}

// MARK: - Finder Sync Extension

class FinderSync: FIFinderSync {
    private let logger = Logger(subsystem: "SD2SnesFileSync", category: "FinderSync")
    private let connectionManager = SD2SnesConnectionManager.shared

    // Virtual SD2Snes directory URL - use user Documents for sandbox compatibility
    private let sd2snesURL: URL = {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return documentsURL.appendingPathComponent("SD2Snes Device")
    }()

    override init() {
        super.init()

        logger.info("SD2Snes FinderSync extension launched")

        // Set up the SD2Snes virtual directory
        setupVirtualDirectory()

        // Configure badge images
        setupBadgeImages()

        // Add sidebar item
        addSidebarItem()
    }

    // MARK: - Setup Methods

    private func setupVirtualDirectory() {
        // Create virtual directory if it doesn't exist
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: sd2snesURL.path) {
            do {
                try fileManager.createDirectory(at: sd2snesURL, withIntermediateDirectories: true)
                logger.info("Created virtual SD2Snes directory at: \(self.sd2snesURL.path)")
            } catch {
                logger.error("Failed to create virtual directory: \(error)")
            }
        }

        // Set up directory monitoring
        FIFinderSyncController.default().directoryURLs = [sd2snesURL]
    }

    private func setupBadgeImages() {
        // ROM file badge
        if let romImage = NSImage(systemSymbolName: "gamecontroller.fill", accessibilityDescription: "ROM") {
            FIFinderSyncController.default().setBadgeImage(romImage, label: "Bootable ROM", forBadgeIdentifier: "rom")
        }

        // Connected badge
        if let connectedImage = NSImage(systemSymbolName: "cable.connector", accessibilityDescription: "Connected") {
            FIFinderSyncController.default().setBadgeImage(connectedImage, label: "Connected", forBadgeIdentifier: "connected")
        }

        // Disconnected badge
        if let disconnectedImage = NSImage(systemSymbolName: "cable.connector.slash", accessibilityDescription: "Disconnected") {
            FIFinderSyncController.default().setBadgeImage(disconnectedImage, label: "Disconnected", forBadgeIdentifier: "disconnected")
        }
    }

    private func addSidebarItem() {
        // Ensure directory exists - using Documents folder which is sandbox-accessible
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: sd2snesURL.path) {
            do {
                try fileManager.createDirectory(at: sd2snesURL, withIntermediateDirectories: true)
                logger.info("Created SD2Snes directory at: \(self.sd2snesURL.path)")
            } catch {
                logger.error("Failed to create directory: \(error)")
                return
            }
        }

        // The key is to make Finder recognize this as a special sync folder
        // by setting up proper directory monitoring and badges
        logger.info("SD2Snes directory ready for Finder Sync at: \(self.sd2snesURL.path)")
    }

    // MARK: - Finder Sync Protocol Methods

    override func beginObservingDirectory(at url: URL) {
        logger.info("Begin observing directory: \(url.path)")

        if url.path.hasPrefix(sd2snesURL.path) {
            // User is viewing the SD2Snes directory or subdirectory
            Task { @MainActor in
                let isConnected = await self.connectionManager.isConnected
                if !isConnected {
                    // Auto-connect when user opens SD2Snes folder
                    await self.connectToSD2Snes()
                } else {
                    // Update current path based on viewed directory
                    await self.updateCurrentPathFromURL(url)
                    await self.updateVirtualFileSystem()
                }
            }
        }
    }

    private func updateCurrentPathFromURL(_ url: URL) async {
        let relativePath = String(url.path.dropFirst(sd2snesURL.path.count))
        let cleanPath = relativePath.hasPrefix("/") ? String(relativePath.dropFirst()) : relativePath

        let currentPath = await connectionManager.currentPath
        if cleanPath != currentPath {
            if cleanPath.isEmpty {
                await MainActor.run {
                    connectionManager.currentPath = ""
                }
            } else {
                await MainActor.run {
                    connectionManager.currentPath = cleanPath
                }
            }
            await connectionManager.refreshFiles()
        }
    }

    override func endObservingDirectory(at url: URL) {
        logger.info("End observing directory: \(url.path)")
    }

    override func requestBadgeIdentifier(for url: URL) {
        guard url.path.hasPrefix(sd2snesURL.path) else { return }

        let fileName = url.lastPathComponent

        // Check if it's a ROM file
        let romExtensions = ["smc", "sfc", "fig", "swc", "bs", "gb"]
        let isRomFile = romExtensions.contains(url.pathExtension.lowercased())

        if isRomFile {
            FIFinderSyncController.default().setBadgeIdentifier("rom", for: url)
        } else if fileName == "SD2Snes" || url == sd2snesURL {
            // Badge for the main directory - will be updated asynchronously
            Task { @MainActor in
                let badgeId = await self.connectionManager.isConnected ? "connected" : "disconnected"
                FIFinderSyncController.default().setBadgeIdentifier(badgeId, for: url)
            }
        }
    }

    // MARK: - Toolbar and Menu Support

    override var toolbarItemName: String {
        return "SD2Snes Device"
    }

    override var toolbarItemToolTip: String {
        return "SD2Snes Commander: Click to open device folder and connect"
    }

    override var toolbarItemImage: NSImage {
        // Use a more distinctive icon
        if let image = NSImage(systemSymbolName: "gamecontroller.fill", accessibilityDescription: "SD2Snes") {
            return image
        }
        return NSImage(systemSymbolName: "externaldrive.badge.wifi", accessibilityDescription: "SD2Snes") ?? NSImage()
    }


    override func menu(for menuKind: FIMenuKind) -> NSMenu {
        let menu = NSMenu(title: "SD2Snes")

        switch menuKind {
        case .contextualMenuForItems:
            return contextMenuForItems()
        case .contextualMenuForContainer:
            return contextMenuForContainer()
        case .contextualMenuForSidebar:
            return contextMenuForSidebar()
        case .toolbarItemMenu:
            return toolbarMenu()
        @unknown default:
            return menu
        }
    }

    private func contextMenuForItems() -> NSMenu {
        let menu = NSMenu(title: "")
        let selectedURLs = FIFinderSyncController.default().selectedItemURLs() ?? []

        for url in selectedURLs {
            let isRomFile = isROMFile(url)
            let isSD2SnesFile = url.path.hasPrefix(sd2snesURL.path)

            if isSD2SnesFile {
                // This is a file in the SD2Snes virtual directory
                if isRomFile {
                    // Add Boot option for ROM files
                    let bootItem = NSMenuItem(title: "Boot ROM", action: #selector(bootROM(_:)), keyEquivalent: "")
                    bootItem.representedObject = url
                    menu.addItem(bootItem)
                    menu.addItem(NSMenuItem.separator())
                }

                // Add download option
                let downloadItem = NSMenuItem(title: "Download from SD2Snes", action: #selector(downloadFile(_:)), keyEquivalent: "")
                downloadItem.representedObject = url
                menu.addItem(downloadItem)

                // Add delete option
                let deleteItem = NSMenuItem(title: "Delete from SD2Snes", action: #selector(deleteRemoteFile(_:)), keyEquivalent: "")
                deleteItem.representedObject = url
                menu.addItem(deleteItem)

            } else {
                // This is a local file - add upload option
                let uploadItem = NSMenuItem(title: "Upload to SD2Snes", action: #selector(uploadFile(_:)), keyEquivalent: "")
                uploadItem.representedObject = url
                menu.addItem(uploadItem)

                // Show IPS patching info for ROM files
                if isRomFile {
                    menu.addItem(NSMenuItem.separator())
                    let ipsItem = NSMenuItem(title: "Upload with IPS Patching", action: #selector(uploadFile(_:)), keyEquivalent: "")
                    ipsItem.representedObject = url
                    menu.addItem(ipsItem)
                }
            }
        }

        if menu.items.isEmpty {
            let noActionsItem = NSMenuItem(title: "No actions available", action: nil, keyEquivalent: "")
            noActionsItem.isEnabled = false
            menu.addItem(noActionsItem)
        }

        return menu
    }

    private func contextMenuForContainer() -> NSMenu {
        let menu = NSMenu(title: "")

        // Since we can't access main actor properties synchronously from background queue,
        // we'll create a menu with both options and let actions handle the logic
        menu.addItem(NSMenuItem(title: "Connect to SD2Snes", action: #selector(connectToSD2Snes(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Refresh", action: #selector(refreshFiles(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Disconnect", action: #selector(disconnectFromSD2Snes(_:)), keyEquivalent: ""))

        return menu
    }

    private func contextMenuForSidebar() -> NSMenu {
        let menu = NSMenu(title: "")

        // Provide both options and let actions handle the logic
        menu.addItem(NSMenuItem(title: "Connect", action: #selector(connectToSD2Snes(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Disconnect", action: #selector(disconnectFromSD2Snes(_:)), keyEquivalent: ""))

        return menu
    }

    private func toolbarMenu() -> NSMenu {
        let menu = NSMenu(title: "")

        // Always show the option to open the folder
        let openFolderItem = NSMenuItem(title: "Open SD2Snes Folder", action: #selector(openSD2SnesFolder(_:)), keyEquivalent: "")
        menu.addItem(openFolderItem)
        menu.addItem(NSMenuItem.separator())

        // Provide all options and let actions handle the logic
        menu.addItem(NSMenuItem(title: "Connect to SD2Snes", action: #selector(connectToSD2Snes(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Refresh Files", action: #selector(refreshFiles(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Disconnect", action: #selector(disconnectFromSD2Snes(_:)), keyEquivalent: ""))

        return menu
    }

    // MARK: - Action Methods

    @objc func connectToSD2Snes(_ sender: AnyObject? = nil) {
        Task { @MainActor in
            // Check if already connected
            let isConnected = await connectionManager.isConnected
            if isConnected {
                return // Already connected, do nothing
            }
            await connectToSD2Snes()
        }
    }

    @MainActor
    private func connectToSD2Snes() async {
        do {
            try await connectionManager.connect()

            // Update badges
            FIFinderSyncController.default().setBadgeIdentifier("connected", for: sd2snesURL)

            // Update virtual file system
            await updateVirtualFileSystem()

            // Refresh finder view
            refreshFinderView()

        } catch {
            logger.error("Failed to connect: \(error)")
            showAlert(title: "Connection Failed", message: "Could not connect to SD2Snes device: \(error.localizedDescription)")
        }
    }

    @objc func disconnectFromSD2Snes(_ sender: AnyObject? = nil) {
        Task { @MainActor in
            // Check if already disconnected
            let isConnected = await connectionManager.isConnected
            if !isConnected {
                return // Already disconnected, do nothing
            }

            await connectionManager.disconnect()

            // Update badges
            FIFinderSyncController.default().setBadgeIdentifier("disconnected", for: sd2snesURL)

            // Refresh finder view
            refreshFinderView()
        }
    }

    @objc func refreshFiles(_ sender: AnyObject? = nil) {
        Task { @MainActor in
            // Only refresh if connected
            let isConnected = await connectionManager.isConnected
            if isConnected {
                await connectionManager.refreshFiles()
                refreshFinderView()
            }
        }
    }

    @objc func bootROM(_ sender: AnyObject?) {
        guard let menuItem = sender as? NSMenuItem,
              let url = menuItem.representedObject as? URL else { return }

        let romPath = url.path.replacingOccurrences(of: sd2snesURL.path + "/", with: "")

        Task {
            await bootROMFile(path: romPath)
        }
    }

    @objc func uploadFile(_ sender: AnyObject?) {
        guard let menuItem = sender as? NSMenuItem,
              let url = menuItem.representedObject as? URL else { return }

        Task {
            await uploadFileToSD2Snes(localURL: url)
        }
    }

    @objc func downloadFile(_ sender: AnyObject?) {
        guard let menuItem = sender as? NSMenuItem,
              let url = menuItem.representedObject as? URL else { return }

        Task {
            await downloadFileFromSD2Snes(remoteURL: url)
        }
    }

    @objc func deleteRemoteFile(_ sender: AnyObject?) {
        guard let menuItem = sender as? NSMenuItem,
              let url = menuItem.representedObject as? URL else { return }

        Task {
            await deleteFileFromSD2Snes(remoteURL: url)
        }
    }

    @objc func openSD2SnesFolder(_ sender: AnyObject? = nil) {
        logger.info("Opening SD2Snes folder")
        NSWorkspace.shared.open(sd2snesURL)
    }

    // MARK: - Helper Methods

    private func isROMFile(_ url: URL) -> Bool {
        let romExtensions = ["smc", "sfc", "fig", "swc", "bs", "gb"]
        return romExtensions.contains(url.pathExtension.lowercased())
    }

    private func refreshFinderView() {
        // Force Finder to refresh the view by requesting badge updates
        Task { @MainActor in
            // Request badge updates for the main directory and files
            self.requestBadgeIdentifier(for: self.sd2snesURL)
            let files = await self.connectionManager.files
            for file in files {
                let fileURL = self.sd2snesURL.appendingPathComponent(file.name)
                self.requestBadgeIdentifier(for: fileURL)
            }
        }
    }

    private func bootROMFile(path: String) async {
        logger.info("Booting ROM: \(path)")

        do {
            try await connectionManager.bootROM(fileName: URL(fileURLWithPath: path).lastPathComponent)
            DispatchQueue.main.async {
                self.showAlert(title: "ROM Boot", message: "Successfully booted ROM: \(path)")
            }
        } catch {
            logger.error("Failed to boot ROM: \(error)")
            DispatchQueue.main.async {
                self.showAlert(title: "Boot Failed", message: "Failed to boot ROM: \(error.localizedDescription)")
            }
        }
    }

    private func uploadFileToSD2Snes(localURL: URL) async {
        logger.info("Uploading file: \(localURL.path)")

        let isConnected = await connectionManager.isConnected
        guard isConnected else {
            DispatchQueue.main.async {
                self.showAlert(title: "Not Connected", message: "Please connect to SD2Snes first")
            }
            return
        }

        do {
            try await connectionManager.uploadFile(localPath: localURL.path)
            DispatchQueue.main.async {
                self.showAlert(title: "Upload Complete", message: "Successfully uploaded: \(localURL.lastPathComponent)")
            }
            // Update the virtual file system
            await updateVirtualFileSystem()
        } catch {
            logger.error("Failed to upload file: \(error)")
            DispatchQueue.main.async {
                self.showAlert(title: "Upload Failed", message: "Failed to upload: \(error.localizedDescription)")
            }
        }
    }

    @MainActor
    private func downloadFileFromSD2Snes(remoteURL: URL) async {
        logger.info("Downloading file from SD2Snes: \(remoteURL.lastPathComponent)")

        guard await connectionManager.isConnected else {
            showAlert(title: "Not Connected", message: "Please connect to SD2Snes first")
            return
        }

        // Show save dialog
        let savePanel = NSSavePanel()
        savePanel.nameFieldStringValue = remoteURL.lastPathComponent
        savePanel.title = "Save File from SD2Snes"

        if savePanel.runModal() == .OK, let saveURL = savePanel.url {
            do {
                let remotePath = remoteURL.path.replacingOccurrences(of: sd2snesURL.path + "/", with: "")
                try await connectionManager.downloadFile(remotePath: remotePath, localPath: saveURL.path)
                showAlert(title: "Download Complete", message: "File saved to: \(saveURL.lastPathComponent)")
            } catch {
                logger.error("Download failed: \(error)")
                showAlert(title: "Download Failed", message: "Failed to download: \(error.localizedDescription)")
            }
        }
    }

    @MainActor
    private func deleteFileFromSD2Snes(remoteURL: URL) async {
        logger.info("Deleting file from SD2Snes: \(remoteURL.lastPathComponent)")

        guard await connectionManager.isConnected else {
            showAlert(title: "Not Connected", message: "Please connect to SD2Snes first")
            return
        }

        // Show confirmation dialog
        let alert = NSAlert()
        alert.messageText = "Delete File"
        alert.informativeText = "Are you sure you want to delete \"\(remoteURL.lastPathComponent)\" from the SD2Snes? This action cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            do {
                try await connectionManager.deleteFile(fileName: remoteURL.lastPathComponent)
                await updateVirtualFileSystem()
                showAlert(title: "File Deleted", message: "Successfully deleted: \(remoteURL.lastPathComponent)")
            } catch {
                logger.error("Delete failed: \(error)")
                showAlert(title: "Delete Failed", message: "Failed to delete: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Virtual File System Management

    private func updateVirtualFileSystem() async {
        // Create virtual files that represent the remote files
        let fileManager = FileManager.default

        // Clear existing virtual files (except .DS_Store and system files)
        if let existingFiles = try? fileManager.contentsOfDirectory(atPath: sd2snesURL.path) {
            for file in existingFiles {
                if !file.hasPrefix(".") {
                    let fileURL = sd2snesURL.appendingPathComponent(file)
                    try? fileManager.removeItem(at: fileURL)
                }
            }
        }

        // Create virtual files for remote files
        let files = await connectionManager.files
        for file in files {
            let virtualFileURL = sd2snesURL.appendingPathComponent(file.name)

            if file.isDirectory {
                // Create directory
                try? fileManager.createDirectory(at: virtualFileURL, withIntermediateDirectories: false)
            } else {
                // Create empty file with correct extension
                try? "".write(to: virtualFileURL, atomically: true, encoding: .utf8)

                // Set custom icon for ROM files
                if file.isRomFile {
                    setCustomIconForROMFile(at: virtualFileURL)
                }
            }
        }

        // Request badge updates for all files
        refreshFinderView()
    }

    private func setCustomIconForROMFile(at url: URL) {
        // Set a custom icon for ROM files to make them easily identifiable
        if let romIcon = NSImage(systemSymbolName: "gamecontroller.fill", accessibilityDescription: "ROM") {
            _ = NSWorkspace.shared.setIcon(romIcon, forFile: url.path, options: [])
        }
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

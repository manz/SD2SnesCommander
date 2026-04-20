import AppKit
import Foundation
import SD2snesCommanderCore

@MainActor
extension MainViewModel {
    // MARK: - Local Files

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

    // MARK: - Remote Files

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
}

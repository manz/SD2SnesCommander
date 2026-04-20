import AppKit
import Foundation
import SD2snesCommanderCore

@MainActor
extension MainViewModel {
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
}

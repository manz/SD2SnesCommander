import AppKit
import Foundation
import SD2snesCommanderCore

@MainActor
extension MainViewModel {
    // Pipe a progress stream into transferProgress on the main actor with
    // last-value-wins coalescing — without this, every C tick would spawn a
    // new MainActor Task and queue could grow unbounded on fast transfers.
    private func makeProgressBridge() -> (handler: @Sendable (Double) -> Void, finish: () -> Void, drain: Task<Void, Never>) {
        let (stream, continuation) = AsyncStream<Double>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let drain = Task { @MainActor [weak self] in
            for await progress in stream {
                self?.transferProgress = progress
            }
        }
        let handler: @Sendable (Double) -> Void = { progress in
            continuation.yield(progress)
        }
        let finish = { continuation.finish() }
        return (handler, finish, drain)
    }

    func uploadFile(_ file: LocalFileItem) {
        guard !file.isDirectory && isConnected else { return }

        transferTask?.cancel()
        transferTask = Task {
            var actualFilePath = file.path
            var tempFilePath: String? = nil

            isTransferInProgress = true
            transferProgress = 0.0

            if file.isRomFile, let ipsPath = IPSPatcher.findIPSPatch(for: file.path) {
                transferStatus = String(localized: "Applying IPS patch…")
                do {
                    tempFilePath = try IPSPatcher.createTemporaryPatchedFile(
                        romPath: file.path,
                        ipsPath: ipsPath
                    )
                    actualFilePath = tempFilePath!
                    transferStatus = String(format: String(localized: "Uploading patched %@…"), file.name)
                } catch {
                    transferStatus = String(format: String(localized: "IPS patch failed: %@. Uploading %@…"), error.localizedDescription, file.name)
                }
            } else {
                transferStatus = String(format: String(localized: "Uploading %@…"), file.name)
            }

            let fullRemotePath = currentRemotePath.isEmpty
                ? file.name
                : "\(currentRemotePath)/\(file.name)"

            let bridge = makeProgressBridge()

            do {
                try await usbClient.uploadFile(
                    localPath: actualFilePath,
                    remotePath: fullRemotePath,
                    progressHandler: bridge.handler
                )
                bridge.finish()
                _ = await bridge.drain.value

                transferStatus = String(localized: "Upload completed")
                transferProgress = 1.0
                await refreshRemoteFiles()

                if let tempPath = tempFilePath {
                    try? FileManager.default.removeItem(atPath: tempPath)
                }

                try? await Task.sleep(nanoseconds: 2_000_000_000)
                isTransferInProgress = false
                transferStatus = ""
            } catch {
                bridge.finish()
                if let tempPath = tempFilePath {
                    try? FileManager.default.removeItem(atPath: tempPath)
                }
                transferStatus = String(format: String(localized: "Upload failed: %@"), error.localizedDescription)
                isTransferInProgress = false
            }
        }
    }

    func downloadFile(_ file: RemoteFileItem) {
        guard !file.isDirectory else { return }

        transferTask?.cancel()
        transferTask = Task {
            guard let url = await fileManager.saveFile(suggestedName: file.name) else { return }

            isTransferInProgress = true
            transferProgress = 0.0
            transferStatus = String(format: String(localized: "Downloading %@…"), file.name)

            let fullRemotePath = currentRemotePath.isEmpty
                ? file.name
                : "\(currentRemotePath)/\(file.name)"

            let bridge = makeProgressBridge()

            do {
                try await usbClient.downloadFile(
                    remotePath: fullRemotePath,
                    localPath: url.path,
                    progressHandler: bridge.handler
                )
                bridge.finish()
                _ = await bridge.drain.value

                transferStatus = String(localized: "Download completed")
                transferProgress = 1.0

                try? await Task.sleep(nanoseconds: 2_000_000_000)
                isTransferInProgress = false
                transferStatus = ""
            } catch {
                bridge.finish()
                transferStatus = String(format: String(localized: "Download failed: %@"), error.localizedDescription)
                isTransferInProgress = false
            }
        }
    }

    func deleteRemoteFile(_ file: RemoteFileItem) {
        guard isConnected else { return }

        let alert = NSAlert()
        alert.messageText = String(localized: "Delete File")
        alert.informativeText = String(
            format: String(localized: "Are you sure you want to delete \"%@\"? This action cannot be undone."),
            file.name
        )
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "Delete"))
        alert.addButton(withTitle: String(localized: "Cancel"))

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

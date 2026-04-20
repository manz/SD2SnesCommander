import AppKit
import SD2snesCommanderCore

@MainActor
extension MainViewModel {
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
}

import AppKit
import SD2snesCommanderCore

@MainActor
extension MainViewModel {
    func connect() {
        guard !isConnecting else { return }

        Task {
            isConnecting = true
            connectionStatus = String(localized: "Searching for SD2SNES device…")

            do {
                try await usbClient.connect()

                let info = try await usbClient.info()

                deviceName = info.deviceName ?? "SD2SNES USB"
                connectionStatus = String(format: String(localized: "Connected to %@ via USB"), deviceName)
                isConnected = true
                isGaming = Self.isGamingFromRomName(info.romName)
                currentRomName = Self.displayRomName(info.romName, gaming: isGaming)

                startInfoPolling()
                await refreshRemoteFiles()
            } catch {
                connectionStatus = String(localized: "Failed to connect")
                isConnected = false

                let alert = NSAlert()
                alert.messageText = String(localized: "USB Connection Failed")
                alert.informativeText = String(
                    format: String(localized: "Could not find or connect to SD2SNES device via USB. Make sure the device is connected and powered on.\n\nError: %@"),
                    error.localizedDescription
                )
                alert.alertStyle = .warning
                alert.addButton(withTitle: String(localized: "OK"))
                alert.runModal()
            }

            isConnecting = false
        }
    }

    func disconnect() {
        infoPollTask?.cancel()
        infoPollTask = nil
        transferTask?.cancel()
        transferTask = nil
        Task {
            await usbClient.disconnect()
            isConnected = false
            isGaming = false
            awaitingMenu = false
            currentRomName = nil
            connectionStatus = String(localized: "Disconnected")
            deviceName = String(localized: "SD2Snes Commander")
            remoteFiles = []
            clearRemoteSelection()
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
                // Optimistically flip the UI out of the gaming placeholder
                // and arm awaitingMenu. The FPGA reload window can leave
                // INFO reporting the old rom path for a poll cycle or two —
                // awaitingMenu makes pollInfo ignore that until the menu
                // binary path actually shows up.
                awaitingMenu = true
                isGaming = false
                currentRomName = nil
            } catch {
                print("Failed to return to menu: \(error)")
            }
        }
    }

    // MARK: - State polling

    func startInfoPolling() {
        infoPollTask?.cancel()
        infoPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { return }
                await self?.pollInfo()
            }
        }
    }

    private func pollInfo() async {
        // INFO is unreliable while a game is running — firmware services USB
        // but CDC endpoint timing collides with SRAM bridging. Stop polling
        // once gaming is detected; Return to Menu flips isGaming back and
        // polling resumes.
        guard isConnected, !isTransferInProgress, !isGaming else { return }
        do {
            let info = try await usbClient.info()
            // Re-check after the await — disconnect or a transfer may have
            // started during the round-trip.
            guard isConnected, !isTransferInProgress else { return }

            let reportsMenu = !Self.isGamingFromRomName(info.romName)

            // While we're waiting for menu_reset to settle, only trust an
            // INFO that actually reports the menu binary. Anything else
            // (still showing the old rom path, empty path, etc.) is the
            // FPGA-reload echo and gets ignored.
            let menuJustConfirmed: Bool
            if awaitingMenu {
                if reportsMenu {
                    awaitingMenu = false
                    menuJustConfirmed = true
                } else {
                    return
                }
            } else {
                menuJustConfirmed = false
            }

            let nowGaming = !reportsMenu
            let previousRom = currentRomName
            currentRomName = Self.displayRomName(info.romName, gaming: nowGaming)
            let romChanged = previousRom != currentRomName
            if nowGaming != isGaming {
                isGaming = nowGaming
            }
            // Refresh file list when transitioning to menu or rom context changes.
            if !nowGaming && (romChanged || remoteFiles.isEmpty || menuJustConfirmed) {
                await refreshRemoteFiles()
            }
        } catch {
            // Treat info errors as a hint that the device may have gone away;
            // mirror the C-side state (which recover_pipe flips on hard
            // disconnect) into the UI flag so the connect/disconnect button
            // and dependent views update.
            let stillThere = await usbClient.isConnected
            if !stillThere {
                isConnected = false
                isGaming = false
                awaitingMenu = false
                currentRomName = nil
                connectionStatus = String(localized: "Disconnected")
                remoteFiles = []
                clearRemoteSelection()
                infoPollTask?.cancel()
                infoPollTask = nil
            }
        }
    }

    static func displayRomName(_ name: String?, gaming: Bool) -> String? {
        guard gaming, let name, !name.isEmpty else { return nil }
        let last = (name as NSString).lastPathComponent
        return last.isEmpty ? name : last
    }

    static func isGamingFromRomName(_ name: String?) -> Bool {
        guard let name, !name.isEmpty else { return false }
        let lower = name.lowercased()
        // Menu sentinels: /sd2snes/m3nu.bin (Mk3), /sd2snes/menu.bin (Mk2)
        if lower.hasSuffix("m3nu.bin") || lower.hasSuffix("menu.bin") {
            return false
        }
        return true
    }
}

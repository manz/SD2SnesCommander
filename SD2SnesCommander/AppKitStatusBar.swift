import AppKit
import SwiftUI
import Combine

class AppKitStatusBar {
    private var statusItem: NSStatusItem?
    private var menu: NSMenu?
    private let statusBarManager = StatusBarManager()
    private var cancellables = Set<AnyCancellable>()

    init() {
        setupStatusBar()
        setupStatusObservation()
    }

    private func setupStatusBar() {
        // Create status item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            // Set icon
            button.image = NSImage(systemSymbolName: "externaldrive.connected.to.line.below",
                                 accessibilityDescription: "SD2Snes Commander")
        }

        // Create menu
        setupMenu()
        statusItem?.menu = menu
    }

    private func setupMenu() {
        menu = NSMenu()
        updateMenuItems()
    }

    private func updateMenuItems() {
        guard let menu = menu else { return }

        menu.removeAllItems()

        // Connection status (non-clickable)
        let statusItem = NSMenuItem()
        statusItem.title = statusBarManager.isConnected ?
            "✅ Connected to \(statusBarManager.deviceName)" :
            "❌ Disconnected"
        statusItem.isEnabled = false
        menu.addItem(statusItem)

        menu.addItem(NSMenuItem.separator())

        // Connection actions
        if statusBarManager.isConnected {
            let disconnectItem = NSMenuItem(title: "Disconnect", action: #selector(disconnectAction), keyEquivalent: "")
            disconnectItem.target = self
            menu.addItem(disconnectItem)

            let resetItem = NSMenuItem(title: "Reset Device", action: #selector(resetAction), keyEquivalent: "")
            resetItem.target = self
            menu.addItem(resetItem)
        } else {
            let connectItem = NSMenuItem(title: "Connect to Device", action: #selector(connectAction), keyEquivalent: "")
            connectItem.target = self
            menu.addItem(connectItem)
        }

        menu.addItem(NSMenuItem.separator())

        // Show main window
        let showWindowItem = NSMenuItem(title: "Show Main Window", action: #selector(showMainWindowAction), keyEquivalent: "")
        showWindowItem.target = self
        menu.addItem(showWindowItem)

        menu.addItem(NSMenuItem.separator())

        // Quit
        let quitItem = NSMenuItem(title: "Quit SD2Snes Commander", action: #selector(quitAction), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    @objc private func connectAction() {
        statusBarManager.connectToDevice()
    }

    @objc private func disconnectAction() {
        statusBarManager.disconnectFromDevice()
    }

    @objc private func resetAction() {
        statusBarManager.resetDevice()
    }

    @objc private func showMainWindowAction() {
        statusBarManager.showMainWindow()
    }

    @objc private func quitAction() {
        NSApplication.shared.terminate(nil)
    }

    private func setupStatusObservation() {
        statusBarManager.$isConnected
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isConnected in
                self?.updateIcon(connected: isConnected)
                self?.updateMenuItems()
            }
            .store(in: &cancellables)

        statusBarManager.$deviceName
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateMenuItems()
            }
            .store(in: &cancellables)
    }

    func updateIcon(connected: Bool) {
        let iconName = connected ? "externaldrive.connected.to.line.below.fill" : "externaldrive.connected.to.line.below"
        statusItem?.button?.image = NSImage(systemSymbolName: iconName,
                                          accessibilityDescription: "SD2Snes Commander")
    }
}
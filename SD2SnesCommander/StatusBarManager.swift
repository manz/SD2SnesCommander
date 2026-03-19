import SwiftUI
import Combine
import AppKit
import SD2snesCommanderCore

class StatusBarManager: ObservableObject {
    @Published var isConnected = false
    @Published var deviceName = "Not Connected"

    private var mainViewModel: MainViewModel {
        AppState.shared.mainViewModel
    }
    private var cancellables = Set<AnyCancellable>()

    init() {
        // Monitor connection status from the shared main view model
        setupConnectionMonitoring()
    }

    private func setupConnectionMonitoring() {
        // Subscribe to the shared main view model's connection state
        mainViewModel.$isConnected
            .receive(on: DispatchQueue.main)
            .assign(to: \.isConnected, on: self)
            .store(in: &cancellables)

        mainViewModel.$deviceName
            .receive(on: DispatchQueue.main)
            .assign(to: \.deviceName, on: self)
            .store(in: &cancellables)
    }

    @MainActor
    func connectToDevice() {
        mainViewModel.connect()
    }

    @MainActor
    func disconnectFromDevice() {
        mainViewModel.disconnect()
    }

    @MainActor
    func resetDevice() {
        mainViewModel.resetDevice()
    }

    func showMainWindow() {
        // Activate the main window
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first {
            window.makeKeyAndOrderFront(nil)
        }
    }
}
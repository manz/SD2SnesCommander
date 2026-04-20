import SwiftUI
import AppKit
import Observation
import SD2snesCommanderCore

@MainActor
@Observable
class StatusBarManager {
    private var mainViewModel: MainViewModel {
        AppState.shared.mainViewModel
    }

    var isConnected: Bool { mainViewModel.isConnected }
    var deviceName: String { mainViewModel.deviceName }

    func connectToDevice() { mainViewModel.connect() }
    func disconnectFromDevice() { mainViewModel.disconnect() }
    func resetDevice() { mainViewModel.resetDevice() }

    func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first {
            window.makeKeyAndOrderFront(nil)
        }
    }
}

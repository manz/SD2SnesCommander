import SwiftUI
import AppKit

@main
struct SD2SnesCommanderApp: App {
    @State private var appDelegate = AppDelegate()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About SD2Snes Commander") {
                }
            }

            CommandGroup(after: .newItem) {
                Button("Connect to Device") {
                }
                .keyboardShortcut("k", modifiers: .command)

                Divider()

                Button("Refresh Local Files") {
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }
    }
}

@MainActor
@Observable
class AppDelegate {
    var isReady = false
    @ObservationIgnored private var statusBar: AppKitStatusBar?

    init() {
        statusBar = AppKitStatusBar()
        isReady = true
    }
}

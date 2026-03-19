import SwiftUI
import AppKit
import Combine

@main
struct SD2SnesCommanderApp: App {
    @StateObject private var appDelegate = AppDelegate()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            // macOS menu bar commands
            CommandGroup(replacing: .appInfo) {
                Button("About SD2Snes Commander") {
                    // Show about dialog
                }
            }

            CommandGroup(after: .newItem) {
                Button("Connect to Device") {
                    // Connection action
                }
                .keyboardShortcut("k", modifiers: .command)

                Divider()

                Button("Refresh Local Files") {
                    // Refresh action
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }
    }
}

class AppDelegate: ObservableObject {
    @Published var isReady = false
    private var statusBar: AppKitStatusBar?

    init() {
        setupStatusBar()
        isReady = true
    }

    private func setupStatusBar() {
        statusBar = AppKitStatusBar()
    }
}
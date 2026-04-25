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
                    NSApplication.shared.orderFrontStandardAboutPanel(nil)
                }
                Divider()
                Button("Install Command Line Tool…") {
                    CommandLineToolInstaller.install()
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

                Divider()

                Button("Restart USB Service") {
                    USBServiceController.restart()
                }
                .keyboardShortcut("u", modifiers: [.command, .option, .shift])
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

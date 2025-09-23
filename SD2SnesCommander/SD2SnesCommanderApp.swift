import SwiftUI

@main
struct SD2SnesCommanderApp: App {
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
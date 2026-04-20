import SwiftUI

struct MenuBarView: View {
    @Environment(StatusBarManager.self) private var statusBarManager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "externaldrive.connected.to.line.below")
                    .foregroundColor(.blue)
                Text("SD2Snes Commander")
                    .font(.headline)
            }
            .padding(.bottom, 4)

            Divider()

            HStack {
                Circle()
                    .fill(statusBarManager.isConnected ? .green : .red)
                    .frame(width: 8, height: 8)

                VStack(alignment: .leading) {
                    Text(statusBarManager.isConnected ? "Connected" : "Disconnected")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text(statusBarManager.deviceName)
                        .font(.body)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                if statusBarManager.isConnected {
                    Button("Disconnect") {
                        statusBarManager.disconnectFromDevice()
                    }
                    .buttonStyle(.borderless)
                } else {
                    Button("Connect to Device") {
                        statusBarManager.connectToDevice()
                    }
                    .buttonStyle(.borderless)
                }

                Button("Show Main Window") {
                    statusBarManager.showMainWindow()
                }
                .buttonStyle(.borderless)
            }

            Divider()

            Button("Quit SD2Snes Commander") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.borderless)
        }
        .padding()
        .frame(width: 220)
    }
}

#Preview {
    MenuBarView()
        .environment(StatusBarManager())
}

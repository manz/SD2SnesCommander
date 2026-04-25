import SwiftUI
import UniformTypeIdentifiers
import SD2snesCommanderCore

struct ContentView: View {
    @State private var appState = AppState.shared

    private var viewModel: MainViewModel {
        appState.mainViewModel
    }

    var body: some View {
        NavigationSplitView {
            LocalFilesView(viewModel: viewModel)
                .navigationSplitViewColumnWidth(min: 300, ideal: 400)
        } detail: {
            RemoteFilesView(viewModel: viewModel)
                .navigationSplitViewColumnWidth(min: 300, ideal: 400)
        }
        .navigationTitle(viewModel.deviceName)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                ControlGroup {
                    Button(action: viewModel.navigateBack) {
                        Label("Back", systemImage: "chevron.left")
                    }
                    .help("Go Back")
                    .disabled(!viewModel.isConnected || viewModel.isGaming || !viewModel.canGoBack)

                    Button(action: viewModel.navigateForward) {
                        Label("Forward", systemImage: "chevron.right")
                    }
                    .help("Go Forward")
                    .disabled(!viewModel.isConnected || viewModel.isGaming || !viewModel.canGoForward)
                }
                .controlGroupStyle(.navigation)
            }

            ToolbarItemGroup(placement: .primaryAction) {
                if viewModel.isTransferInProgress {
                    ProgressView(value: viewModel.transferProgress)
                        .frame(width: 100)

                    Text("\(Int(viewModel.transferProgress * 100))%")
                        .font(.caption)
                        .monospacedDigit()
                }

                Button(action: viewModel.toggleConnection) {
                    Image(systemName: viewModel.isConnected ? "cable.connector" : "cable.connector.slash")
                }
                .help(viewModel.isConnected ? "Disconnect" : "Connect to SD2Snes")

                if viewModel.isConnected {
                    Menu {
                        Button("Reset Device") {
                            viewModel.resetDevice()
                        }

                        Button("Reset to Menu") {
                            viewModel.menuToDevice()
                        }
                    } label: {
                        Image(systemName: "gearshape.fill")
                    }
                    .help("Device Actions")
                }
            }
        }
        .onAppear {
            viewModel.initialize()
        }
    }
}

#Preview {
    ContentView()
}

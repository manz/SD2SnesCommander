import SwiftUI
import UniformTypeIdentifiers
import SD2snesCommanderCore

struct ContentView: View {
    @StateObject private var appState = AppState.shared

    private var viewModel: MainViewModel {
        appState.mainViewModel
    }
    
    var body: some View {
        NavigationSplitView {
            // Local files sidebar
            LocalFilesView(viewModel: viewModel)
                .navigationSplitViewColumnWidth(min: 300, ideal: 400)
        } detail: {
            // Remote device files
            RemoteFilesView(viewModel: viewModel)
                .navigationSplitViewColumnWidth(min: 300, ideal: 400)
        }
        .navigationTitle(viewModel.deviceName)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button(action: viewModel.toggleConnection) {
                    Image(systemName: viewModel.isConnected ? "cable.connector" : "cable.connector.slash")
                }
                .help(viewModel.isConnected ? "Disconnect" : "Connect to QUsb2Snes")
            }
            
            ToolbarItemGroup(placement: .primaryAction) {
                if viewModel.isTransferInProgress {
                    ProgressView(value: viewModel.transferProgress)
                        .frame(width: 100)

                    Text("\(Int(viewModel.transferProgress * 100))%")
                        .font(.caption)
                        .monospacedDigit()
                }

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

struct LocalFilesView: View {
    @ObservedObject var viewModel: MainViewModel
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Local Files")
                    .font(.headline)
                Spacer()
                Button("Browse...") {
                    viewModel.browseLocalFiles()
                }
            }
            .padding()
            
            Divider()
            
            // File list
            List(Array(viewModel.localFiles.enumerated()), id: \.element.path) { index, file in
                LocalFileRow(file: file, viewModel: viewModel)
                    .listRowBackground(
                        RoundedRectangle(cornerRadius: 0)
                            .fill(
                                viewModel.selectedLocalFile == file.name
                                    ? Color.accentColor.opacity(0.3)
                                    : (index % 2 == 0 ? Color.white : Color.gray.opacity(0.1))
                            )
                    )
                    .listRowSeparator(.hidden)
                    .onTapGesture {
                        viewModel.selectLocalFile(file.name)
                    }
                    .onTapGesture(count: 2) {
                        if file.isDirectory {
                            viewModel.openDirectory(file)
                        }
                    }
            }
            .listStyle(.plain)
            .background(Color.white)
        }
    }
}

struct RemoteFilesView: View {
    @ObservedObject var viewModel: MainViewModel
    @State private var isDropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header with navigation
            HStack {
                // Navigation buttons
                if viewModel.isConnected {
                    HStack(spacing: 2) {
                        Button(action: viewModel.navigateBack) {
                            Image(systemName: "chevron.left")
                        }
                        .help("Go Back")
                        .disabled(!viewModel.canGoBack)
                        .buttonStyle(.borderless)

                        Button(action: viewModel.navigateForward) {
                            Image(systemName: "chevron.right")
                        }
                        .help("Go Forward")
                        .disabled(!viewModel.canGoForward)
                        .buttonStyle(.borderless)
                    }
                    .controlSize(.regular)
                }

                Text("Device Files")
                    .font(.headline)
                Spacer()
                if viewModel.isConnected {
                    Button("Refresh") {
                        Task {
                            await viewModel.refreshRemoteFiles()
                        }
                    }
                }
            }
            .padding()

            Divider()

            if viewModel.isConnected {
                // File list with drag and drop
                List(Array(viewModel.remoteFiles.enumerated()), id: \.element.name) { index, file in
                    RemoteFileRow(file: file, viewModel: viewModel)
                        .listRowBackground(
                            RoundedRectangle(cornerRadius: 0)
                                .fill(
                                    viewModel.selectedRemoteFile == file.name
                                        ? Color.accentColor.opacity(0.3)
                                        : (index % 2 == 0 ? Color.white : Color.gray.opacity(0.1))
                                )
                        )
                        .listRowSeparator(.hidden)
                        .onTapGesture {
                            viewModel.selectRemoteFile(file.name)
                        }
                        .onTapGesture(count: 2) {
                            if file.isDirectory {
                                viewModel.openRemoteDirectory(file)
                            }
                        }
                }
                .listStyle(.plain)
                .background(isDropTargeted ? Color.accentColor.opacity(0.1) : Color.white)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isDropTargeted ? Color.accentColor : Color.clear, lineWidth: 2)
                        .padding(4)
                )
                .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                    handleDroppedFiles(providers)
                }
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "externaldrive.badge.wifi")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)

                    Text("Not Connected")
                        .font(.title2)
                        .fontWeight(.medium)

                    Text("Connect to QUsb2Snes to browse device files")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    Button("Connect") {
                        viewModel.connect()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func handleDroppedFiles(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier("public.file-url") {
                provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, error in
                    guard let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) else {
                        return
                    }

                    // Create LocalFileItem from dropped file
                    Task { @MainActor in
                        let resourceValues = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                        let isDirectory = resourceValues?.isDirectory ?? false
                        let fileSize = resourceValues?.fileSize ?? 0

                        // Only handle files, not directories
                        if !isDirectory {
                            let fileItem = LocalFileItem(
                                name: url.lastPathComponent,
                                path: url.path,
                                size: Int64(fileSize),
                                isDirectory: false
                            )

                            viewModel.uploadFile(fileItem)
                        }
                    }
                }
            }
        }
        return true
    }
}

struct LocalFileRow: View {
    let file: LocalFileItem
    @ObservedObject var viewModel: MainViewModel

    var body: some View {
        HStack {
            Image(systemName: file.isDirectory ? "folder.fill" : "doc")
                .foregroundStyle(file.isDirectory ? .blue : .primary)

            Text(file.name)
                .lineLimit(1)
            
            Spacer()
            
            if !file.isDirectory && viewModel.isConnected {
                Button("Upload") {
                    viewModel.uploadFile(file)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .contextMenu {
            if file.isDirectory {
                Button("Open") {
                    viewModel.openDirectory(file)
                }
            } else {
                Button("Upload to Device") {
                    viewModel.uploadFile(file)
                }
                .disabled(!viewModel.isConnected)
                
                Divider()
                
                Button("Show in Finder") {
                    viewModel.showInFinder(file)
                }
            }
        }
    }
}

struct RemoteFileRow: View {
    let file: RemoteFileItem
    @ObservedObject var viewModel: MainViewModel

    var body: some View {
        HStack {
            Image(systemName: file.isDirectory ? "folder.fill" : "doc")
                .foregroundStyle(file.isDirectory ? .blue : .primary)

            Text(file.name)
                .lineLimit(1)
            
            Spacer()
            
            if !file.isDirectory && file.isRomFile {
                Button("Boot") {
                    viewModel.bootRom(file)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .contextMenu {
            if file.isDirectory {
                Button("Open") {
                    viewModel.openRemoteDirectory(file)
                }
            } else {
                if file.isRomFile {
                    Button("Boot ROM") {
                        viewModel.bootRom(file)
                    }
                    
                    Divider()
                }
                
                Button("Download") {
                    viewModel.downloadFile(file)
                }
                
                Divider()
                
                Button("Delete", role: .destructive) {
                    viewModel.deleteRemoteFile(file)
                }
            }
        }
    }
}

#Preview {
    ContentView()
}

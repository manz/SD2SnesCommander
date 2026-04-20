import SwiftUI
import AppKit
import UniformTypeIdentifiers
import SD2snesCommanderCore

struct RemoteFilesView: View {
    let viewModel: MainViewModel
    @State private var isDropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
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
                List(Array(viewModel.remoteFiles.enumerated()), id: \.element.name) { index, file in
                    RemoteFileRow(file: file, viewModel: viewModel)
                        .contentShape(Rectangle())
                        .listRowBackground(
                            RoundedRectangle(cornerRadius: 0)
                                .fill(
                                    viewModel.selectedRemoteFile == file.name
                                        ? Color.accentColor.opacity(0.3)
                                        : (index % 2 == 0 ? Color(NSColor.controlBackgroundColor) : Color(NSColor.alternatingContentBackgroundColors[1]))
                                )
                        )
                        .listRowSeparator(.hidden)
                        .onTapGesture(count: 2) {
                            if file.isDirectory {
                                viewModel.openRemoteDirectory(file)
                            }
                        }
                        .onTapGesture {
                            viewModel.selectRemoteFile(file.name)
                        }
                }
                .listStyle(.plain)
                .background(isDropTargeted ? Color.accentColor.opacity(0.1) : Color(NSColor.controlBackgroundColor))
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
                provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                    guard let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) else {
                        return
                    }

                    Task { @MainActor in
                        let resourceValues = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                        let isDirectory = resourceValues?.isDirectory ?? false
                        let fileSize = resourceValues?.fileSize ?? 0

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

struct RemoteFileRow: View {
    let file: RemoteFileItem
    let viewModel: MainViewModel

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

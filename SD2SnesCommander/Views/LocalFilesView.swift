import SwiftUI
import AppKit
import SD2snesCommanderCore

struct LocalFilesView: View {
    let viewModel: MainViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
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

            List(Array(viewModel.localFiles.enumerated()), id: \.element.path) { index, file in
                LocalFileRow(file: file, viewModel: viewModel)
                    .contentShape(Rectangle())
                    .listRowBackground(
                        RoundedRectangle(cornerRadius: 0)
                            .fill(
                                viewModel.selectedLocalFile == file.name
                                    ? Color.accentColor.opacity(0.3)
                                    : (index % 2 == 0 ? Color(NSColor.controlBackgroundColor) : Color(NSColor.alternatingContentBackgroundColors[1]))
                            )
                    )
                    .listRowSeparator(.hidden)
                    .onTapGesture(count: 2) {
                        if file.isDirectory {
                            viewModel.openDirectory(file)
                        }
                    }
                    .onTapGesture {
                        viewModel.selectLocalFile(file.name)
                    }
            }
            .listStyle(.plain)
            .background(Color(NSColor.controlBackgroundColor))
        }
    }
}

struct LocalFileRow: View {
    let file: LocalFileItem
    let viewModel: MainViewModel

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

import SwiftUI
import Foundation
import AppKit
import Observation
import SD2snesCommanderCore

@MainActor
@Observable
class MainViewModel {
    var isConnected = false
    var connectionStatus = "Disconnected"
    var isConnecting = false
    var deviceName: String = "SD2Snes Commander"

    var localFiles: [LocalFileItem] = []
    var remoteFiles: [RemoteFileItem] = []
    var currentLocalPath = ""
    var currentRemotePath = ""
    var remoteBreadcrumbs: [String] = []

    var remoteNavigationHistory: [String] = []
    var remoteHistoryIndex: Int = -1
    var canGoBack: Bool = false
    var canGoForward: Bool = false

    var selectedLocalFile: String? = nil
    var selectedRemoteFile: String? = nil

    var isTransferInProgress = false
    var transferProgress: Double = 0.0
    var transferStatus = ""

    @ObservationIgnored let usbClient = SD2SnesUSBClient()
    @ObservationIgnored let fileManager = LocalFileManager()
    @ObservationIgnored var transferTask: Task<Void, Never>?

    init() {}

    func initialize() {
        loadInitialLocalFiles()
    }

    // MARK: - Selection

    func selectLocalFile(_ fileName: String) { selectedLocalFile = fileName }
    func selectRemoteFile(_ fileName: String) { selectedRemoteFile = fileName }
    func clearLocalSelection() { selectedLocalFile = nil }
    func clearRemoteSelection() { selectedRemoteFile = nil }
}

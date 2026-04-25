import SwiftUI
import Foundation
import AppKit
import Observation
import SD2snesCommanderCore

@MainActor
@Observable
final class MainViewModel {
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

    var isGaming = false
    var currentRomName: String?

    // Sticky flag set when the user asks the device to return to menu.
    // Stays set until INFO confirms the menu binary is back, so a stale
    // INFO response from the FPGA-reload window cannot bounce isGaming
    // back to true and flicker the UI.
    @ObservationIgnored var awaitingMenu = false

    @ObservationIgnored let usbClient = SD2SnesUSBClient.shared
    @ObservationIgnored let fileManager = LocalFileManager()
    @ObservationIgnored var transferTask: Task<Void, Never>?
    @ObservationIgnored var infoPollTask: Task<Void, Never>?

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

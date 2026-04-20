import Foundation

@MainActor
extension MainViewModel {
    func addToNavigationHistory(_ path: String) {
        if remoteHistoryIndex < remoteNavigationHistory.count - 1 {
            remoteNavigationHistory.removeSubrange((remoteHistoryIndex + 1)...)
        }

        if remoteNavigationHistory.last != path {
            remoteNavigationHistory.append(path)
            remoteHistoryIndex = remoteNavigationHistory.count - 1
        }

        updateNavigationButtons()
    }

    func updateNavigationButtons() {
        canGoBack = remoteHistoryIndex > 0
        canGoForward = remoteHistoryIndex < remoteNavigationHistory.count - 1
    }

    func navigateBack() {
        guard canGoBack else { return }

        remoteHistoryIndex -= 1
        let targetPath = remoteNavigationHistory[remoteHistoryIndex]

        Task {
            await navigateToPath(targetPath, addToHistory: false)
        }
    }

    func navigateForward() {
        guard canGoForward else { return }

        remoteHistoryIndex += 1
        let targetPath = remoteNavigationHistory[remoteHistoryIndex]

        Task {
            await navigateToPath(targetPath, addToHistory: false)
        }
    }

    func navigateToPath(_ path: String, addToHistory: Bool = true) async {
        currentRemotePath = path
        remoteBreadcrumbs = path.isEmpty ? [] : path.components(separatedBy: "/")
        clearRemoteSelection()

        if addToHistory {
            addToNavigationHistory(path)
        } else {
            updateNavigationButtons()
        }

        await refreshRemoteFiles()
    }
}

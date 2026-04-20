import SwiftUI
import Observation

@MainActor
@Observable
class AppState {
    static let shared = AppState()

    let mainViewModel: MainViewModel

    private init() {
        mainViewModel = MainViewModel()
    }
}

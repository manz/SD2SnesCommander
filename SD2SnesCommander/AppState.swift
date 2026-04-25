import SwiftUI
import Observation

@MainActor
@Observable
final class AppState {
    static let shared = AppState()

    let mainViewModel: MainViewModel

    private init() {
        mainViewModel = MainViewModel()
    }
}

import SwiftUI
import Combine

class AppState: ObservableObject {
    static let shared = AppState()

    @Published var mainViewModel: MainViewModel

    private init() {
        mainViewModel = MainViewModel()
    }
}
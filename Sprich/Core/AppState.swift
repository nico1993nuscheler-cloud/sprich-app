import Foundation
import Combine

enum AppStatus: Equatable {
    case ready
    case recording(TranscriptionMode)
    case processing
    case error(String)

    static func == (lhs: AppStatus, rhs: AppStatus) -> Bool {
        switch (lhs, rhs) {
        case (.ready, .ready), (.processing, .processing):
            return true
        case (.recording(let a), .recording(let b)):
            return a == b
        case (.error(let a), .error(let b)):
            return a == b
        default:
            return false
        }
    }
}

@MainActor
class AppState: ObservableObject {
    @Published var status: AppStatus = .ready
    @Published var settings: AppSettings

    var cancellables = Set<AnyCancellable>()

    private static let settingsKey = "SprichSettings"

    init() {
        if let data = UserDefaults.standard.data(forKey: AppState.settingsKey),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            self.settings = decoded
        } else {
            self.settings = AppSettings.defaults
        }
    }

    func saveSettings() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: AppState.settingsKey)
        }
    }
}

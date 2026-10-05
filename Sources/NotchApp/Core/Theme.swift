import SwiftUI

enum AppTheme: String, CaseIterable, Identifiable {
    case minimal = "Minimal"
    case playful = "Playful"
    case neon = "Neon"
    var id: String { rawValue }
}

final class ThemeManager: ObservableObject {
    static let shared = ThemeManager()
    @Published var current: AppTheme = .minimal {
        didSet { UserDefaults.standard.set(current.rawValue, forKey: "theme") }
    }
    init() {
        if let s = UserDefaults.standard.string(forKey: "theme"),
           let t = AppTheme(rawValue: s) { current = t }
    }

    var background: Color {
        switch current {
        case .minimal: return Color.black
        case .playful: return Color(red: 0.12, green: 0.12, blue: 0.18)
        case .neon: return Color(red: 0.05, green: 0.05, blue: 0.08)
        }
    }
    var accent: Color {
        switch current {
        case .minimal: return .white
        case .playful: return Color(red: 0.4, green: 0.7, blue: 1.0)
        case .neon: return Color(red: 0.2, green: 1.0, blue: 0.7)
        }
    }
}

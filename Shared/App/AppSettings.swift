import Observation
import SwiftUI

/// In the pickers, « Système » comes first, as everywhere in macOS and iOS; dark stays the default.
enum ThemeChoice: String, CaseIterable, Identifiable {
    case system, dark, light
    var id: String { rawValue }
    var label: String {
        switch self {
        case .dark: "Sombre"
        case .light: "Clair"
        case .system: "Système"
        }
    }
}

/// User preferences, persisted in UserDefaults. Same keys and defaults as Void and Void Notes for
/// what they share (theme, accent, tint of the window), but in Void Mail's own domain.
@MainActor @Observable
final class AppSettings {
    static let shared = AppSettings()
    @ObservationIgnored private let defaults = AppSettings.store

    var theme: ThemeChoice { didSet { defaults.set(theme.rawValue, forKey: "theme"); applyAppearance() } }
    var accent: AccentChoice { didSet { defaults.set(accent.rawValue, forKey: "accent") } }
    /// Tint of the window's frame (see ChromeTint.swift).
    var chromeTint: ChromeTint {
        didSet {
            defaults.set(chromeTint.rawValue, forKey: "chromeTint")
            Theme.isTinted = chromeTint != .none
        }
    }
    var chromeTintIntensity: Double { didSet { defaults.set(chromeTintIntensity, forKey: "chromeTintIntensity") } }
    var chromeTintGradient: Bool { didSet { defaults.set(chromeTintGradient, forKey: "chromeTintGradient") } }
    /// The mailboxes on the left of the window.
    var showsSidebar: Bool { didSet { defaults.set(showsSidebar, forKey: "showsSidebar") } }
    /// Misspelled words underlined in red as one writes.
    var checksSpelling: Bool { didSet { defaults.set(checksSpelling, forKey: "checksSpelling") } }
    /// Grammar mistakes underlined in blue (when macOS checks grammar for apps).
    var checksGrammar: Bool { didSet { defaults.set(checksGrammar, forKey: "checksGrammar") } }
    /// Account shown when the app was last used.
    var currentAccount: String? { didSet { defaults.set(currentAccount, forKey: "currentAccount") } }

    /// Debug launches keep their preferences apart from the real ones.
    private static var store: UserDefaults {
        #if DEBUG
        if DebugLaunch.isRequested { return UserDefaults(suiteName: "app.void.mail.debug")! }
        #endif
        return .standard
    }

    private init() {
        let d = AppSettings.store
        theme = ThemeChoice(rawValue: d.string(forKey: "theme") ?? "") ?? .dark
        accent = AccentChoice(rawValue: d.string(forKey: "accent") ?? "") ?? .violet
        chromeTint = ChromeTint(rawValue: d.string(forKey: "chromeTint") ?? "") ?? .none
        chromeTintIntensity = d.object(forKey: "chromeTintIntensity") as? Double ?? ChromeLook.amountRange.upperBound
        chromeTintGradient = d.object(forKey: "chromeTintGradient") as? Bool ?? true
        showsSidebar = d.object(forKey: "showsSidebar") as? Bool ?? true
        currentAccount = d.string(forKey: "currentAccount")
        checksSpelling = d.object(forKey: "checksSpelling") as? Bool ?? true
        checksGrammar = d.object(forKey: "checksGrammar") as? Bool ?? true
        #if DEBUG
        // `-theme light -accent pink -tint lavender -tintAmount 0.12 -tintGradient NO`, as in Void Notes.
        if DebugLaunch.isRequested {
            let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
            theme = (arguments["theme"] as? String).flatMap(ThemeChoice.init) ?? .dark
            accent = (arguments["accent"] as? String).flatMap(AccentChoice.init) ?? .violet
            chromeTint = (arguments["tint"] as? String).flatMap(ChromeTint.init) ?? .none
            chromeTintIntensity = (arguments["tintAmount"] as? String).flatMap(Double.init) ?? ChromeLook.amountRange.upperBound
            chromeTintGradient = (arguments["tintGradient"] as? String).map { $0 != "NO" } ?? true
            showsSidebar = true
            currentAccount = nil
        }
        #endif
        Theme.isTinted = chromeTint != .none
    }

    var chromeLook: ChromeLook {
        let range = ChromeLook.amountRange
        return ChromeLook(tint: chromeTint,
                          amount: min(range.upperBound, max(range.lowerBound, chromeTintIntensity)), gradient: chromeTintGradient)
    }

    func applyAppearance() {
        #if os(macOS)
        switch theme {
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .system: NSApp.appearance = nil
        }
        #endif
    }

    /// The same choice for SwiftUI (`preferredColorScheme`): nil follows the system.
    var colorScheme: ColorScheme? {
        switch theme {
        case .dark: .dark
        case .light: .light
        case .system: nil
        }
    }
}

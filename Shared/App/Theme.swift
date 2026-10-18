import SwiftUI
#if canImport(AppKit)
import AppKit
typealias PlatformColor = NSColor
typealias PlatformFont = NSFont
#else
import UIKit
typealias PlatformColor = UIColor
typealias PlatformFont = UIFont
#endif

/// The five accent colors offered in Réglages → Couleur — the same pastel tones as Void (OKLCH:
/// lightness 0.74 and chroma 0.095 for the light theme, 0.80 and about 0.09 for the dark one).
/// A deliberate choice of softness over contrast in the light theme: there an accent text or
/// icon reaches only about 2:1; in the dark theme, at least 8:1. Labels on an accent fill
/// (primary buttons, checked boxes) are dark (`Theme.onAccent`, at least 7.5:1), never white.
enum AccentChoice: String, CaseIterable, Identifiable {
    case violet, blue, green, orange, pink
    var id: String { rawValue }

    var label: String {
        switch self {
        case .violet: "Violet"
        case .blue: "Bleu"
        case .green: "Vert"
        case .orange: "Orange"
        case .pink: "Rose"
        }
    }

    /// Text / icon tone on light backgrounds; also the fill of primary buttons (dark label).
    var lightHex: UInt32 {
        switch self {
        case .violet: 0xA7A2E4
        case .blue: 0x84ADE7
        case .green: 0x7BBC8E
        case .orange: 0xD89C6D
        case .pink: 0xDB92AE
        }
    }

    /// Text / icon tone on dark backgrounds.
    var darkHex: UInt32 {
        switch self {
        case .violet: 0xBAB5F4
        case .blue: 0x9EC0F0
        case .green: 0x91CFA3
        case .orange: 0xE7B188
        case .pink: 0xEEA5C1
        }
    }

    /// Deep tone, behind the white labels the system draws itself (the swipe actions on
    /// iPhone): white reaches at least 5.5:1 on it.
    var deepHex: UInt32 {
        switch self {
        case .violet: 0x5B4BE0
        case .blue: 0x1F5FD1
        case .green: 0x12703A
        case .orange: 0xA84400
        case .pink: 0xC21F68
        }
    }
}

/// Void Mail's palette — the only place where colors are defined (Void's; the frame's tints are
/// computed in ChromeTint.swift). Every color adapts to the current appearance (dark by default);
/// the accent follows Réglages → Couleur and the frame Réglages → Teinte, live.
/// The `…NS` colors are the same ones for the message's text views: `NSColor` on the Mac,
/// `UIColor` on iPhone.
enum Theme {
    /// The window's frame (list, toolbar, around the message), flat: neutral or tinted.
    @MainActor static var chrome: Color { Color(platform: chromeNS) }
    /// A tinted frame over the blurred desktop (Mac): lightly translucent.
    static let translucentChromeOpacity = 0.82
    /// The surface the message is read and written on, flat: white or dark grey, or with a tint, the frame
    /// lifted. Behind the message itself, `MessageSurface` shows the frame through.
    @MainActor static var surface: Color { Color(platform: surfaceNS) }
    /// Over a tinted frame, what makes the message's sheet.
    static let surfaceLift = dynamic(light: PlatformColor(white: 1, alpha: ChromeLook.lift.light), dark: PlatformColor(white: 1, alpha: ChromeLook.lift.dark))
    static let hover = dynamic(light: PlatformColor(white: 0, alpha: 0.05), dark: PlatformColor(white: 1, alpha: 0.055))
    static let stroke = dynamic(light: PlatformColor(white: 0, alpha: 0.08), dark: PlatformColor(white: 1, alpha: 0.08))
    static let primaryText = Color(platform: primaryTextNS)
    /// Cool grey on the neutral frame and surface; warm grey, lighter in the dark theme, on tinted
    /// ones (their warm bases and up to 20 % of color): at least 4.5:1 on both in every case.
    @MainActor static var secondaryText: Color { Color(platform: secondaryTextNS) }
    static let danger = dynamic(light: PlatformColor(hex: 0xC4262E), dark: PlatformColor(hex: 0xFF6B6B))
    /// Solid red behind white text (a destructive swipe action) — same tone in both themes, as
    /// `accentDeepFill`: white reaches 5.6:1 on it.
    static let dangerFill = Color(platform: PlatformColor(hex: 0xC4262E))
    static let switchOff = dynamic(light: PlatformColor(white: 0, alpha: 0.14), dark: PlatformColor(white: 1, alpha: 0.18))
    static let switchKnob = Color.white
    static let shadow = Color.black

    /// Window background behind the chrome (AppKit / UIKit side of `chrome`).
    @MainActor static var chromeNS: PlatformColor { AppSettings.shared.chromeLook.color }
    /// AppKit / UIKit side of `surface`.
    @MainActor static var surfaceNS: PlatformColor { AppSettings.shared.chromeLook.surfaceColor }
    static let primaryTextNS = dynamicNS(light: PlatformColor(hex: 0x131316), dark: PlatformColor(hex: 0xECECF1))
    /// AppKit / UIKit side of `secondaryText`. Formatted text takes it: an
    /// editor is made anew when the frame goes from neutral to tinted or back.
    static var secondaryTextNS: PlatformColor { isTinted ? secondaryTextWarmNS : secondaryTextCoolNS }
    /// A tint is chosen (Réglages → Teinte), mirrored by `AppSettings` for `NoteFormat`, which
    /// formats on the main thread without being bound to it.
    nonisolated(unsafe) static var isTinted = false
    static let secondaryTextCoolNS = dynamicNS(light: PlatformColor(hex: 0x62626B), dark: PlatformColor(hex: 0x8B8B96))
    static let secondaryTextWarmNS = dynamicNS(light: PlatformColor(hex: 0x5E5A55), dark: PlatformColor(hex: 0xBCB7B0))

    /// Highlighted text: one yellow, drawn as a marker's band under the lower half of the letters
    /// (`MarkerLayoutManager`). See-through so the text keeps its color; brighter on the dark
    /// surface, where a faint yellow turns olive.
    static let highlightNS = dynamicNS(light: PlatformColor(hex: 0xFFD60A, alpha: 0.6), dark: PlatformColor(hex: 0xFFD60A, alpha: 0.48))
    static let highlight = Color(platform: highlightNS)
    /// Behind inline code, and behind what the search found in the message.
    static let codeBackgroundNS = dynamicNS(light: PlatformColor(white: 0, alpha: 0.06), dark: PlatformColor(white: 1, alpha: 0.09))
    /// The line of a divider.
    static let dividerNS = dynamicNS(light: PlatformColor(white: 0, alpha: 0.16), dark: PlatformColor(white: 1, alpha: 0.18))

    // MARK: Accent

    private struct AccentPalette {
        let accentNS: PlatformColor, softNS: PlatformColor
        let accent: Color, fill: Color, soft: Color
    }

    private static let palettes: [AccentChoice: AccentPalette] = Dictionary(uniqueKeysWithValues: AccentChoice.allCases.map { choice in
        let accent = dynamicNS(light: PlatformColor(hex: choice.lightHex), dark: PlatformColor(hex: choice.darkHex))
        let soft = dynamicNS(light: PlatformColor(hex: choice.lightHex, alpha: 0.28), dark: PlatformColor(hex: choice.darkHex, alpha: 0.2))
        return (choice, AccentPalette(accentNS: accent, softNS: soft, accent: Color(platform: accent),
                                      fill: Color(platform: PlatformColor(hex: choice.lightHex)), soft: Color(platform: soft)))
    })

    /// Icons, active controls, insertion point, quote bars, switches, focus rings.
    @MainActor static var accent: Color { palettes[AppSettings.shared.accent]!.accent }
    /// Solid fill behind `onAccent` text (primary buttons) — same tone in both themes.
    @MainActor static var accentFill: Color { palettes[AppSettings.shared.accent]!.fill }
    /// Behind the white labels drawn by the system (swipe actions): the deep tone of the accent.
    @MainActor static var accentDeepFill: Color { Color(platform: PlatformColor(hex: AppSettings.shared.accent.deepHex)) }
    /// Text and symbols on `accentFill` / `accent` fills: dark, the pastel tones being light.
    static let onAccentNS = PlatformColor(hex: 0x131316)
    static let onAccent = Color(platform: onAccentNS)
    /// Tinted background: selected message in the list, selected text.
    @MainActor static var accentSoft: Color { palettes[AppSettings.shared.accent]!.soft }

    static func accentNS(_ choice: AccentChoice) -> PlatformColor { palettes[choice]!.accentNS }
    static func accentSoftNS(_ choice: AccentChoice) -> PlatformColor { palettes[choice]!.softNS }
    static func swatch(_ choice: AccentChoice) -> Color { palettes[choice]!.accent }

    // MARK: Logo (brand colors, fixed)

    static let logoGradient = [PlatformColor(hex: 0xF4F1FF), PlatformColor(hex: 0x9D8FFF), PlatformColor(hex: 0x4B3FD0)].map { Color(platform: $0) }
    static let logoGlow = Color(platform: PlatformColor(hex: 0x9D8FFF, alpha: 0.55))
    static let logoCore = Color(platform: PlatformColor(hex: 0x07070A))

    static let spring: Animation = .spring(response: 0.32, dampingFraction: 0.86)
    static let quickDuration: Double = 0.16
    static let quick: Animation = .easeOut(duration: quickDuration)

    static func dynamicNS(light: PlatformColor, dark: PlatformColor) -> PlatformColor {
        #if canImport(AppKit)
        PlatformColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
        #else
        PlatformColor { $0.userInterfaceStyle == .dark ? dark : light }
        #endif
    }

    static func dynamic(light: PlatformColor, dark: PlatformColor) -> Color {
        Color(platform: dynamicNS(light: light, dark: dark))
    }
}

extension PlatformColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        let red = CGFloat((hex >> 16) & 0xFF) / 255, green = CGFloat((hex >> 8) & 0xFF) / 255, blue = CGFloat(hex & 0xFF) / 255
        #if canImport(AppKit)
        self.init(srgbRed: red, green: green, blue: blue, alpha: alpha)
        #else
        self.init(red: red, green: green, blue: blue, alpha: alpha)
        #endif
    }
}

extension Color {
    init(platform color: PlatformColor) {
        #if canImport(AppKit)
        self.init(nsColor: color)
        #else
        self.init(uiColor: color)
        #endif
    }
}

/// The Void mark: a dark disc eclipsing a luminous ring.
struct VoidLogo: View {
    var size: CGFloat = 64
    var body: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(colors: Theme.logoGradient, startPoint: .bottomLeading, endPoint: .topTrailing))
                .shadow(color: Theme.logoGlow, radius: size * 0.12)
            Circle()
                .fill(Theme.logoCore)
                .frame(width: size * 0.86, height: size * 0.86)
                .offset(x: size * 0.045, y: -size * 0.045)
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Void Mail")
    }
}

/// Small icon-only button used throughout the chrome.
struct ChromeButton: View {
    let symbol: String
    var help: String = ""
    var active: Bool = false
    var disabled: Bool = false
    var size: CGFloat = 13
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(active ? Theme.accent : Theme.secondaryText)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7).fill(hovering && !disabled ? Theme.hover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
        .help(help)
        .accessibilityLabel(help)
        .onHover { hovering = $0 }
        .animation(Theme.quick, value: hovering)
    }
}

extension View {
    /// The main button of a dialog: the accent's fill, with a dark label.
    func primaryButton() -> some View { buttonStyle(PrimaryButtonStyle()) }
}

/// The system's prominent button draws a white label, unreadable on the pastel accents.
private struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    #if os(macOS)
    private static let height: CGFloat = 22, padding: CGFloat = 10, radius: CGFloat = 6
    #else
    private static let height: CGFloat = 36, padding: CGFloat = 16, radius: CGFloat = 10
    #endif

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .fontWeight(.medium)
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, Self.padding)
            .frame(minHeight: Self.height)
            .background(RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                .fill(Theme.accentFill)
                .brightness(configuration.isPressed ? -0.08 : 0))
            .contentShape(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
            .opacity(isEnabled ? 1 : 0.45)
    }
}

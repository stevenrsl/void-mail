import SwiftUI

/// The tint of the window's frame (list of messages, toolbar, margin around the message), offered in
/// Réglages → Apparence → Teinte — the same as Void: neutral, or one of eight pastel hues around
/// the color wheel. Those complementary to the accent color (Réglages → Couleur) are pointed out.
enum ChromeTint: String, CaseIterable, Identifiable {
    case none, rose, peach, lemon, sage, mint, sky, lavender, mauve
    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: "Neutre"
        case .rose: "Rose"
        case .peach: "Pêche"
        case .lemon: "Citron"
        case .sage: "Sauge"
        case .mint: "Menthe"
        case .sky: "Ciel"
        case .lavender: "Lavande"
        case .mauve: "Mauve"
        }
    }

    /// OKLCH hue, in degrees; nil for the neutral frame.
    var hue: Double? {
        switch self {
        case .none: nil
        case .rose: 0
        case .peach: 55
        case .lemon: 95
        case .sage: 150
        case .mint: 185
        case .sky: 235
        case .lavender: 285
        case .mauve: 330
        }
    }

    static let palette = allCases.filter { $0 != .none }

    /// Within 30° of the hue opposite to the accent's.
    func isComplementary(to accent: AccentChoice) -> Bool {
        guard let hue else { return false }
        let opposite = OKLCH.hue(hex: accent.darkHex) + 180
        let distance = abs((hue - opposite).truncatingRemainder(dividingBy: 360))
        return min(distance, 360 - distance) <= 30
    }
}

/// What the frame looks like, as chosen in Réglages: a little of a pastel color (at most 20 %)
/// mixed into a softly warm base, cream in the light theme and dark brown in the dark one; with
/// the gradient, two soft glows, the tint's and its complement's, as on Firn's site. The neutral
/// frame keeps Void's cool grey. The message is the frame itself, a little lighter (`Theme.surfaceLift`):
/// the same as the list of messages, gradient and blurred desktop included (`MessageSurface`).
struct ChromeLook: Equatable {
    var tint: ChromeTint
    /// Share of the pastel color in the frame.
    var amount: Double
    var gradient: Bool

    static let amountRange: ClosedRange<Double> = 0.04...0.20
    /// Under the glows, the frame has less of the color.
    static let gradientBase = 0.4
    /// Pastel tones of a hue, in OKLCH (lightness, chroma) per appearance: a little lighter and
    /// brighter than the accents.
    private static let pastel = (light: (0.81, 0.105), dark: (0.83, 0.09))
    static let neutral: (light: UInt32, dark: UInt32) = (0xE9E9EE, 0x0B0B0E)
    static let warm: (light: UInt32, dark: UInt32) = (0xF0EAE2, 0x110D0A)
    static let neutralSurface: (light: UInt32, dark: UInt32) = (0xFFFFFF, 0x17171C)
    /// White over the frame, on the message: enough to tell the sheet from its frame.
    static let lift = (light: 0.4, dark: 0.05)

    /// Flat color of the frame.
    var color: PlatformColor { tone(hue: tint.hue, amount: amount) }

    /// The frame with `amount` of the pastel of `hue` (nil: neutral), both appearances.
    func tone(hue: Double?, amount: Double) -> PlatformColor {
        guard let hue else {
            return Theme.dynamicNS(light: PlatformColor(hex: Self.neutral.light), dark: PlatformColor(hex: Self.neutral.dark))
        }
        return Theme.dynamicNS(light: PlatformColor(hex: Self.mix(Self.warm.light, Self.pastel(hue, dark: false), amount)),
                               dark: PlatformColor(hex: Self.mix(Self.warm.dark, Self.pastel(hue, dark: true), amount)))
    }

    /// The message's surface, flat (popovers).
    var surfaceColor: PlatformColor { surfaceTone(hue: tint.hue, amount: amount) }

    /// The flat message's surface for a frame with `amount` of the pastel of `hue` (nil: neutral):
    /// the frame, lifted.
    func surfaceTone(hue: Double?, amount: Double) -> PlatformColor {
        guard let hue else {
            return Theme.dynamicNS(light: PlatformColor(hex: Self.neutralSurface.light), dark: PlatformColor(hex: Self.neutralSurface.dark))
        }
        return Theme.dynamicNS(light: PlatformColor(hex: Self.mix(Self.mix(Self.warm.light, Self.pastel(hue, dark: false), amount), 0xFFFFFF, Self.lift.light)),
                               dark: PlatformColor(hex: Self.mix(Self.mix(Self.warm.dark, Self.pastel(hue, dark: true), amount), 0xFFFFFF, Self.lift.dark)))
    }

    static func pastel(_ hue: Double, dark: Bool) -> UInt32 {
        let (lightness, chroma) = dark ? pastel.dark : pastel.light
        return OKLCH.hex(lightness, chroma * cos(hue * .pi / 180), chroma * sin(hue * .pi / 180))
    }

    /// `amount` of `color` over `base`, channel by channel (sRGB).
    static func mix(_ base: UInt32, _ color: UInt32, _ amount: Double) -> UInt32 {
        [16, 8, 0].reduce(0) { hex, shift in
            let from = Double((base >> UInt32(shift)) & 0xFF), to = Double((color >> UInt32(shift)) & 0xFF)
            return hex | UInt32((from + (to - from) * amount).rounded()) << UInt32(shift)
        }
    }
}

/// sRGB ↔ Oklab (Björn Ottosson), out-of-gamut values clamped.
enum OKLCH {
    static func lab(_ hex: UInt32) -> (Double, Double, Double) {
        func decode(_ shift: UInt32) -> Double {
            let v = Double((hex >> shift) & 0xFF) / 255
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        let (r, g, b) = (decode(16), decode(8), decode(0))
        let l = cbrt(0.4122214708 * r + 0.5363015620 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }

    static func hex(_ lightness: Double, _ a: Double, _ b: Double) -> UInt32 {
        let l = pow(lightness + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m = pow(lightness - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s = pow(lightness - 0.0894841775 * a - 1.2914855480 * b, 3)
        let red = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
        let green = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
        let blue = -0.0041960863 * l - 0.7034186147 * m + 1.7076127010 * s
        func encode(_ v: Double) -> UInt32 {
            let v = min(1, max(0, v))
            return UInt32(((v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055) * 255).rounded())
        }
        return encode(red) << 16 | encode(green) << 8 | encode(blue)
    }

    /// Hue of an sRGB color, in degrees.
    static func hue(hex: UInt32) -> Double {
        let (_, a, b) = lab(hex)
        let degrees = atan2(b, a) * 180 / .pi
        return degrees < 0 ? degrees + 360 : degrees
    }
}

/// The frame's color: flat, or with the gradient, a paler base under two soft glows — the tint's
/// at the top right, its complement's at the bottom left.
struct ChromeFill: View {
    let look: ChromeLook

    var body: some View {
        if let hue = look.tint.hue, look.gradient {
            GeometryReader { geo in
                let radius = max(geo.size.width, geo.size.height) * 0.85
                ZStack {
                    Color(platform: look.tone(hue: hue, amount: look.amount * ChromeLook.gradientBase))
                    glow(hue: hue, at: UnitPoint(x: 0.95, y: 0.05), radius: radius)
                    glow(hue: hue + 180, at: UnitPoint(x: 0.0, y: 0.9), radius: radius)
                }
            }
        } else {
            Color(platform: look.color)
        }
    }

    /// The full tone at the center, fading into the paler base.
    private func glow(hue: Double, at center: UnitPoint, radius: CGFloat) -> some View {
        let tone = Color(platform: look.tone(hue: hue, amount: look.amount))
        return RadialGradient(colors: [tone, tone.opacity(0)], center: center, startRadius: 0, endRadius: radius)
    }
}

/// The window's frame: neutral, or the chosen tint. On the Mac, a tinted frame lets a little of
/// the blurred desktop through.
struct ChromeBackground: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        if settings.chromeTint == .none {
            ChromeFill(look: settings.chromeLook)
        } else {
            #if os(macOS)
            ZStack {
                BehindWindowBlur()
                ChromeFill(look: settings.chromeLook).opacity(Theme.translucentChromeOpacity)
            }
            #else
            ChromeFill(look: settings.chromeLook)
            #endif
        }
    }
}

/// Behind the message: white or dark grey; with a tint, the frame itself, a little lighter — its
/// gradient and, on the Mac, the blurred desktop: the same as the list of messages. In the main
/// window the frame is already drawn behind everything (`WindowBackdrop`): only the lift is.
struct MessageSurface: View {
    var drawsFrame = true
    @Environment(AppSettings.self) private var settings

    var body: some View {
        if settings.chromeTint == .none {
            Theme.surface
        } else if drawsFrame {
            ZStack {
                ChromeBackground()
                Theme.surfaceLift
            }
        } else {
            Theme.surfaceLift
        }
    }
}

/// Réglages → Teinte: neutral and the eight pastels; those complementary to the accent carry a
/// dot. Applies at once to every window.
struct ChromeTintPicker: View {
    @Environment(AppSettings.self) private var settings

    #if os(macOS)
    private static let side: CGFloat = 18, spacing: CGFloat = 4
    #else
    private static let side: CGFloat = 22, spacing: CGFloat = 6
    #endif

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: Self.spacing) {
                ForEach(ChromeTint.allCases) { tint in
                    swatch(tint)
                }
            }
            HStack(spacing: 4) {
                Circle().fill(Theme.accent).frame(width: 4, height: 4)
                Text("complémentaire de votre couleur").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func swatch(_ tint: ChromeTint) -> some View {
        let selected = settings.chromeTint == tint
        let complementary = tint.isComplementary(to: settings.accent)
        return Button { withAnimation(Theme.quick) { settings.chromeTint = tint } } label: {
            Group {
                if let hue = tint.hue {
                    // The pastel itself: the frame only has a little of it.
                    Circle().fill(Color(platform: PlatformColor(hex: ChromeLook.pastel(hue, dark: false))))
                } else {
                    Circle().fill(Color(platform: ChromeLook(tint: .none, amount: 0, gradient: false).color))
                        .overlay(Rectangle().fill(Theme.secondaryText.opacity(0.6)).frame(width: 1.5).rotationEffect(.degrees(45)))
                        .clipShape(Circle())
                }
            }
            .frame(width: Self.side, height: Self.side)
            .overlay(Circle().strokeBorder(Theme.stroke, lineWidth: 1))
            .padding(3)
            .overlay(Circle().strokeBorder(selected ? Theme.accent : .clear, lineWidth: 2))
            .overlay(alignment: .bottom) {
                if complementary { Circle().fill(Theme.accent).frame(width: 4, height: 4).offset(y: 6) }
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(complementary ? "\(tint.label) — complémentaire de votre couleur" : tint.label)
        .accessibilityLabel(tint.label)
        .accessibilityHint(complementary ? Text("Complémentaire de votre couleur") : Text(""))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Intensity and gradient, shown once a tint is chosen.
struct ChromeTintOptions: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        if settings.chromeTint != .none {
            LabeledContent("Intensité de la teinte") {
                HStack {
                    // Rounded to the percent without `step`, which would draw a tick per percent.
                    Slider(value: Binding { settings.chromeTintIntensity } set: { settings.chromeTintIntensity = ($0 * 100).rounded() / 100 },
                           in: ChromeLook.amountRange)
                        .accessibilityLabel("Intensité de la teinte")
                        .accessibilityValue(Text(settings.chromeTintIntensity, format: .percent.precision(.fractionLength(0))))
                    Text(settings.chromeTintIntensity, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 36, alignment: .trailing)
                }
                #if os(macOS)
                .frame(width: 200)
                #endif
            }
            Toggle("Dégradé", isOn: Bindable(settings).chromeTintGradient)
                #if os(macOS)
                .toggleStyle(.switch)
                #endif
        }
    }
}

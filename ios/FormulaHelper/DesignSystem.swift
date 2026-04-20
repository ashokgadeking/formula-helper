import SwiftUI

// MARK: - Colours (semantic tokens)

extension Color {

    // ── Backgrounds (layered: primary → secondary → elevated → overlay) ──
    static let primaryBackground  = Color(hex: "#08080f")
    static let secondaryBackground = Color(hex: "#0e0e1a")
    static let elevatedBackground  = Color(hex: "#141422")
    static let overlayBackground   = Color(hex: "#1a1a2e")

    // ── Labels ──
    static let primaryLabel    = Color(hex: "#ebebf5")
    static let secondaryLabel  = Color(hex: "#6e6e87")
    static let tertiaryLabel   = Color(hex: "#4a4a62")
    static let quaternaryLabel = Color(hex: "#ebebf5").opacity(0.18)

    // ── Fills (translucent element backgrounds) ──
    static let primaryFill   = Color.white.opacity(0.12)
    static let secondaryFill = Color.white.opacity(0.08)
    static let tertiaryFill  = Color.white.opacity(0.05)

    // ── Separators ──
    static let separator        = Color.white.opacity(0.06)
    static let opaqueSeparator  = Color.white.opacity(0.10)

    // ── Accent: Green ──
    static let green       = Color(hex: "#44d66e")
    static let greenFill   = Color(red: 68/255,  green: 210/255, blue: 110/255).opacity(0.10)
    static let greenBorder = Color(red: 68/255,  green: 210/255, blue: 110/255).opacity(0.20)

    // ── Accent: Blue ──
    static let blue       = Color(hex: "#5aaaff")
    static let blueFill   = Color(red: 90/255,  green: 170/255, blue: 255/255).opacity(0.08)
    static let blueBorder = Color(red: 90/255,  green: 170/255, blue: 255/255).opacity(0.15)

    // ── Accent: Yellow ──
    static let yellow       = Color(hex: "#ffc837")
    static let yellowFill   = Color(red: 255/255, green: 200/255, blue: 55/255).opacity(0.08)
    static let yellowBorder = Color(red: 255/255, green: 200/255, blue: 55/255).opacity(0.15)

    // ── Accent: Red ──
    static let red       = Color(hex: "#ff4b4b")
    static let redFill   = Color(red: 255/255, green: 75/255,  blue: 75/255).opacity(0.08)
    static let redBorder = Color(red: 255/255, green: 75/255,  blue: 75/255).opacity(0.15)

    // ── Accent: Purple ──
    static let purple       = Color(hex: "#b478ff")
    static let purpleFill   = Color(red: 180/255, green: 120/255, blue: 255/255).opacity(0.08)
    static let purpleBorder = Color(red: 180/255, green: 120/255, blue: 255/255).opacity(0.15)

    init(hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: h).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255
        let g = Double((int >> 8)  & 0xFF) / 255
        let b = Double(int         & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

// MARK: - Typography

// Outfit variable font helper (fixed size, use for display/hero text)
extension Font {
    static func outfit(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        return .custom("Outfit", size: size).weight(weight)
    }
}

// Dynamic Type-aware text styles using Outfit
enum AppTextStyle {
    case largeTitle    // 34pt bold
    case title1        // 28pt bold
    case title2        // 22pt bold
    case title3        // 20pt semibold
    case headline      // 17pt semibold
    case body          // 17pt regular
    case callout       // 16pt regular
    case subheadline   // 15pt regular
    case footnote      // 13pt regular
    case caption1      // 12pt regular
    case caption2      // 11pt medium

    var font: Font {
        switch self {
        case .largeTitle:   return .custom("Outfit", size: 34, relativeTo: .largeTitle).bold()
        case .title1:       return .custom("Outfit", size: 28, relativeTo: .title).bold()
        case .title2:       return .custom("Outfit", size: 22, relativeTo: .title2).bold()
        case .title3:       return .custom("Outfit", size: 20, relativeTo: .title3).weight(.semibold)
        case .headline:     return .custom("Outfit", size: 17, relativeTo: .headline).weight(.semibold)
        case .body:         return .custom("Outfit", size: 17, relativeTo: .body)
        case .callout:      return .custom("Outfit", size: 16, relativeTo: .callout)
        case .subheadline:  return .custom("Outfit", size: 15, relativeTo: .subheadline)
        case .footnote:     return .custom("Outfit", size: 13, relativeTo: .footnote)
        case .caption1:     return .custom("Outfit", size: 12, relativeTo: .caption)
        case .caption2:     return .custom("Outfit", size: 11, relativeTo: .caption2).weight(.medium)
        }
    }
}

extension View {
    func appFont(_ style: AppTextStyle) -> some View {
        self.font(style.font)
    }
}

// MARK: - Button style (scale on press, respects Reduce Motion)

struct ScaledButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}

// MARK: - Shared card modifier

struct CardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color.elevatedBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.separator, lineWidth: 1))
    }
}

extension View {
    func cardStyle() -> some View {
        modifier(CardStyle())
    }
}

import SwiftUI

// MARK: - Colours (exact match to web app CSS variables)

extension Color {
    static let bg      = Color(hex: "#08080f")
    static let bg2     = Color(hex: "#0e0e1a")
    static let card    = Color(hex: "#141422")
    static let card2   = Color(hex: "#1a1a2e")
    static let wht     = Color(hex: "#ebebf5")   // --white (off-white, blue-tinted)
    static let dim     = Color(hex: "#6e6e87")
    static let dim2    = Color(hex: "#4a4a62")

    static let green   = Color(hex: "#44d66e")
    static let greenBg = Color(red: 68/255,  green: 210/255, blue: 110/255).opacity(0.10)
    static let greenBd = Color(red: 68/255,  green: 210/255, blue: 110/255).opacity(0.20)

    static let blue    = Color(hex: "#5aaaff")
    static let blueBg  = Color(red: 90/255,  green: 170/255, blue: 255/255).opacity(0.08)
    static let blueBd  = Color(red: 90/255,  green: 170/255, blue: 255/255).opacity(0.15)

    static let yellow  = Color(hex: "#ffc837")
    static let yellowBg = Color(red: 255/255, green: 200/255, blue: 55/255).opacity(0.08)
    static let yellowBd = Color(red: 255/255, green: 200/255, blue: 55/255).opacity(0.15)

    static let red     = Color(hex: "#ff4b4b")
    static let redBg   = Color(red: 255/255, green: 75/255,  blue: 75/255).opacity(0.08)
    static let redBd   = Color(red: 255/255, green: 75/255,  blue: 75/255).opacity(0.15)

    static let purple  = Color(hex: "#b478ff")
    static let purpleBg = Color(red: 180/255, green: 120/255, blue: 255/255).opacity(0.08)
    static let purpleBd = Color(red: 180/255, green: 120/255, blue: 255/255).opacity(0.15)

    static let border      = Color.white.opacity(0.06)
    static let borderLight = Color.white.opacity(0.10)

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

// MARK: - Typography (Outfit font)

extension Font {
    /// Outfit variable font with a given size and weight
    static func outfit(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        // Map SwiftUI weight → Outfit variable font weight value
        let name: String
        switch weight {
        case .ultraLight: name = "Outfit-ExtraLight"
        case .thin:       name = "Outfit-Thin"
        case .light:      name = "Outfit-Light"
        case .regular:    name = "Outfit-Regular"
        case .medium:     name = "Outfit-Medium"
        case .semibold:   name = "Outfit-SemiBold"
        case .bold:       name = "Outfit-Bold"
        case .heavy:      name = "Outfit-ExtraBold"
        case .black:      name = "Outfit-Black"
        default:          name = "Outfit-Regular"
        }
        // Variable font — use family name with weight axis
        return .custom("Outfit", size: size).weight(weight)
    }
}

// MARK: - Shared card modifier

struct CardStyle: ViewModifier {
    var padding: CGFloat = 0
    func body(content: Content) -> some View {
        content
            .background(Color.card)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.border, lineWidth: 1))
    }
}

extension View {
    func cardStyle(padding: CGFloat = 0) -> some View {
        modifier(CardStyle(padding: padding))
    }
}

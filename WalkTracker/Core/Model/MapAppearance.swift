import Foundation

/// How the base map is themed.
///
/// A setting rather than just following the system, because on this map the
/// two look genuinely different rather than merely lighter and darker: walked
/// streets are a neon green over a near-black base in dark mode, and that is
/// the most striking thing the app puts on screen. Somebody may well want it
/// without running their whole phone dark.
public enum MapAppearance: String, CaseIterable, Codable, Sendable {
    case system
    case light
    case dark

    public var label: String {
        switch self {
        case .system: return String(localized: "Match system")
        case .light: return String(localized: "Light")
        case .dark: return String(localized: "Dark")
        }
    }
}

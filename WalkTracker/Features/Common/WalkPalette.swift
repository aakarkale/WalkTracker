import SwiftUI
import UIKit

/// The app's colours.
///
/// VISUAL DIRECTION, recorded here so it does not get undone by accident:
/// light and modern, in the family of Strava and Nike Run Club for typography,
/// spacing and surfaces. Near-white backgrounds, white cards with a very soft
/// shadow rather than grey fills, generous whitespace instead of dividers and
/// borders, and exactly ONE vivid accent used sparingly: walked streets, the
/// progress ring, and the primary action. Everything else is near-black text,
/// mid grey secondary text, and white. Resist adding a second accent colour.
///
/// The accent is GREEN, in the tone of Nike Run Club's volt green. It is not a
/// style choice that can be swapped for a warm colour: green reads as "done"
/// instantly over a light map, which is exactly what a walked street is, and
/// the reference app for this product draws its walked blocks the same way.
///
/// Dark mode is a real dark theme rather than inverted greys: near-black page,
/// slightly lifted cards, and the same accent warmed a little so it keeps its
/// contrast against black.
///
/// Every colour is built with a dynamic provider, so the system resolves the
/// theme rather than view code branching on the colour scheme, and the same
/// values are available to both SwiftUI and the MapKit renderers.
enum WalkPalette {

    // MARK: - Accent

    /// The single accent: a vivid medium green, lifted slightly in dark mode
    /// so it keeps its contrast against a near-black page.
    static let accentUIColor = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.188, green: 0.820, blue: 0.345, alpha: 1.0)
            : UIColor(red: 0.204, green: 0.780, blue: 0.349, alpha: 1.0)
    }

    static let accent = Color(uiColor: accentUIColor)

    // MARK: - Map

    /// Walked streets, the bright core of the line.
    ///
    /// Deliberately not the same green as the interface accent. A button sits
    /// on white and needs a green that reads against white; a walked street
    /// sits on the map, and in dark mode that map is nearly black. The accent
    /// green goes muddy there, so dark mode gets a neon lime that looks lit
    /// rather than painted. That glow against a dark map is the single most
    /// striking thing this app can put on screen, and it is worth a second
    /// colour to get right.
    static let walkedCoreUIColor = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.42, green: 0.98, blue: 0.35, alpha: 1.0)
            : UIColor(red: 0.204, green: 0.780, blue: 0.349, alpha: 1.0)
    }

    /// The halo drawn under the core, wider and much fainter.
    ///
    /// This is what makes the line look luminous instead of merely coloured.
    /// Faint in light mode, where a bloom over a pale map just reads as a
    /// smudge, and strong in dark mode, where it does the work.
    static let walkedGlowUIColor = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.42, green: 0.98, blue: 0.35, alpha: 0.28)
            : UIColor(red: 0.204, green: 0.780, blue: 0.349, alpha: 0.16)
    }

    /// Kept for interface use: chips, legends and anything off the map.
    static let walkedUIColor = walkedCoreUIColor

    /// Streets still to walk. A light warm grey: present enough to read as a
    /// street network, quiet enough that the accent pops off it. The map should
    /// feel like a clean canvas the accent is drawn onto, not a street atlas.
    static let unwalkedUIColor = UIColor { traits in
        traits.userInterfaceStyle == .dark
            // Quieter in dark mode than the light-mode equivalent. The dark
            // base map already draws its own streets clearly, so this only has
            // to mark which of them are in scope, and anything louder competes
            // with the green it exists to set off.
            ? UIColor(red: 0.55, green: 0.56, blue: 0.60, alpha: 0.38)
            : UIColor(red: 0.76, green: 0.73, blue: 0.70, alpha: 0.95)
    }

    static let walked = Color(uiColor: walkedUIColor)
    static let unwalked = Color(uiColor: unwalkedUIColor)

    // MARK: - Text

    /// Near-black rather than pure black, which is harsh on white.
    static let ink = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.95, green: 0.95, blue: 0.96, alpha: 1.0)
            : UIColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1.0)
    })

    static let secondaryInk = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.60, green: 0.60, blue: 0.63, alpha: 1.0)
            : UIColor(red: 0.56, green: 0.56, blue: 0.58, alpha: 1.0)
    })

    // MARK: - Surfaces

    /// Page background: a warm near-white, and a true near-black in dark mode.
    static let background = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.043, green: 0.043, blue: 0.047, alpha: 1.0)
            : UIColor(red: 0.985, green: 0.980, blue: 0.976, alpha: 1.0)
    })

    /// Cards sit on the page: white on light, lifted grey on dark.
    static let card = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1.0)
            : UIColor.white
    })

    /// Soft and low contrast. Shadows do not read on a black page, so in dark
    /// mode the card is separated by its own lighter fill instead.
    static let cardShadow = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor.black.withAlphaComponent(0)
            : UIColor.black.withAlphaComponent(0.06)
    })

    /// For the thin rules between stat columns. Never used as a box border.
    static let hairline = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.10)
            : UIColor.black.withAlphaComponent(0.08)
    })

    /// The stop control while a walk is recording. Not a second accent: it is
    /// the system's own destructive red and appears in one place only.
    static let recording = Color.red
}

import SwiftUI
import UIKit

// The GoldenNugget Mobile design tokens.
//
// Ported from the desktop app's own iOS GUI, which is the only place the design
// is stated — three files, and every value below comes from one of them:
//
//   * `src/gui/theme/colors.py`  — the `DARK` `ThemeColors` palette (surfaces,
//     text, accent, semantic, borders).  The iOS GUI's default theme is that
//     palette, so the hexes here are the reference's own, not approximations.
//   * `src/gui/theme/styles.py`  — the component stylesheet: radii, paddings,
//     font sizes/weights, letter-spacing, and the switch's on/off track colors.
//   * `src/gui/ios/components.py` — the mobile component set (`IOSCard`,
//     `IOSNavBar`, `IOSSectionHeader`, `IOSSettingsRow`, `IOSPrimaryButton`,
//     `IOSDangerButton`, `IOSSwitch`, `IOSValueLabel`) and its fixed metrics
//     (nav bar 56, primary/danger button 50, logo 80 with radius 14).
//
// **One deliberate divergence: the font family.**  The reference pins a bundled
// `Inter Variable` on every platform, because Qt's default family differs per
// OS and it wants one look everywhere.  On iOS the reference's component set is
// explicitly an imitation of the platform's own chrome (a 51×31 switch with a
// green track, a centred 17/600 nav title, grouped cards), so the system font is
// the faithful choice here — the *scale* below is the reference's, and `Inter`
// is used automatically if it is ever bundled (see `GoldenFont.hasInter`).
enum GoldenTheme {

    // MARK: - Surfaces
    //
    // colors.py: bg_primary is the page, bg_secondary the card/row/nav fill,
    // bg_tertiary the chip fill, bg_input the field fill.

    static let backgroundPrimary = hex(0x1E1E1E)
    static let backgroundSecondary = hex(0x1C1C1E)
    static let backgroundTertiary = hex(0x2C2C2E)
    static let backgroundInput = hex(0x1C1C1E)

    // MARK: - Text

    static let textPrimary = Color.white
    static let textSecondary = hex(0x8E8E93)
    static let textDisabled = hex(0x787878)
    static let textInverse = Color.white

    // MARK: - Accent and semantics

    static let accent = hex(0x007AFF)
    static let accentPressed = hex(0x0055AA)
    static let success = hex(0x30D158)
    static let error = hex(0xFF453A)
    static let errorPressed = hex(0xC2322A)
    static let warning = hex(0xFFD60A)

    // MARK: - Borders

    static let border = hex(0x3A3A3C)
    static let divider = hex(0x3A3A3C)
    static let surfaceHover = hex(0x2C2C2E)

    // MARK: - Metrics
    //
    // components.py: `IOSNavBar.setFixedHeight(56)`,
    // `IOSPrimaryButton.setFixedHeight(50)`, `IOSSwitch.setFixedSize(51, 31)`,
    // the home logo `setFixedSize(80, 80)` with radius 14.
    // styles.py: `card` radius 12, `settings_row` radius 10 / padding 14·16,
    // the dialog inputs radius 10 / padding 12·16.

    static let navBarHeight: CGFloat = 56
    static let buttonHeight: CGFloat = 50
    static let logoSize: CGFloat = 80
    static let logoRadius: CGFloat = 14
    static let cardRadius: CGFloat = 12
    static let rowRadius: CGFloat = 10
    static let controlRadius: CGFloat = 10

    // Spacing, straight from the two page layouts: the home page uses
    // `setContentsMargins(16,16,16,16)` + `setSpacing(16)`, the tweaks page
    // `setContentsMargins(16,16,16,32)` + `setSpacing(8)`; the home card grid
    // reflows at `MIN_CARD_WIDTH = 200` with `SPACING = 12`.
    static let pageMargin: CGFloat = 16
    static let sectionSpacing: CGFloat = 16
    static let rowSpacing: CGFloat = 8
    static let gridSpacing: CGFloat = 12
    static let gridMinCardWidth: CGFloat = 200

    /// The iOS GUI renders inside a phone frame on the desktop, i.e. it never
    /// gets wider than a phone.  This app runs on an iPad (TARGETED_DEVICE_FAMILY
    /// 1,2), so the same reading is reproduced by constraining the content and
    /// centring it — the alternative, letting one row stretch to 1366 pt, is the
    /// one thing the reference's layout can never show.
    static let contentMaxWidth: CGFloat = 720

    /// Card content insets (`settings_row` padding 14·16).
    static let rowPadding = EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16)
    /// Card body insets for multi-element cards (the home card content used 16).
    static let cardPadding = EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)

    static func hex(_ value: UInt32) -> Color {
        Color(red: Double((value >> 16) & 0xFF) / 255.0,
              green: Double((value >> 8) & 0xFF) / 255.0,
              blue: Double(value & 0xFF) / 255.0)
    }
}

/// The reference's type scale (`styles.py`), one case per named style.
///
/// Sizes and weights are copied exactly; the family is resolved by `font(...)`
/// — Inter when it is bundled, the system font otherwise, so the design reads
/// the same on device either way.
enum GoldenFont {
    /// `home_title`: 32px / 700.
    static let homeTitle = font(32, .bold)
    /// `home_subtitle`: 14px / 400, secondary.
    static let homeSubtitle = font(14)
    /// `nav_title` / `home_card_title`: 17px / 600.
    static let navTitle = font(17, .semibold)
    static let cardTitle = font(17, .semibold)
    /// `settings_row` and the switch row labels: 15px / 400.
    static let rowTitle = font(15)
    /// The dialog controls are 15px too.
    static let field = font(15)
    /// `home_card_subtitle`: 13px / 400.
    static let cardSubtitle = font(13)
    /// `section_header`: 13px / 600, uppercase, 0.5px tracking.
    static let sectionHeader = font(13, .semibold)
    /// `value_label`: 14px / 400, secondary.
    static let value = font(14)
    /// The default `QLabel` size.
    static let body = font(14)
    /// `process_status_*`: 14px / 500.
    static let status = font(14, .medium)
    /// `safety_note`: 12px, italic, danger text.
    static let safetyNote = font(12).italic()
    /// The smallest size the reference uses (posterboard card labels).
    static let caption = font(11)
    /// Log lines, which are paths and byte counts: monospaced so columns of
    /// numbers line up and a path is readable character by character. Not a
    /// reference style -- the reference shows these in a QTextEdit.
    static let monoCaption = Font.system(size: 11, design: .monospaced)
    /// Not in the reference: the log view is this app's own surface, and the
    /// macOS/iOS convention for log text is monospaced.
    static let log = Font.system(size: 12, design: .monospaced)

    /// True when `Inter Variable` resolved, in which case every style above is
    /// rendered in it.  False on a build that does not bundle the font, which is
    /// the shipping state — see this file's header for why that is not a defect.
    static let hasInter = interName != nil

    /// `styles.py: FONT_FAMILY = "Inter Variable"`; the PostScript name of the
    /// bundled variable font is `InterVariable`, so both spellings are probed
    /// rather than one being assumed.
    private static let interName: String? = {
        for name in ["Inter Variable", "InterVariable"] {
            if UIFont(name: name, size: 15) != nil { return name }
        }
        return nil
    }()

    private static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        if let interName {
            return .custom(interName, size: size).weight(weight)
        }
        return .system(size: size, weight: weight)
    }
}

import SwiftUI
import UIKit

// The GoldenNugget Mobile component set, ported from `src/gui/ios/components.py`
// and `src/gui/theme/styles.py`.
//
// The reference draws each list row as its **own** rounded surface stacked with
// 8 pt between them (`IOSCard` in the tweaks page, `IOSSettingsRow` on the home
// page) rather than as an iOS grouped table, so the primitives here are
// one-row-per-surface too and no view has to re-implement the chrome.  Every
// metric is a token in `GoldenTheme`; nothing below invents a number.

// MARK: - Page scaffold

/// The scroll body both pages share: page background, 16 pt margins, content
/// capped at `contentMaxWidth` and centred on a wide screen.
struct GoldenPage<Content: View>: View {
    var spacing: CGFloat = GoldenTheme.sectionSpacing
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            // Lazy, not eager: this is the scaffold behind every page, and two of
            // them are long lists — the tweaks page builds a card per enabled
            // section (98 in Liquid Glass alone) and Files builds three rows per
            // entry.  An eager `VStack` created *all* of them up front and kept
            // them alive, so the first paint of a section and every subsequent
            // diff paid for rows that were never on screen.
            LazyVStack(alignment: .leading, spacing: spacing) {
                content
            }
            .padding(GoldenTheme.pageMargin)
            // Two frames on purpose: constrain, then centre what was constrained.
            .frame(maxWidth: GoldenTheme.contentMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .background(GoldenTheme.backgroundPrimary.ignoresSafeArea())
    }
}

// MARK: - Text

/// `styles.py: section_header` — 13/600, uppercase, 0.5 pt tracking, 4 pt inset.
struct GoldenSectionHeader: View {
    let text: String

    var body: some View {
        Text(text)
            .font(GoldenFont.sectionHeader)
            .tracking(0.5)
            .textCase(.uppercase)
            .foregroundColor(GoldenTheme.textSecondary)
            .padding(.leading, 4)
    }
}

/// A titled block: the reference's section header followed by its rows, with
/// the 8 pt gutter the tweaks page uses between a header and what it labels.
///
/// `content` is an `AnyView` because two of the call sites are a conditional
/// pair of rows (load vs reset), which a generic parameter would force them to
/// spell out twice.
struct GoldenSection: View {
    let title: String
    let content: AnyView

    var body: some View {
        VStack(alignment: .leading, spacing: GoldenTheme.rowSpacing) {
            GoldenSectionHeader(text: title)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A section header that folds its rows away.
///
/// **The rows are not drawn by this view.**  The caller emits them as siblings —
/// `GoldenCollapsibleHeader(…)` followed by `if !collapsed { ForEach(rows) { … } }`
/// — so they become individual children of `GoldenPage`'s `LazyVStack` and are
/// built only as they scroll into view.
///
/// The original shape was a header *containing* its rows in a `VStack`, which
/// made a whole section one child of the lazy stack: every row of every open
/// section was built on the first pass.  With a restored preset (172 tweaks here)
/// all three sections open by default, so opening the Tweaks page built 133 cards
/// — each with a title, a control, an id and a description — before it could
/// draw its first frame.  Splitting the header out is what makes the list lazy
/// for real; `GoldenSection` (no rows to fold) is unaffected.
struct GoldenCollapsibleHeader: View {
    let title: String
    @Binding var isCollapsed: Bool

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) { isCollapsed.toggle() }
        } label: {
            HStack(spacing: 6) {
                GoldenSectionHeader(text: title)
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(GoldenTheme.textSecondary)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// `styles.py: safety_note` — 12 px italic in the danger tone.  Used for the
/// lines that say what an action costs (reboot, overwrite).
struct GoldenSafetyNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(GoldenFont.safetyNote)
            .foregroundColor(GoldenTheme.error)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A muted explanatory line (`styles.py: home_card_subtitle`, 13 pt secondary).
struct GoldenMutedNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(GoldenFont.cardSubtitle)
            .foregroundColor(GoldenTheme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// `styles.py: value_label` — the muted parenthesised value beside a row title.
struct GoldenValueLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(GoldenFont.value)
            .foregroundColor(GoldenTheme.textSecondary)
    }
}

/// `styles.py: process_status_*` — 14/500, tone picked by the caller.  This is
/// the coloured state line the reference puts under the home header.
struct GoldenStatusText: View {
    let text: String
    var tone: GoldenTone = .primary
    var centered = false

    var body: some View {
        Text(text)
            .font(GoldenFont.status)
            .foregroundColor(tone.color)
            .multilineTextAlignment(centered ? .center : .leading)
            .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The tone slots the reference has named colors for.
enum GoldenTone {
    case primary, secondary, disabled, accent, success, error, warning

    var color: Color {
        switch self {
        case .primary: return GoldenTheme.textPrimary
        case .secondary: return GoldenTheme.textSecondary
        case .disabled: return GoldenTheme.textDisabled
        case .accent: return GoldenTheme.accent
        case .success: return GoldenTheme.success
        case .error: return GoldenTheme.error
        case .warning: return GoldenTheme.warning
        }
    }
}

// MARK: - Surfaces

/// The row surface every list row wears: radius 10, padding 14·16,
/// `bg_secondary` (`styles.py: settings_row`).
extension View {
    func goldenRowSurface() -> some View {
        padding(GoldenTheme.rowPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: GoldenTheme.rowRadius)
                .fill(GoldenTheme.backgroundSecondary))
    }
}

/// The press feedback the reference gives every row (`:hover` → `surface_hover`).
struct GoldenRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(GoldenTheme.rowPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: GoldenTheme.rowRadius)
                .fill(configuration.isPressed ? GoldenTheme.surfaceHover
                                              : GoldenTheme.backgroundSecondary))
    }
}

/// `styles.py: card` — radius 12, `bg_secondary`, no border.  For the multi-part
/// surfaces (status block, log, import report).
struct GoldenCard<Content: View>: View {
    var padding: EdgeInsets = GoldenTheme.cardPadding
    var spacing: CGFloat = GoldenTheme.rowSpacing
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            content
        }
        .padding(padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: GoldenTheme.cardRadius)
            .fill(GoldenTheme.backgroundSecondary))
    }
}

/// The hairline the reference draws between rows of one card.
struct GoldenDivider: View {
    var body: some View {
        Rectangle()
            .fill(GoldenTheme.divider)
            .frame(height: 1)
    }
}

// MARK: - Row content

/// The inside of a row: a leading title, an optional muted value and an optional
/// trailing glyph (`IOSSettingsRow` renders `title  (value)  ›` on one line).
struct GoldenRowLabel: View {
    let title: String
    var value: String?
    var systemImage: String?
    var trailingGlyph: String? = "chevron.right"
    var tone: GoldenTone = .primary

    var body: some View {
        HStack(spacing: 12) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 15))
                    .foregroundColor(tone == .primary ? GoldenTheme.textSecondary : tone.color)
                    .frame(width: 20)
            }
            // `layoutPriority(1)` so the title is the last thing to be squeezed:
            // a row is 288 pt wide in Slide Over, and after the icon (20), the
            // chevron (13), the gutters and the 32 pt row padding there is ~170
            // pt for title + value.  Without the priority the two split it, and
            // a value like "12.3 GB free of 64 GB" wrapped to three lines while
            // the title was cut to a fragment.
            //
            // The value keeps one line and shrinks instead: it is a measurement
            // or a version, and a wrapped number reads as two facts.
            Text(title)
                .font(GoldenFont.rowTitle)
                .foregroundColor(tone.color)
                .layoutPriority(1)
            Spacer(minLength: 8)
            if let value {
                GoldenValueLabel(text: value)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            if let trailingGlyph {
                Image(systemName: trailingGlyph)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(GoldenTheme.textDisabled)
            }
        }
        .contentShape(Rectangle())
    }
}

/// A row that opens something — `IOSSettingsRow`, chevron included.
struct GoldenActionRow: View {
    let title: String
    var value: String?
    var systemImage: String?
    var tone: GoldenTone = .primary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            GoldenRowLabel(title: title, value: value, systemImage: systemImage, tone: tone)
        }
        .buttonStyle(GoldenRowButtonStyle())
    }
}

/// The switch of the tweaks page.
///
/// `IOSSwitch` is a hand-drawn copy of the platform switch (51×31, `success`
/// track when on, `border` when off, white knob) — on iOS the platform control
/// *is* that, so it is used and tinted rather than redrawn.
struct GoldenSwitch: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle("", isOn: $isOn)
            .labelsHidden()
            .tint(GoldenTheme.success)
    }
}

// MARK: - Inputs

/// The field chrome the reference uses in its input dialogs (radius 10,
/// `bg_input`, 15 px, padding 12·16) — applied to the inline editors this app
/// already had, so a field looks the same whether it is inline or in a sheet.
struct GoldenFieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(GoldenFont.field)
            .foregroundColor(GoldenTheme.textPrimary)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: GoldenTheme.controlRadius)
                .fill(GoldenTheme.backgroundInput))
    }
}

extension View {
    func goldenField() -> some View { modifier(GoldenFieldStyle()) }

    /// Put a "Done" above the keyboard — required for `.numberPad` /
    /// `.decimalPad` fields, which have no Return key of their own.
    func goldenKeyboardDone() -> some View { modifier(GoldenKeyboardDone()) }
}

/// A "Done" button in a toolbar above the keyboard.
///
/// Needed on a phone for every field whose keyboard has **no Return key** —
/// `.numberPad` and `.decimalPad` — because without one there is no way to put
/// the keyboard away: it covers half the screen and the field below it stays
/// unreachable.  `.numbersAndPunctuation` and the default keyboards have a
/// Return key, so fields using those do not need this.
///
/// It resigns first responder through UIKit instead of tracking a `@FocusState`
/// per field, so one modifier serves every field in the app.
struct GoldenKeyboardDone: ViewModifier {
    func body(content: Content) -> some View {
        content.toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { Self.resignFirstResponder() }
            }
        }
    }

    private static func resignFirstResponder() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                        to: nil, from: nil, for: nil)
    }
}

/// A labelled field row (label 13 pt secondary above the field, as the home
/// page's target section needs).
struct GoldenLabeledField<Content: View>: View {
    let label: String
    @ViewBuilder var field: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(GoldenFont.cardSubtitle)
                .foregroundColor(GoldenTheme.textSecondary)
            field.goldenField()
        }
    }
}

// MARK: - Buttons

/// `styles.py: primary_button` — 50 pt, radius 12, accent→accent_pressed
/// vertical gradient, 17/600 label; disabled is `border` on `text_disabled`.
struct GoldenPrimaryButton: View {
    let title: String
    var running = false
    var disabled = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            GoldenButtonLabel(title: title,
                              grayed: running || disabled,
                              showsSpinner: running,
                              gradient: [GoldenTheme.accent, GoldenTheme.accentPressed])
        }
        .buttonStyle(.plain)
        .disabled(running || disabled)
    }
}

/// `styles.py: danger_button` — the same geometry in the error ramp.
struct GoldenDangerButton: View {
    let title: String
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            GoldenButtonLabel(title: title,
                              grayed: disabled,
                              showsSpinner: false,
                              gradient: [GoldenTheme.error, GoldenTheme.errorPressed])
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

/// One button body for both ramps, so their geometry cannot drift apart.
/// `grayed` is the reference's `:disabled` state (`border` fill,
/// `text_disabled` label) — reached by "the run is in flight" as well as by
/// "there is nothing to run against".
struct GoldenButtonLabel: View {
    let title: String
    let grayed: Bool
    let showsSpinner: Bool
    let gradient: [Color]

    var body: some View {
        HStack(spacing: 8) {
            if showsSpinner {
                ProgressView().tint(GoldenTheme.textDisabled)
            }
            Text(title)
                .font(GoldenFont.navTitle)
                .foregroundColor(grayed ? GoldenTheme.textDisabled : GoldenTheme.textInverse)
        }
        .frame(maxWidth: .infinity)
        .frame(height: GoldenTheme.buttonHeight)
        .background(RoundedRectangle(cornerRadius: GoldenTheme.cardRadius)
            .fill(LinearGradient(colors: grayed ? [GoldenTheme.border, GoldenTheme.border] : gradient,
                                 startPoint: .top, endPoint: .bottom)))
        .contentShape(Rectangle())
    }
}

// MARK: - Home header and cards

/// The home header: 80×80 logo with radius 14, 32/700 title, and the line under
/// it — the reference keeps this one `text_secondary`, and tints only its
/// separate status label, so the tone stays a parameter rather than a constant.
struct GoldenHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    var subtitleTone: GoldenTone = .secondary
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            GoldenLogo()
            VStack(alignment: .leading, spacing: 4) {
                // Shrink rather than wrap in a narrow window.  The arithmetic
                // behind 0.6: the narrowest window this app can be given is
                // Slide Over at 320 pt — 2×16 pt page margins leaves 288, minus
                // the logo (80), the 16 pt gutter and the trailing button (36)
                // leaves **156 pt** for the title.  "GoldenNugget" at 32 pt bold
                // is ~210 pt, so it needs 0.74 to fit; 0.6 leaves headroom for a
                // longer subtitle row and still renders at 19 pt, which reads.
                // Wrapping instead would turn the header into a three-line tower
                // and push the whole page down.
                Text(title)
                    .font(GoldenFont.homeTitle)
                    .foregroundColor(GoldenTheme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(subtitle)
                    .font(GoldenFont.homeSubtitle)
                    .foregroundColor(subtitleTone.color)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            trailing
        }
    }
}

/// The header as the reference's home page draws it when there is nothing to
/// put on the right (`home.py`: logo + title + subtitle, and the device picker
/// only when the host can see more than one device).
extension GoldenHeader where Trailing == EmptyView {
    init(title: String, subtitle: String, subtitleTone: GoldenTone = .secondary) {
        self.init(title: title, subtitle: subtitle, subtitleTone: subtitleTone) {
            EmptyView()
        }
    }
}

/// `styles.py: home_icon_button` — 36×36, `bg_secondary`, radius 10, 18 pt
/// glyph.  `home.py` puts a refresh and a settings button in the header; this
/// is the one the refresh uses.
struct GoldenIconButton: View {
    let systemImage: String
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(GoldenTheme.textPrimary)
                .frame(width: 36, height: 36)
                .background(RoundedRectangle(cornerRadius: 10)
                    .fill(GoldenTheme.backgroundSecondary))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// The app icon, drawn at the header size the reference uses for its logo, with
/// the reference's own fallback when the artwork is missing
/// (`home.py`: a `bg_secondary` square at radius 14).
struct GoldenLogo: View {
    /// The square the logo is drawn at. The home header keeps the design system's
    /// 80; the settings page's About wants it larger, and a second hard-coded
    /// frame here would be one more number to keep in step with the theme.
    var size: CGFloat = GoldenTheme.logoSize

    var body: some View {
        Group {
            if let image = GoldenLogo.bundledIcon {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: GoldenTheme.logoRadius)
                    .fill(GoldenTheme.backgroundSecondary)
                    .overlay(
                        Image(systemName: "shippingbox.fill")
                            .font(.system(size: 32))
                            .foregroundColor(GoldenTheme.accent)
                    )
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: GoldenTheme.logoRadius))
    }

    /// The same artwork the home screen shows.
    ///
    /// It deliberately does **not** go through `UIImage(named: "AppIcon")`, even
    /// though the icon is a catalog asset and that looks like the obvious way in.
    /// An app icon is not an image: the name resolves to a `CUINamedImage` out of
    /// the iconstack rather than to CGImage-backed content, and UIKit's
    /// `-[_UIImageCGImageContent initWithCGImageSource:CGImage:scale:]` asserts on
    /// it. That is an `NSAssertionHandler` throw, not a Swift error, so it cannot
    /// be caught — it aborts the process:
    ///
    ///     GoldenLogo.bundledIcon -> UIImage(named:) -> _UIAssetManager imageNamed:
    ///       -> CUINamedImage UIImageWithAsset: -> _UIImageCGImageContent initWithCGImageSource:
    ///       -> NSAssertionHandler handleFailureInMethod: -> objc_exception_throw -> abort
    ///
    /// SIGABRT, `bug_type 309`, and because this is a `static let` the trap fires
    /// on the first view that asks for the logo — during the home screen's first
    /// layout pass, so the app dies before anything is on screen. One iconstack in
    /// the car happened to resolve to a loadable rendition; a second one did not,
    /// which is what turned a latent bad call into a launch crash.
    ///
    /// `Logo@1x/@2x` are the same artwork under names no icon key can claim, so
    /// they cannot shadow the iconstack the way the light-only `AppIcon*.png`
    /// files used to. Loading them by path cannot abort.
    ///
    /// Following the light/dark theme again means a real `.imageset` in the
    /// catalog with a dark twin — `UIImage(named:)` handles an ordinary imageset
    /// fine. It needs an actool round-trip, since the car is built on macOS.
    private static let bundledIcon: UIImage? = {
        if let path = Bundle.main.path(forResource: "Logo@2x", ofType: "png"),
           let image = UIImage(contentsOfFile: path) { return image }
        if let path = Bundle.main.path(forResource: "Logo@1x", ofType: "png"),
           let image = UIImage(contentsOfFile: path) { return image }
        return nil
    }()
}

// MARK: - Log

/// The run log.  The reference has no log surface (its progress goes to a status
/// line), so this is this app's own — but it wears the reference's card chrome:
/// `bg_secondary`, radius 12, muted text.  Scrolls on its own so a long run does
/// not push the controls out of reach.
struct GoldenLogView: View {
    let lines: [String]
    /// The identity of `lines[0]`, for callers whose window slides (`RunLog`).
    /// Static content leaves it at 0 — the ids only have to be unique and stable
    /// within one view, not globally.
    var firstId: Int = 0
    var height: CGFloat = 300

    /// Rows keyed by a stable id rather than by array offset: offset identities
    /// all shift by one when a sliding window drops its first line, and SwiftUI
    /// then rebuilds every row instead of moving the window.
    private var rows: [(id: Int, text: String)] {
        lines.enumerated().map { (firstId + $0.offset, $0.element) }
    }

    var body: some View {
        ScrollView {
            // Lazy on purpose: the engine keeps up to 600 lines, and a run with
            // every chunk logged would otherwise build 600 selectable `Text`s
            // before the first frame.
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(rows, id: \.id) { row in
                    Text(row.text)
                        .font(GoldenFont.log)
                        .foregroundColor(GoldenTheme.textSecondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(GoldenTheme.cardPadding)
        }
        .frame(height: height)
        .background(RoundedRectangle(cornerRadius: GoldenTheme.cardRadius)
            .fill(GoldenTheme.backgroundSecondary))
    }
}

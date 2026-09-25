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
            VStack(alignment: .leading, spacing: spacing) {
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
            Text(title)
                .font(GoldenFont.rowTitle)
                .foregroundColor(tone.color)
            Spacer(minLength: 8)
            if let value {
                GoldenValueLabel(text: value)
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
                Text(title)
                    .font(GoldenFont.homeTitle)
                    .foregroundColor(GoldenTheme.textPrimary)
                Text(subtitle)
                    .font(GoldenFont.homeSubtitle)
                    .foregroundColor(subtitleTone.color)
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
        .frame(width: GoldenTheme.logoSize, height: GoldenTheme.logoSize)
        .clipShape(RoundedRectangle(cornerRadius: GoldenTheme.logoRadius))
    }

    /// The icon ships as a loose PNG at the bundle root (`project.yml`), not in
    /// an asset catalog, so it is loaded by file name with both spellings tried.
    private static let bundledIcon: UIImage? = {
        for name in ["AppIcon60x60@2x", "AppIcon76x76@2x~ipad"] {
            if let path = Bundle.main.path(forResource: name, ofType: "png"),
               let image = UIImage(contentsOfFile: path) {
                return image
            }
        }
        return nil
    }()
}

/// `home.py:_make_card` — a 56 pt header band with the 17/600 title, then a
/// content block with the 13 pt subtitle (and, for this app, the one number the
/// card stands for).  A plain label so the caller wraps it in whatever it needs
/// — a `NavigationLink` here — and the whole card stays one tap target.  The
/// reference's card has no chevron; neither does this.
struct GoldenFeatureCardLabel: View {
    let title: String
    let subtitle: String
    var detail: String?

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(GoldenFont.cardTitle)
                .foregroundColor(GoldenTheme.textPrimary)
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(GoldenTheme.backgroundSecondary)

            VStack(alignment: .leading, spacing: 4) {
                Text(subtitle)
                    .font(GoldenFont.cardSubtitle)
                    .foregroundColor(GoldenTheme.textSecondary)
                if let detail {
                    GoldenValueLabel(text: detail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(GoldenTheme.cardPadding)
        }
        // The reference's card body sits on the page fill while only the header
        // band is `bg_secondary`, which is what gives the card its two-tone look.
        .background(GoldenTheme.backgroundTertiary)
        .clipShape(RoundedRectangle(cornerRadius: GoldenTheme.cardRadius))
        .contentShape(Rectangle())
    }
}

/// `home.py:_CardGrid` — reflows the cards into the largest column count where
/// each card still gets `gridMinCardWidth`, so a wide screen fills one row
/// instead of dropping the last card to a second one.
struct GoldenCardGrid<Content: View>: View {
    let itemCount: Int
    let content: (Int) -> Content
    @State private var width: CGFloat = 0

    init(itemCount: Int, @ViewBuilder content: @escaping (Int) -> Content) {
        self.itemCount = itemCount
        self.content = content
    }

    var body: some View {
        let columns = columnCount(for: width)
        let rows = columns > 0 ? Int(ceil(Double(itemCount) / Double(columns))) : 0
        VStack(spacing: GoldenTheme.gridSpacing) {
            ForEach(0..<max(rows, 0), id: \.self) { row in
                HStack(spacing: GoldenTheme.gridSpacing) {
                    ForEach(0..<max(columns, 1), id: \.self) { column in
                        let index = row * columns + column
                        if index < itemCount {
                            content(index)
                        } else {
                            Color.clear
                        }
                    }
                }
            }
        }
        .background(GeometryReader { proxy in
            Color.clear
                .onAppear { width = proxy.size.width }
                .onChange(of: proxy.size.width) { width = $0 }
        })
    }

    private func columnCount(for width: CGFloat) -> Int {
        guard width > 0, itemCount > 0 else { return 1 }
        for candidate in stride(from: itemCount, through: 1, by: -1) {
            let available = width - GoldenTheme.gridSpacing * CGFloat(candidate - 1)
            if available / CGFloat(candidate) >= GoldenTheme.gridMinCardWidth { return candidate }
        }
        return 1
    }
}

// MARK: - Log

/// The run log.  The reference has no log surface (its progress goes to a status
/// line), so this is this app's own — but it wears the reference's card chrome:
/// `bg_secondary`, radius 12, muted text.  Scrolls on its own so a long run does
/// not push the controls out of reach.
struct GoldenLogView: View {
    let lines: [String]
    var height: CGFloat = 300

    var body: some View {
        ScrollView {
            // Lazy on purpose: the engine keeps up to 600 lines, and a run with
            // every chunk logged would otherwise build 600 selectable `Text`s
            // before the first frame.
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
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

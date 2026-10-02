import SwiftUI
import UIKit

// Plain-SwiftUI building blocks for the native screens.
//
// These are deliberately thin.  The screens themselves use `List`/`Form`,
// `Section`, `NavigationLink`, `Toggle`, `TextField`, `LabeledContent` and the
// system button styles directly; only the few repeated bits of custom text and
// the two action buttons live here.  Nothing in this file imitates the desktop
// build, and every value is a Dynamic Type text style or a semantic system
// colour so light and dark, and the user's text size, both work.
//
// The original `Golden*` component library is kept untouched in
// `GoldenComponents.swift` / `GoldenTheme.swift` for reuse elsewhere; the
// native screens do not depend on it.

/// A muted explanatory line: secondary, footnote, wraps rather than truncates.
struct NativeNote: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A line that says what an action costs, in the system danger tone.
struct NativeSafetyNote: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A full-width prominent action, with an inline spinner while running.
///
/// Uses the platform's Liquid Glass prominent button style — the system draws
/// the metal, the press feedback and the disabled state, so there is no gradient
/// to keep in step with the OS.
struct NativePrimaryButton: View {
    let title: String
    var systemImage: String?
    var running = false
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if running {
                    ProgressView().controlSize(.small)
                } else if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title).font(.headline)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
        .disabled(running || disabled)
    }
}

/// A full-width destructive action, in the system's red prominent treatment.
struct NativeDangerButton: View {
    let title: String
    var systemImage: String?
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(role: .destructive, action: action) {
            HStack(spacing: 8) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title).font(.headline)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(.red)
        .disabled(disabled)
    }
}

/// A tappable list-section header that folds the section's rows away.
///
/// `Section(isExpanded:)` is the platform's own collapsible section, but in the
/// tweaks/daemons `List`s it drew no visible affordance, so the fold was
/// unreachable.  This header draws the chevron itself and toggles the same
/// *collapsed* binding the page already keeps, so the fold state stays where it
/// was and the caller emits the rows only while the section is open.
struct NativeCollapsibleHeader: View {
    let title: String
    @Binding var collapsed: Bool

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { collapsed.toggle() }
        } label: {
            HStack(spacing: 6) {
                Text(title)
                Spacer(minLength: 0)
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The app artwork at a chosen size, rounded like the home-screen icon.
///
/// Self-contained on purpose: it loads the same `Logo@1x/@2x` bundle files the
/// ported `GoldenLogo` did, but without depending on the old component library.
struct NativeLogo: View {
    var size: CGFloat = 72

    var body: some View {
        Group {
            if let image = NativeLogo.bundledIcon {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: size * 0.2, style: .continuous)
                    .fill(.thinMaterial)
                    .overlay(
                        Image(systemName: "shippingbox.fill")
                            .font(.system(size: size * 0.4))
                            .foregroundStyle(.tint)
                    )
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.2, style: .continuous))
    }

    /// `Logo@1x/@2x` are the icon artwork under names no icon key can claim, so
    /// loading them by path cannot abort the way `UIImage(named: "AppIcon")` can.
    private static let bundledIcon: UIImage? = {
        if let path = Bundle.main.path(forResource: "Logo@2x", ofType: "png"),
           let image = UIImage(contentsOfFile: path) { return image }
        if let path = Bundle.main.path(forResource: "Logo@1x", ofType: "png"),
           let image = UIImage(contentsOfFile: path) { return image }
        return nil
    }()
}

extension GoldenTone {
    /// The same tone slot, in the platform's semantic palette rather than the
    /// desktop build's named colours.
    var nativeColor: Color {
        switch self {
        case .primary: return .primary
        case .secondary: return .secondary
        case .disabled: return Color(.tertiaryLabel)
        case .accent: return .accentColor
        case .success: return .green
        case .error: return .red
        case .warning: return .orange
        }
    }
}

extension View {
    /// Put a "Done" above the keyboard — required for `.numberPad` /
    /// `.decimalPad` fields, which have no Return key of their own.
    func nativeKeyboardDone() -> some View { modifier(NativeKeyboardDone()) }
}

/// A "Done" button in a toolbar above the keyboard, resigning through UIKit so
/// one modifier serves every field.
struct NativeKeyboardDone: ViewModifier {
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

import SwiftUI

/// One tweak: its title, the control its kind calls for, and its id.
///
/// Shared by the Tweaks and Daemons pages so a daemon row is not a lookalike of
/// a tweak row but literally the same view. The on/off behaviour is injected
/// rather than read off the selection, because the two pages disagree about
/// what "on" means: a tweak is on when its flag is set, a daemon group is on
/// when every launchd label in it has to be written as disabled, and only the
/// second one needs a value written alongside the flag.
struct TweakRow: View {
    let spec: TweakSpec
    private let readOn: () -> Bool
    private let writeOn: (Bool) -> Void

    init(spec: TweakSpec, selection: Binding<TweakSelection>) {
        self.init(spec: spec, isOn: { selection.wrappedValue.isOn(spec) },
                  setOn: { selection.wrappedValue.setOn($0, for: spec) })
    }

    init(spec: TweakSpec, isOn: @escaping () -> Bool, setOn: @escaping (Bool) -> Void) {
        self.spec = spec
        self.readOn = isOn
        self.writeOn = setOn
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch spec.kind {
            case .toggle:
                HStack(spacing: 12) {
                    Text(spec.title)
                        .font(GoldenFont.rowTitle)
                        .foregroundColor(GoldenTheme.textPrimary)
                    Spacer(minLength: 12)
                    GoldenSwitch(isOn: toggleBinding)
                }
            case .text, .number:
                // Only the registry reaches these, and it goes through the
                // selection-bound initialiser. A daemon spec is always a toggle,
                // so rather than carry a selection that may not be there, say so.
                Text(spec.title)
                    .font(GoldenFont.rowTitle)
                    .foregroundColor(GoldenTheme.textPrimary)
                GoldenMutedNote(text: "Not editable here.")
            }
            Text(spec.id)
                .font(GoldenFont.caption)
                .foregroundColor(GoldenTheme.textDisabled)
            if let detail = spec.detail {
                GoldenMutedNote(text: detail)
            }
        }
        .goldenRowSurface()
    }

    private var toggleBinding: Binding<Bool> {
        Binding(get: readOn, set: writeOn)
    }

}

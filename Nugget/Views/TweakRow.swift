import SwiftUI

/// One tweak: its title, the control its kind calls for, and its id.
///
/// Shared by the Tweaks and Daemons pages so a daemon row is not a lookalike of
/// a tweak row but literally the same view.
///
/// The toggle's read and write are injected rather than read off the selection,
/// because the two pages disagree about what "on" means: a tweak is on when its
/// flag is set, a daemon group is on when every launchd label in it has to be
/// written as disabled, and only the second one needs a value written alongside
/// the flag. Everything else -- the text field, the numeric editor -- reads and
/// writes the selection directly in both pages, so the selection is always
/// carried rather than made optional: a row whose kind happens to be `.text`
/// must not lose its editor because its toggle had a special meaning.
struct TweakRow: View {
    let spec: TweakSpec
    @Binding private var selection: TweakSelection
    private let readOn: () -> Bool
    private let writeOn: (Bool) -> Void

    init(spec: TweakSpec, selection: Binding<TweakSelection>) {
        self.init(spec: spec, selection: selection,
                  isOn: nil, setOn: nil)
    }

    /// The daemon shape: same row, but the page decides what the switch means.
    init(spec: TweakSpec, selection: Binding<TweakSelection>,
         isOn: @escaping () -> Bool, setOn: @escaping (Bool) -> Void) {
        self.init(spec: spec, selection: selection,
                  isOn: isOn, setOn: setOn)
    }

    private init(spec: TweakSpec, selection: Binding<TweakSelection>,
                 isOn: (() -> Bool)?, setOn: ((Bool) -> Void)?) {
        self.spec = spec
        self._selection = selection
        self.readOn = isOn ?? { selection.wrappedValue.isOn(spec) }
        self.writeOn = setOn ?? { selection.wrappedValue.setOn($0, for: spec) }
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
            case .text:
                Text(spec.title)
                    .font(GoldenFont.rowTitle)
                    .foregroundColor(GoldenTheme.textPrimary)
                TextField("(empty = clear)", text: textBinding)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .goldenField()
            case .number:
                Text(spec.title)
                    .font(GoldenFont.rowTitle)
                    .foregroundColor(GoldenTheme.textPrimary)
                TweakNumberField(spec: spec, selection: $selection)
                GoldenMutedNote(text: spec.numberHint)
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

    private var textBinding: Binding<String> {
        Binding(get: {
            if case .string(let value) = selection.value(for: spec) { return value }
            return selection.value(for: spec).display
        }, set: { selection.setValue(.string($0), for: spec) })
    }
}

/// A numeric editor that keeps its own draft text.
///
/// Binding the field straight to the selection would fight the user: the value
/// is clamped and re-typed on every keystroke, so an intermediate `""` or `1`
/// would snap the field back mid-edit.  The draft holds what was typed, the
/// selection holds what is valid, and committing on submit shows the latter.
struct TweakNumberField: View {
    let spec: TweakSpec
    @Binding var selection: TweakSelection
    @State private var draft: String

    /// The draft is seeded here, once, and never re-seeded.
    ///
    /// It used to be seeded in `onAppear` — and that assignment is a *change*
    /// like any other, so `onChange(of: draft)` read it as "the user typed this"
    /// and `setValue`, which switches the tweak on the way the reference's
    /// `toggle_enabled=True` does, switched on every number tweak whose row
    /// scrolled into view.  The page then reported 42 tweaks enabled after two
    /// switches were flipped, 38 of them Liquid Glass: 39 of the 41 value-shaped
    /// Liquid Glass specs are numbers, and the row that had not been scrolled to
    /// yet was the difference.  The count grew as the user scrolled, which is
    /// why it was the number on the way *out* that looked wrong.
    ///
    /// A flag set in the same `onAppear` cannot guard this, because `onChange`
    /// runs in the update *after* it, when the flag is already set.  The only
    /// way to keep the seed out of `onChange` is to not make it a change at all.
    init(spec: TweakSpec, selection: Binding<TweakSelection>) {
        self.spec = spec
        self._selection = selection
        self._draft = State(initialValue: selection.wrappedValue.value(for: spec).display)
    }

    var body: some View {
        TextField("value", text: $draft)
            .keyboardType(.decimalPad)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .goldenField()
            .onChange(of: draft) { newValue in
                if let value = spec.numberValue(from: newValue) {
                    selection.setValue(value, for: spec)
                }
            }
            .onSubmit { draft = selection.value(for: spec).display }
    }
}

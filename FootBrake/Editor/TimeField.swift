import FootBrakeCore
import SwiftUI

/// Editable `m:ss.mmm` time. Invalid input reverts to the current value.
struct TimeField: View {
    let title: String
    let value: Double
    /// Applies a typed time and returns the value actually used (after clamping).
    let commit: (Double) -> Double

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(title, text: $text)
            .keyboardType(.numbersAndPunctuation)
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .focused($focused)
            .submitLabel(.done)
            .onSubmit(apply)
            .onChange(of: focused) { isFocused in
                if isFocused {
                    // Select the whole time so typing replaces it.
                    DispatchQueue.main.async {
                        UIApplication.shared.sendAction(#selector(UIResponder.selectAll(_:)), to: nil, from: nil, for: nil)
                    }
                } else {
                    apply()
                }
            }
            .onChange(of: value) { newValue in
                if !focused { text = Format.duration(newValue) }
            }
            .onAppear { text = Format.duration(value) }
    }

    /// Runs on Return and again when focus is lost. `value` may still be the
    /// pre-edit value here (the parent hasn't re-rendered yet), so the text is
    /// set from what `commit` applied, which makes the second call a no-op.
    private func apply() {
        if let seconds = Format.parseDuration(text) {
            text = Format.duration(commit(seconds))
        } else {
            text = Format.duration(value)
        }
    }
}

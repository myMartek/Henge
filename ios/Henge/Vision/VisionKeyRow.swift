// SPDX-License-Identifier: GPL-2.0-or-later
#if os(visionOS)
import SwiftUI

/// The keys visionOS's keyboard lacks, under the window: plain system buttons, which a Vision Pro can tell apart when
/// one looks at them. More of them than make a sensible row, so they come in sets to switch between. After Everdesk's
/// key row; on iOS these keys sit above the on-screen keyboard instead (ModifierRow), a place visionOS does not have.
struct VisionKeyRow: View {
    private enum KeySet: String, CaseIterable, Identifiable {
        case main, function, navigation

        var id: Self { self }

        var title: String {
            switch self {
            case .main: "Main keys"
            case .function: "F1–F12"
            case .navigation: "Navigation"
            }
        }

        var symbol: String {
            switch self {
            case .main: "command"
            case .function: "fn"
            case .navigation: "arrow.up.to.line"
            }
        }

        var keys: [Key] {
            switch self {
            case .main: [Key("←", 105, repeats: true), Key("↑", 103, repeats: true), Key("↓", 108, repeats: true), Key("→", 106, repeats: true)]
            case .function:
                VisionKeyRow.functionKeys
            case .navigation:
                [Key("↖", 102), Key("↘", 107), Key("⇞", 104, repeats: true), Key("⇟", 109, repeats: true),
                 Key("⌦", 111, repeats: true), Key("⌫", Keys.backspace, repeats: true), Key("⏎", 28), Key("⇪", 58)]
            }
        }
    }

    /// Linux input codes: F1 to F10 are 59 to 68, F11 and F12 are 87 and 88.
    private static let functionKeys: [Key] = {
        var keys: [Key] = []
        for number in 1...12 {
            let code: UInt16 = number <= 10 ? UInt16(58 + number) : UInt16(76 + number)
            keys.append(Key("F\(number)", code))
        }
        return keys
    }()

    private struct Key: Hashable {
        let label: String
        let code: UInt16
        var repeats = false

        init(_ label: String, _ code: UInt16, repeats: Bool = false) {
            self.label = label
            self.code = code
            self.repeats = repeats
        }
    }

    @ObservedObject private var sticky = StickyKeys.shared
    @AppStorage("henge.vision.keySet") private var keySet = KeySet.main

    var body: some View {
        HStack(spacing: 6) {
            Picker("Keys", selection: $keySet) {
                ForEach(KeySet.allCases) { set in
                    Label(set.title, systemImage: set.symbol).tag(set)
                }
            }
            .pickerStyle(.menu)
            if keySet == .main {
                key(Key("esc", Keys.escape))
                key(Key("⇥", Keys.tab))
                modifier("⇧", Keys.shift, "Shift")
                modifier("⌃", Keys.control, "Control")
                modifier("⌥", Keys.option, "Option")
                modifier("⌘", Keys.command, "Command")
            }
            ForEach(keySet.keys, id: \.self, content: key)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
    }

    /// One press, with whatever modifiers are held for it, which it lets go of.
    private func key(_ key: Key) -> some View {
        Button(key.label) {
            Keys.press(key.code)
            StickyKeys.shared.releaseAll()
        }
        .buttonRepeatBehavior(key.repeats ? .enabled : .disabled)
    }

    /// Held until the next key or click, and showing that it is.
    private func modifier(_ label: String, _ code: UInt16, _ name: String) -> some View {
        Button(label) { sticky.toggle(code) }
            .tint(sticky.down.contains(code) ? Desk.accent : nil)
            .accessibilityLabel(name)
    }
}
#endif

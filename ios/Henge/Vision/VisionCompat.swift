// SPDX-License-Identifier: GPL-2.0-or-later
// visionOS spike: what the iOS app expects from UIKit and visionOS does not have, in one place, so the
// shared sources stay as they are on iOS.
#if os(visionOS)
import SwiftUI
import UIKit

/// visionOS has no screen: an app has windows, as large as the person makes them. The app asks the screen
/// for two things, the shape a new Mac's display should have and the width of its key rows, so this stands
/// in with a 16:9 display (1920×1080 points at 2x, a 4K Mac in Retina mode). It shadows UIKit's UIScreen,
/// which is marked unavailable here.
final class UIScreen {
    static let main = UIScreen()
    var bounds: CGRect { CGRect(x: 0, y: 0, width: 1920, height: 1080) }
    var nativeBounds: CGRect { CGRect(x: 0, y: 0, width: 3840, height: 2160) }
    var scale: CGFloat { 2 }
}

/// The screens a Mac can be given on visionOS, where a window can be any shape: the usual one and wider ones. More
/// pixels are more for the emulated Mac to draw, so the big ones cost speed.
enum VisionScreen {
    struct Choice: Hashable {
        let width: Int, height: Int
        let title: String
        var tag: String { "\(width)x\(height)" }
    }

    static let all = [
        Choice(width: 1920, height: 1080, title: "16:9 (1920 × 1080)"),
        Choice(width: 2560, height: 1440, title: "16:9, larger (2560 × 1440)"),
        Choice(width: 2560, height: 1080, title: "21:9 ultrawide (2560 × 1080)"),
        Choice(width: 3440, height: 1440, title: "21:9 ultrawide, larger (3440 × 1440)"),
        Choice(width: 3840, height: 1080, title: "32:9 super ultrawide (3840 × 1080)"),
    ]

    static func tag(width: Int, height: Int) -> String { "\(width)x\(height)" }
    static func choice(_ tag: String) -> Choice? { all.first { $0.tag == tag } }
}

/// No Taptic Engine in a headset: the app's taps are silent here.
final class UIImpactFeedbackGenerator {
    enum FeedbackStyle { case light, medium, heavy, soft, rigid }
    init(style: FeedbackStyle) {}
    func prepare() {}
    func impactOccurred() {}
    func impactOccurred(intensity: CGFloat) {}
}

/// The volume buttons as mouse buttons (VolumeClicks.swift) have no counterpart on a Vision Pro, whose two
/// buttons belong to the system. The settings they share with the trackpad stay, so the window's own
/// tap-to-click (the "touchscreen" mode) is what runs.
final class VolumeClicks: NSObject {
    enum InputMode: String, CaseIterable { case touchscreen, volumeButtons }
    enum Mode: String, CaseIterable { case delayHold, tapThenDrag, intercept }
    static let inputModeKey = "henge.trackpad.inputMode"
    static let modeKey = "henge.trackpad.volumeMode"
    static let swapKey = "henge.trackpad.swapButtons"
    static let shared = VolumeClicks()
    static var inputMode: InputMode { .touchscreen }
    func start() {}
    func stop() {}
    func releaseButtons() {}
}

/// The camera-button interception that goes with them: nothing to show.
struct CaptureInteractionView: View {
    var body: some View { EmptyView() }
}
#endif

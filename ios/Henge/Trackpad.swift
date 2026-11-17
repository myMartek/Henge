import SwiftUI
import UIKit

/// A surface that works like a Mac's trackpad — it is one: the engine presents it on
/// the Mac's USB bus as a Magic Trackpad 2, so the Mac's own multitouch engine sees
/// the fingers: two scroll, three swipe between Spaces and to Mission Control, four
/// show the session's hidden controls.
///
/// Clicking depends on the input mode (Settings > Trackpad):
///  - Touchscreen: the surface itself clicks. A quick tap is a left click, a quick
///    two-finger tap is a right click, and touching then holding presses the button
///    down so moving drags. These go out as mouse buttons alongside the pad's fingers.
///  - Volume buttons: the surface only points and gestures; the clicks live on the
///    volume keys (VolumeClicks), so a tap here does nothing.
/// Only fingers count: a real trackpad or mouse goes through HardwareMouse.
struct Trackpad: UIViewRepresentable {
    /// Four fingers tapped together: the session shows its hidden controls.
    static let revealTap = Notification.Name("henge.trackpad.revealTap")

    /// visionOS: where the Mac's screen is on this surface, and its size in the Mac's pixels, for taking the Mac's
    /// pointer to where the system's is (VisionPointer). Empty for a surface that is only a pad.
    var macRect = CGRect.zero
    var macPixels = CGSize.zero
    /// visionOS: the shape the window should have, so that the Mac's screen fills it (0: leave the window alone).
    var windowAspect: CGFloat = 0

    func makeUIView(context: Context) -> Surface { Surface() }
    func updateUIView(_ view: Surface, context: Context) {
        view.macRect = macRect
        view.macPixels = macPixels
        #if os(visionOS)
        view.windowAspect = windowAspect
        #endif
    }

    final class Surface: UIView, UIPointerInteractionDelegate {
        /// The emulated pad's sensor, in the Magic Trackpad 2's own units.
        private static let sensorW: Int32 = 8134
        private static let sensorH: Int32 = 5206
        private static let holdTime: TimeInterval = 0.4
        private static let tapTime: TimeInterval = 0.3
        private static let tapDistance: CGFloat = 8

        private struct Finger { var touch: UITouch; var id: Int32 }

        private var fingers: [Finger] = []
        private var freeIds = Set<Int32>(1...5) /* a touch screen reports five fingers at most */
        private var started = Date()
        private var travelled: CGFloat = 0
        private var mostFingers = 0
        private var touchesLogged = 0

        /* Touchscreen-mode clicking. */
        private var holding = false
        private var holdTimer: Timer?
        private let buzz = UIImpactFeedbackGenerator(style: .medium)
        private var tapsClick: Bool { VolumeClicks.inputMode == .touchscreen }

        var macRect = CGRect.zero
        var macPixels = CGSize.zero

        override init(frame: CGRect) {
            super.init(frame: frame)
            isMultipleTouchEnabled = true
            backgroundColor = .clear
            addInteraction(UIPointerInteraction(delegate: self))
            #if os(visionOS)
            addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(pointerHovered)))
            // A hover stops while a button is down: this follows the pointer through a drag. The buttons themselves
            // come from the mouse (HardwareMouse), so this only says where.
            let press = UILongPressGestureRecognizer(target: self, action: #selector(pointerPressed))
            press.minimumPressDuration = 0
            press.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
            press.cancelsTouchesInView = false
            addGestureRecognizer(press)
            #endif
        }

        #if os(visionOS)
        /// Where the system pointer was last seen hovering, in this view.
        private var hoverAt: CGPoint?
        /// A press in progress: where it began as the press says, and where the pointer was as the hover said.
        private var press: (began: CGPoint, pointer: CGPoint)?
        private var pressesLogged = 0
        /// The Mac's pointer to the spot of the Mac's screen that is at `p` in this view.
        private func aim(_ p: CGPoint) {
            guard macRect.width > 1, macRect.height > 1, macPixels.width > 1 else { return }
            let unit = CGPoint(x: min(max((p.x - macRect.minX) / macRect.width, 0), 1),
                               y: min(max((p.y - macRect.minY) / macRect.height, 0), 1))
            VisionPointer.shared.aim(at: CGPoint(x: unit.x * (macPixels.width - 1), y: unit.y * (macPixels.height - 1)), unit: unit,
                                     screen: macPixels)
        }

        /// The system pointer over this surface: the Mac's pointer goes to the same spot of the Mac's screen.
        @objc private func pointerHovered(_ gesture: UIHoverGestureRecognizer) {
            switch gesture.state {
            case .began, .changed:
                let p = gesture.location(in: self)
                hovers &+= 1
                hoverAt = p
                aim(p)
            case .ended, .cancelled:
                pinToEdge(gesture.location(in: self))
                VisionPointer.shared.leave()
            default: break
            }
        }

        /// How near an edge the system pointer has to leave for the Mac's pointer to go all the way to it, and how
        /// near a corner for the corner, in points.
        private static let edgeReach: CGFloat = 20, cornerReach: CGFloat = 34
        private var hovers: UInt = 0

        /// The system pointer left the Mac's screen at `p`: the Mac's pointer goes on to the edge it left by, as a
        /// pointer stops at the edge of a real screen. A visionOS window has round corners, and the hover ends at
        /// the curve, well short of the picture's corner: left as it was, the Mac's pointer never got into a corner
        /// (the Apple menu, hot corners), nor quite to an edge when moved fast.
        private func pinToEdge(_ p: CGPoint) {
            guard macRect.width > 1, macRect.height > 1 else { return }
            let last = hoverAt ?? p
            // Where it left: what the gesture says if that is on or past an edge, else where it was last seen.
            var q = macRect.insetBy(dx: 1, dy: 1).contains(p) ? last : p
            let left = q.x - macRect.minX, right = macRect.maxX - q.x, top = q.y - macRect.minY, bottom = macRect.maxY - q.y
            let nearX = min(left, right), nearY = min(top, bottom)
            let reach = max(nearX, nearY) < Self.cornerReach ? Self.cornerReach : Self.edgeReach
            guard min(nearX, nearY) < reach else { return }
            if nearX < reach { q.x = left < right ? macRect.minX : macRect.maxX }
            if nearY < reach { q.y = top < bottom ? macRect.minY : macRect.maxY }
            // Not if it left because a button went down (a hover ends then too): a click near an edge stays where it is.
            hovers &+= 1
            let hover = hovers
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [self] in
                guard hover == hovers, press == nil, !VisionPointer.shared.holdsButton else { return }
                hoverAt = q
                aim(q)
                VisionPointer.shared.leave()
            }
        }

        /// A button is down on this surface. Only how far the pointer moves is taken from the press, not where it
        /// is: a click made the Mac's pointer jump a few centimetres, and the press's own idea of its place is the
        /// one thing a click and a hover do not share. The first few say both places in the log.
        @objc private func pointerPressed(_ gesture: UILongPressGestureRecognizer) {
            let p = gesture.location(in: self)
            switch gesture.state {
            case .began:
                VisionPointer.shared.stay()
                press = (p, hoverAt ?? p)
                if pressesLogged < 6 {
                    pressesLogged += 1
                    HengeLog.log("input", String(format: "pointer: press at %.0f, %.0f; the hover was at %.0f, %.0f", p.x, p.y,
                                                 hoverAt?.x ?? -1, hoverAt?.y ?? -1))
                }
                if hoverAt == nil { aim(p) } // no hover has said: the press is all there is
            case .changed:
                guard let press else { return }
                let q = CGPoint(x: press.pointer.x + p.x - press.began.x, y: press.pointer.y + p.y - press.began.y)
                hoverAt = q
                aim(q)
            default:
                press = nil
            }
        }

        /// The shape the window should have (the Mac's screen, so nothing is left black beside it). Its width stays.
        var windowAspect: CGFloat = 0 {
            didSet { if abs(windowAspect - oldValue) > 0.005 { fitWindow() } }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            fitWindow()
        }

        override func willMove(toWindow newWindow: UIWindow?) {
            super.willMove(toWindow: newWindow)
            // The session is over: the window is anyone's shape again.
            if newWindow == nil, windowAspect > 0, let scene = window?.windowScene {
                scene.requestGeometryUpdate(.Vision(resizingRestrictions: .freeform))
            }
        }

        private func fitWindow() {
            guard windowAspect > 0.2, let window, let scene = window.windowScene, window.bounds.width > 100 else { return }
            let size = CGSize(width: window.bounds.width, height: (window.bounds.width / windowAspect).rounded())
            HengeLog.log("display", "window to \(Int(size.width)) x \(Int(size.height)) for the Mac's screen")
            scene.requestGeometryUpdate(.Vision(size: size, resizingRestrictions: .uniform)) { error in
                HengeLog.log("display", "window size refused: \(error.localizedDescription)")
            }
        }
        #endif

        /// Over the Mac there is only the Mac's pointer, if iPadOS hasn't locked its own away.
        func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? { .hidden() }

        required init?(coder: NSCoder) { fatalError("made in code") }

        /// Where the finger is on the pad's sensor, in its units.
        private func sensor(_ t: UITouch) -> (Int32, Int32) {
            let p = t.location(in: self)
            // One scale for both axes. The view and the pad's sensor are different
            // shapes, so stretching the view to fill the sensor would make a finger
            // move the pointer further on one axis than the other. Map the view to a
            // centred part of the sensor at a single scale instead.
            let w = max(Double(bounds.width), 1), h = max(Double(bounds.height), 1)
            let scale = min(Double(Self.sensorW) / w, Double(Self.sensorH) / h)
            let x = (Double(p.x) - w / 2) * scale + Double(Self.sensorW) / 2
            let y = (Double(p.y) - h / 2) * scale + Double(Self.sensorH) / 2
            return (Int32(min(max(x, 0), Double(Self.sensorW))),
                    Int32(min(max(y, 0), Double(Self.sensorH))))
        }

        /* A touch sample's own clock, in ms. The guest derives finger speed from the
           timestamp deltas, so reports must carry the sample time, not the moment we
           process the event -- otherwise a burst of samples reads as one enormous flick
           and scroll inertia goes wild on release. */
        private static func ms(_ t: TimeInterval) -> UInt32 { UInt32(truncatingIfNeeded: Int(t * 1000)) }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            let touches = touches.filter { $0.type != .indirectPointer }
            guard !touches.isEmpty else { return }
            if fingers.isEmpty {
                started = Date()
                travelled = 0
                mostFingers = 0
                if tapsClick { buzz.prepare() }
            }
            for t in touches {
                guard let id = freeIds.min() else { break }
                freeIds.remove(id)
                fingers.append(Finger(touch: t, id: id))
                let (x, y) = sensor(t)
                henge_vm_touch(id, 0, x, y, Self.ms(t.timestamp))
                if touchesLogged < 12 {
                    touchesLogged += 1
                    HengeLog.log("input", "trackpad: finger \(id) down at \(x),\(y)")
                    #if os(visionOS)
                    VisionPointer.shared.logFinger("down")
                    #endif
                }
            }
            mostFingers = max(mostFingers, fingers.count)
            guard tapsClick else { return }
            if fingers.count >= 2 {
                cancelHold()
                if holding { /* a drag becomes a multi-finger gesture */
                    holding = false
                    mouseButton(0, false)
                }
            } else {
                armHold()
            }
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            var moved = false
            let ts = Self.ms(event?.timestamp ?? touches.first?.timestamp ?? 0)
            for t in touches where t.type != .indirectPointer {
                guard let i = fingers.firstIndex(where: { $0.touch == t }) else { continue }
                let now = t.location(in: self), before = t.previousLocation(in: self)
                travelled += abs(now.x - before.x) + abs(now.y - before.y)
                let (x, y) = sensor(t)
                henge_vm_touch(fingers[i].id, 1, x, y, ts)
                moved = true
            }
            /* Moving means pointing or a gesture, not a tap or a press-to-drag. */
            if tapsClick && travelled >= Self.tapDistance && !holding { cancelHold() }
            /* One frame with every finger that moved, so the guest sees a gesture's
               fingers move together rather than one at a time. */
            if moved { henge_vm_touch_frame(ts) }
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { lift(touches) }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { lift(touches) }

        private func lift(_ touches: Set<UITouch>) {
            var lifted: [Int32] = []
            fingers.removeAll { finger in
                guard touches.contains(finger.touch), finger.touch.type != .indirectPointer else { return false }
                freeIds.insert(finger.id)
                lifted.append(finger.id)
                return true
            }
            guard !lifted.isEmpty else { return }
            let ts = Self.ms(touches.map(\.timestamp).max() ?? 0)
            for id in lifted { henge_vm_touch(id, 2, 0, 0, ts) }
            guard fingers.isEmpty else { return } /* fingers still down: the gesture goes on */
            /* The whole gesture is over. */
            if tapsClick {
                cancelHold()
                let quick = Date().timeIntervalSince(started) < Self.tapTime
                let still = travelled < Self.tapDistance
                if holding {
                    holding = false
                    mouseButton(0, false) /* let go of the drag */
                } else if quick && still {
                    if mostFingers == 1 { click(0) }      /* a tap is a left click */
                    else if mostFingers == 2 { click(1) } /* a two-finger tap is a right click */
                }
            }
            if mostFingers >= 4, travelled < Self.tapDistance * 3, Date().timeIntervalSince(started) < Self.tapTime * 2 {
                NotificationCenter.default.post(name: Trackpad.revealTap, object: nil)
            }
            StickyKeys.shared.releaseAll()
        }

        /// A brief press of a mouse button: down then up.
        /// A mouse button for a tap or a hold, where the Mac's pointer is.
        private func mouseButton(_ button: Int32, _ down: Bool) {
            #if os(visionOS)
            VisionPointer.shared.buttonHere(button, down: down) // not the virtio mouse's: VisionPointer says why
            #else
            henge_vm_mouse_button(button, down ? 1 : 0)
            #endif
        }

        private func click(_ button: Int32) {
            mouseButton(button, true)
            mouseButton(button, false)
            buzz.impactOccurred()
        }

        /// A finger that stays put presses the left button down, so moving it drags.
        private func armHold() {
            cancelHold()
            let timer = Timer(timeInterval: Self.holdTime, repeats: false) { [weak self] _ in
                guard let self, self.fingers.count == 1, self.travelled < Self.tapDistance else { return }
                self.holding = true
                self.mouseButton(0, true)
                self.buzz.impactOccurred()
            }
            RunLoop.main.add(timer, forMode: .common)
            holdTimer = timer
        }

        private func cancelHold() {
            holdTimer?.invalidate()
            holdTimer = nil
        }
    }
}

/// One mouse button you can hold: down when touched, up when let go.
struct MouseButton: View {
    let title: String
    let button: Int32
    @State private var down = false

    var body: some View {
        Text(title)
            .font(.system(size: 15))
            .foregroundStyle(down ? Desk.text : Desk.dim)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(down ? Desk.raised : Color.clear)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !down else { return }
                        down = true
                        henge_vm_mouse_button(button, 1)
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                    .onEnded { _ in
                        down = false
                        henge_vm_mouse_button(button, 0)
                        StickyKeys.shared.releaseAll()
                    }
            )
            .accessibilityLabel(title)
    }
}
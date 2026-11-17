// SPDX-License-Identifier: GPL-2.0-or-later
#if os(visionOS)
import QuartzCore
import UIKit

/// One pointer on visionOS: the Mac's follows the system's.
///
/// iPadOS locks its pointer away while a Mac runs, and the mouse's raw motion (GameController) moves the Mac's alone.
/// visionOS does not lock it. Moved by raw motion, the Mac's pointer went one way at macOS's speed while the system's
/// went on at its own, out of the window and onto the tab bar or the controls under it: two pointers, in two places.
/// So here the system's pointer leads, as in Everdesk: where it hovers over the Mac's screen is where the Mac's
/// pointer is taken, and a click, a wheel turn or a key counts only while it is there.
///
/// The Mac is told where its pointer is through a USB pointer that reports positions (HV_USB_POINTER, devices/xhci.c):
/// exact, and at once. Until macOS has set that device up, or where there is none, the Mac has only its relative
/// mouse, whose reports macOS accelerates, and this closes the loop instead: each frame it reads where the Mac's
/// pointer is and sends a step toward the target. That lags behind a moving pointer, which is why it is only the
/// fallback.
final class VisionPointer: NSObject {
    static let shared = VisionPointer()

    /// The system pointer has been seen over the Mac in this session: it leads from now on, and raw motion is left out.
    private(set) var tracks = false
    /// It is over the Mac's screen right now. For a moment after it left as well: pressing a button ends the hover
    /// that says it is there, and the press comes from the mouse on its own, in no fixed order.
    var isOverMac: Bool { over || CACurrentMediaTime() - leftAt < 0.25 }
    private var over = false
    private var leftAt: CFTimeInterval = 0

    private var target = CGPoint.zero
    private var aimsLogged = 0

    /// The screen the Mac was started with, in pixels (the one real mode its display has: SessionView says).
    var started = CGSize.zero
    private var screen = CGSize.zero
    private var lastUnit = CGPoint.zero
    private var aims: UInt = 0
    private var clicks: UInt = 0
    private var clicksLogged = 0
    private var dragsLogged = 0
    private var link: CADisplayLink?
    private var stillFrames = 0
    /// Clicks that wait for the Mac's pointer to arrive, in order, and when they stop waiting.
    private var waiting: [() -> Void] = []
    private var waitingSince: CFTimeInterval = 0

    /// The Mac takes positions (its USB pointer is set up): nothing to follow, and nothing to wait for.
    private(set) var exact = false

    /// Where the system pointer is: in the Mac's pixels, and as 0...1 of its screen, whose size in pixels is `screen`.
    func aim(at point: CGPoint, unit: CGPoint, screen: CGSize) {
        tracks = true
        over = true
        target = point
        lastUnit = unit
        aims &+= 1
        lastAim = CACurrentMediaTime()
        if screen != self.screen {
            self.screen = screen
            clicksLogged = 0
            dragsLogged = 0
            HengeLog.log("input", String(format: "pointer: the Mac's screen is %.0f x %.0f (started as %.0f x %.0f)",
                                         screen.width, screen.height, started.width, started.height))
        }
        let was = exact
        exact = place()
        if exact != was { HengeLog.log("input", exact ? "pointer: the Mac takes positions" : "pointer: following in steps") }
        if !heldExact.isEmpty, dragsLogged < 6 {
            // Does a move with a button held land where a plain move does? Asked once the pointer rests.
            let aimed = aims, screen = screen
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [self] in
                var x: Int32 = 0, y: Int32 = 0
                guard aimed == aims, !heldExact.isEmpty, dragsLogged < 6, henge_vm_pointer(&x, &y) == 0 else { return }
                dragsLogged += 1
                HengeLog.log("input", String(format: "pointer: drag meant for %.0f, %.0f is at %d, %d", unit.x * (screen.width - 1),
                                             unit.y * (screen.height - 1), x, y))
            }
        }
        if aimsLogged < 6 {
            aimsLogged += 1
            HengeLog.log("input", String(format: "pointer: at %.3f, %.3f of the Mac's screen", unit.x, unit.y))
        }
        if exact {
            flush()
        } else {
            run()
        }
    }

    /// The system pointer left the Mac's screen.
    func leave() {
        guard over else { return }
        over = false
        leftAt = CACurrentMediaTime()
    }

    /// A press arrived at the Mac's screen: the pointer is there, whatever the hover said last.
    func stay() {
        guard tracks else { return }
        over = true
    }

    /// Buttons held through the Mac's USB pointer: each is let go the way it went down, whatever leads by then.
    private var heldExact: Set<Int32> = []
    /// A mouse button is down.
    var holdsButton: Bool { !heldExact.isEmpty }

    /// A mouse button (0 left, 1 right, 2 middle). Through the USB pointer while it leads, where the Mac's pointer
    /// is: a button over the virtio mouse then made the Mac's pointer jump (devices/xhci.c says what was seen).
    func button(_ button: Int32, down: Bool) {
        if down {
            heldExact.insert(button)
            if exact, press(button, down: true) {
                measureClick(pressed: true)
            } else {
                heldExact.remove(button)
                henge_vm_mouse_button(button, 1)
            }
        } else if heldExact.remove(button) != nil {
            _ = press(button, down: false)
            measureClick(pressed: false)
        } else {
            henge_vm_mouse_button(button, 0)
        }
    }

    /// A mouse button for the pointer where the Mac has it, not where the system's is: a finger on the screen, used
    /// as a trackpad, moved it there and now taps or holds. The button goes through the USB pointer with the place
    /// the Mac reports for its pointer, which is the place it is drawn at. Not over the virtio mouse: with a USB
    /// pointer in the Mac, a button from that mouse moved the Mac's pointer at the press and again at the release,
    /// so a tap clicked somewhere else and dragged (seen with the mouse first, then with taps, which still went
    /// that way).
    func buttonHere(_ button: Int32, down: Bool) {
        if !down, !heldExact.contains(button) { return henge_vm_mouse_button(button, 0) }
        var x: Int32 = 0, y: Int32 = 0, w: Int32 = 0, h: Int32 = 0
        guard henge_vm_pointer(&x, &y) == 0, henge_vm_display_size(&w, &h) == 0, w > 1, h > 1 else {
            // The Mac has not said where its pointer is: nothing to place a report by.
            if heldExact.remove(button) != nil { _ = henge_vm_pointer_button(button, 0) } else { henge_vm_mouse_button(button, down ? 1 : 0) }
            return
        }
        lastUnit = CGPoint(x: CGFloat(x) / CGFloat(w - 1), y: CGFloat(y) / CGFloat(h - 1))
        if down { heldExact.insert(button) } else { heldExact.remove(button) }
        let taken = press(button, down: down)
        if !taken {
            heldExact.remove(button)
            henge_vm_mouse_button(button, down ? 1 : 0)
        }
        if fingersLogged < 16 {
            fingersLogged += 1
            HengeLog.log("input", "pointer: \(down ? "press" : "release") by a finger at \(x), \(y) of \(w) x \(h), \(taken ? "as a position" : "over the mouse")")
        }
    }

    /// A finger came down on the Mac's screen: where the Mac's pointer is, and how long ago the system's pointer
    /// last said where it is (if a pinch does that too, the Mac's pointer goes to where the eyes are).
    func logFinger(_ what: String) {
        var x: Int32 = -1, y: Int32 = -1
        _ = henge_vm_pointer(&x, &y)
        HengeLog.log("input", String(format: "pointer: finger %@, the Mac's pointer is at %d, %d; the system's pointer spoke %.0f ms ago",
                                     what, x, y, lastAim > 0 ? (CACurrentMediaTime() - lastAim) * 1000 : -1))
    }
    private var fingersLogged = 0
    private var lastAim: CFTimeInterval = 0

    /// Where the system's pointer is, as the USB pointer says it: 0...32767 of the Mac's screen.
    private var wire: (x: Int32, y: Int32) {
        (Int32((min(max(lastUnit.x, 0), 1) * 32767).rounded()), Int32((min(max(lastUnit.y, 0), 1) * 32767).rounded()))
    }

    /// The Mac's pointer to where the system's is. False if the Mac takes no positions.
    private func place() -> Bool {
        let at = wire
        return henge_vm_pointer_at(at.x, at.y) == 0
    }

    /// The button's change through the USB pointer, in one report with where the pointer is.
    private func press(_ button: Int32, down: Bool) -> Bool {
        let at = wire
        return henge_vm_pointer_button_at(button, down ? 1 : 0, at.x, at.y) == 0
    }

    /// After a button changed: where is the Mac's pointer? Only said in the log, for the first few. (A build
    /// corrected clicks by this in resolutions other than the Mac's first, where the two differed by the ratio of
    /// the resolutions. Wrongly: the Mac had the click where it was sent, and it was the place it reports for its
    /// pointer that counted on the first resolution. host/vm.c scales that now, and so does what draws the pointer.)
    private func measureClick(pressed: Bool) {
        guard clicksLogged < 16 else { return }
        clicks &+= 1
        let click = clicks, aimed = aims, unit = lastUnit, screen = screen
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.07) { [self] in
            guard click == clicks, aimed == aims, screen.width > 1 else { return } // a button or the pointer moved since
            var x: Int32 = 0, y: Int32 = 0
            guard henge_vm_pointer(&x, &y) == 0 else { return }
            clicksLogged += 1
            HengeLog.log("input", String(format: "pointer: %@ meant for %.0f, %.0f, the Mac's pointer is at %d, %d",
                                         pressed ? "press" : "release", unit.x * (screen.width - 1), unit.y * (screen.height - 1), x, y))
        }
    }

    /// A turn of the wheel, up and down. True if the USB pointer took it.
    func wheel(_ amount: Int32) -> Bool {
        exact && henge_vm_pointer_wheel(amount) == 0
    }

    /// The session ended.
    func reset() {
        for button in heldExact { _ = henge_vm_pointer_button(button, 0) }
        heldExact.removeAll()
        tracks = false
        over = false
        leftAt = 0
        exact = false
        screen = .zero
        flush()
        link?.invalidate()
        link = nil
    }

    /// Whether raw mouse motion should be left out: the system pointer leads and the Mac says where its own is.
    var leads: Bool {
        guard tracks else { return false }
        if exact { return true }
        var x: Int32 = 0, y: Int32 = 0
        return henge_vm_pointer(&x, &y) == 0
    }

    /// Runs `work` (a button going down or up) once the Mac's pointer is where the system's is, or after a quarter of
    /// a second: a click right after a fast move would otherwise land where the Mac's pointer still was.
    func whenThere(_ work: @escaping () -> Void) {
        if exact, waiting.isEmpty { return work() }
        if waiting.isEmpty, distance().map({ $0 < 4 }) ?? true { return work() }
        if waiting.isEmpty { waitingSince = CACurrentMediaTime() }
        waiting.append(work)
        run()
    }

    private func run() {
        stillFrames = 0
        guard link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(step))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private func flush() {
        let work = waiting
        waiting.removeAll()
        work.forEach { $0() }
    }

    /// How far the Mac's pointer is from the target, in its pixels; nil while macOS has not said where it is.
    private func distance() -> Int32? {
        var x: Int32 = 0, y: Int32 = 0
        guard henge_vm_pointer(&x, &y) == 0 else { return nil }
        return max(abs(Int32(target.x.rounded()) - x), abs(Int32(target.y.rounded()) - y))
    }

    @objc private func step() {
        if exact {
            flush()
            link?.invalidate()
            link = nil
            return
        }
        var x: Int32 = 0, y: Int32 = 0
        guard henge_vm_pointer(&x, &y) == 0 else {
            flush()
            return
        }
        let dx = Int32(target.x.rounded()) - x, dy = Int32(target.y.rounded()) - y
        let far = max(abs(dx), abs(dy))
        if far < 2 {
            flush()
            stillFrames += 1
            if stillFrames > 45 { // nothing to do for half a second: stop asking every frame
                link?.invalidate()
                link = nil
            }
            return
        }
        stillFrames = 0
        if !waiting.isEmpty, far < 4 || CACurrentMediaTime() - waitingSince > 0.25 { flush() }
        // Far away a bigger step, which macOS makes bigger still; near, small ones it leaves as they are.
        let limit: Int32 = far > 240 ? 40 : 16
        func part(_ d: Int32) -> Int32 {
            guard d != 0 else { return 0 }
            let half = d / 2
            return max(-limit, min(limit, half == 0 ? (d > 0 ? 1 : -1) : half))
        }
        henge_vm_mouse_move(part(dx), part(dy))
    }
}
#endif

import SwiftUI
import GameController

/// A running Mac. Upright, its screen sits above a trackpad; on its side the screen fills the device
/// and is its own trackpad. Zoomed in, the screen fills the device either way and follows the pointer.
/// A keyboard, trackpad or mouse attached to an iPad works throughout.
struct SessionView: View {
    let mac: VirtualMac
    let close: () -> Void

    @StateObject private var display = DisplayRouter()
    @State private var error: String?
    @State private var state: Int32 = 0
    @State private var bootAttempt = 0
    @State private var cpusOn: Int32 = 0
    @State private var userCode = false
    @State private var blocksPerSecond: Double = 0
    @State private var framesOut: UInt64 = 0
    @State private var framesIn: UInt64 = 0
    @State private var log: [String] = []
    @State private var started = Date()
    @State private var thermalState = ProcessInfo.processInfo.thermalState
    @State private var bootRAM: UInt64 = 0 /* what the Mac was started with, which a save is for */
    @AppStorage("henge.cpus") private var cpus = 4
    @AppStorage("henge.matchScreenColors") private var matchScreenColors = true
    @AppStorage("henge.display.brightness") private var screenBrightness = 1.0
    @AppStorage("henge.cursor.scale") private var cursorScale = Device.isPad ? 1 : 3
    @AppStorage("henge.cursor.sharp") private var sharpCursor = true
    @AppStorage(HardwareMouse.scrollSpeedKey) private var scrollSpeed = 0.3

    /// Testing: -henge.session.typing YES opens a session with the keyboard asked for.
    @State private var typing = UserDefaults.standard.bool(forKey: "henge.session.typing")
    @State private var zoomed = false
    @State private var showDetails = false
    /// The Mac's screen as it is now, once it shows one: it can pick another resolution than it was started with,
    /// and of another shape. The view takes that shape, so that a click lands where it is made.
    @State private var guestScreen: CGSize?
    @State private var controlsHidden = false
    @State private var showRevealHint = false
    @State private var pointerRefused = false
    @AppStorage("henge.controls.hintsShown") private var revealHintsShown = 0
    @AppStorage(VolumeClicks.inputModeKey) private var inputMode = VolumeClicks.InputMode.touchscreen
    @AppStorage(VolumeClicks.modeKey) private var volumeMode = VolumeClicks.Mode.delayHold
    /// Once per install: macOS's moving wallpapers and aerial screen saver are video, decoded by the emulated
    /// CPUs (a phone ran about 30% faster with a still one).
    @AppStorage("henge.tips.stillWallpaperShown") private var stillWallpaperTipShown = false
    @State private var showWallpaperTip = false
    @State private var confirmStop = false
    /// This run was a Windows installation and ended the way one ends: Windows shut itself down.
    @State private var windowsInstalled = false
    @State private var windowsServicing = false
    /// What is being got ready before the machine starts, to say so meanwhile.
    @State private var preparing: String?
    @State private var zoomCentre = CGPoint(x: 0.5, y: 0.5) // where the zoomed view is, 0...1 of the Mac's screen
    @State private var map: UIImage?
    @State private var zoomFollowing: Task<Void, Never>?
    @State private var helperRunning = false
    @State private var shown = CGSize(width: 0.5, height: 0.5) // how much of the Mac's screen the zoomed view shows
    @Environment(\.scenePhase) private var scenePhase
    #if os(visionOS)
    @Environment(\.openWindow) private var openWindow
    #endif


    var body: some View {
        GeometryReader { geo in
            let insets = geo.safeAreaInsets
            let full = CGSize(width: geo.size.width + insets.leading + insets.trailing,
                              height: geo.size.height + insets.top + insets.bottom)
            let landscape = full.width > full.height
            let layout = Layout(full: full, insets: insets, landscape: landscape, zoomed: zoomed, typing: Self.keyboardTakesRoom && typing, centre: zoomCentre, aspect: screenAspect)
            ZStack(alignment: .topLeading) {
                (landscape || zoomed ? Color.black : Desk.page)
                // One view in every layout: it holds the layer the engine draws into.
                BootDisplay(display: display, role: .device)
                    .opacity(display.isExternal ? 0 : 1)
                    .overlay {
                        if display.isExternal && state != 2 {
                            VStack(spacing: 8) {
                                Image(systemName: "display").font(.largeTitle)
                                Text("Mac on external display").font(.headline)
                                Text("Use the trackpad, keyboard or a connected mouse.")
                                    .font(.subheadline)
                            }
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .padding()
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .frame(width: layout.screen.width, height: layout.screen.height)
                    .clipShape(RoundedRectangle(cornerRadius: layout.fillsPhone ? 0 : 15, style: .continuous))
                    .overlay {
                        if !layout.fillsPhone {
                            RoundedRectangle(cornerRadius: 15, style: .continuous).stroke(Color.white.opacity(0.16), lineWidth: 0.5)
                        }
                    }
                    .position(x: layout.screen.midX, y: layout.screen.midY)
                if state != 2 {
                    Trackpad(macRect: layout.screen.offsetBy(dx: -layout.touch.minX, dy: -layout.touch.minY),
                             macPixels: guestScreen ?? CGSize(width: mac.screen.width, height: mac.screen.height),
                             windowAspect: Self.windowFollowsMac ? screenAspect : 0)
                        .frame(width: layout.touch.width, height: layout.touch.height)
                        .position(x: layout.touch.midX, y: layout.touch.midY)
                    if inputMode == .volumeButtons && volumeMode == .intercept {
                        // The capture interaction must live in the SwiftUI hierarchy to receive
                        // the volume-button events; it passes touches through to the trackpad.
                        CaptureInteractionView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .allowsHitTesting(false)
                    }
                    if !layout.fillsPhone {
                        uprightControls(layout)
                    } else {
                        floatingControls(layout)
                    }
                    if pointerRefused && !showRevealHint {
                        Label("Make Henge full screen to use the trackpad or mouse as the Mac's", systemImage: "cursorarrow.rays")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18).padding(.vertical, 12)
                            .deskGlass(in: Capsule())
                            .position(x: full.width / 2, y: insets.top + 40)
                            .transition(.opacity)
                            .allowsHitTesting(false)
                    }
                    if showRevealHint {
                        Label("Tap with four fingers to show the controls", systemImage: "hand.tap")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18).padding(.vertical, 12)
                            .deskGlass(in: Capsule())
                            .position(x: full.width / 2, y: insets.top + 40)
                            .transition(.opacity)
                            .allowsHitTesting(false)
                    }
                    if showWallpaperTip && !showRevealHint && !pointerRefused {
                        Label("For more speed, give this Mac a still wallpaper and set its screen saver to Never in System Settings.", systemImage: "speedometer")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: min(full.width - 40, 520))
                            .padding(.horizontal, 18).padding(.vertical, 12)
                            .deskGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                            .position(x: full.width / 2, y: insets.top + 56)
                            .transition(.opacity)
                            .allowsHitTesting(false)
                    }
                }
                if state == 2 {
                    StoppedMacView(outcome: henge_vm_exit_outcome(), reason: String(cString: henge_vm_exit_reason()),
                                   start: { bootAttempt += 1 }, windows: mac.kind == "windows", installed: windowsInstalled, close: close)
                        .frame(width: min(layout.touch.width - 32, 360))
                        .position(x: layout.touch.midX, y: layout.fillsPhone ? layout.touch.midY : layout.pad.midY)
                }
                if let error { errorCard(error, layout) }
                if let preparing {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(preparing).font(.subheadline).multilineTextAlignment(.center)
                    }
                    .foregroundStyle(.white)
                    .padding(24)
                    .frame(maxWidth: 380)
                    .background(Color(white: 0.10), in: RoundedRectangle(cornerRadius: 22))
                    .position(x: layout.touch.midX, y: layout.fillsPhone ? layout.touch.midY : layout.pad.midY)
                }
                KeyboardCatcher(active: $typing).frame(width: 0, height: 0)
            }
            .frame(width: full.width, height: full.height)
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 0.25), value: zoomed)
            .animation(.easeInOut(duration: 0.25), value: typing)
            .animation(.easeInOut(duration: 0.25), value: controlsHidden)
            .animation(.easeInOut(duration: 0.25), value: showRevealHint)
            .animation(.easeInOut(duration: 0.25), value: showWallpaperTip)
            .onReceive(NotificationCenter.default.publisher(for: UIPointerLockState.didChangeNotification)) { _ in
                pointerRefused = PointerLock.refused
            }
            .onReceive(NotificationCenter.default.publisher(for: .GCMouseDidConnect)) { _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { pointerRefused = PointerLock.refused }
            }
            .onReceive(NotificationCenter.default.publisher(for: Trackpad.revealTap)) { _ in
                controlsHidden = false
                showRevealHint = false
            }
            .onAppear { shown = layout.shown }
            .onChange(of: layout.shown) { shown = $0 }
        }
        .statusBarHidden(zoomed || Device.isPad)
        .persistentSystemOverlays(.hidden)
        #if os(visionOS)
        // The controls sit under the window, not over the Mac's screen: nothing of the Mac is covered, so nothing needs
        // hiding, and the four-finger tap that brings hidden controls back on a touchscreen does not exist here.
        .ornament(visibility: state != 2 ? .visible : .hidden, attachmentAnchor: .scene(.bottom), contentAlignment: .top) {
            VStack(spacing: 10) {
                visionBar
                if typing {
                    // The Mac's own keys, which visionOS's keyboard lacks and has no row above it for.
                    VisionKeyRow()
                        .padding(10)
                        .glassBackgroundEffect(in: Capsule())
                        .transition(.opacity)
                }
            }
            .padding(.top, 14)
            .animation(.easeInOut(duration: 0.2), value: typing)
        }
        #endif
        .sheet(isPresented: $showDetails) { details.deskPlainButtons() }
        .confirmationDialog("Shut down \(mac.name)?", isPresented: $confirmStop, titleVisibility: .visible) {
            #if os(visionOS)
            if mac.isWindows { Button("Ask Windows to shut down") { henge_vm_power_button() } } // its power button, not the plug
            #endif
            Button(mac.kind == "windows" ? "Turn off now" : "Shut Down", role: .destructive) { finish() }
        } message: {
            Text(mac.kind == "windows" ? "Turning it off at once loses anything not saved, and stops an installation half way."
                                       : "This turns the Mac off at once. Anything not saved on it is lost.")
        }
        .onChange(of: zoomed) { on in
            zoomFollowing?.cancel()
            zoomFollowing = on ? Task { await followPointer() } : nil
        }
        .onChange(of: pointerNeeded) { PointerLock.set(!$0) }
        .onChange(of: scenePhase) { phase in
            guard phase != .active else {
                display.refresh()
                InstantResume.cameBack(mac)
                return
            }
            HardwareKeys.releaseAll()
            HardwareMouse.shared.releaseButtons()
            VolumeClicks.shared.releaseButtons()
            if phase == .inactive { InstantResume.pause() }
            if phase == .background && bootRAM > 0 { InstantResume.suspend(mac, ramMB: bootRAM, cpus: cpus) }
        }
        .onChange(of: showDetails) { showing in
            if showing { HardwareKeys.releaseAll(); StickyKeys.shared.releaseAll() }
        }
        .onChange(of: confirmStop) { showing in
            if showing { HardwareKeys.releaseAll(); StickyKeys.shared.releaseAll() }
        }
        .onAppear {
            RunningMac.shown += 1
            UIApplication.shared.isIdleTimerDisabled = true
            HardwareMouse.shared.start()
            VolumeClicks.shared.start()
        }
        .onDisappear {
            RunningMac.shown = max(RunningMac.shown - 1, 0)
            UIApplication.shared.isIdleTimerDisabled = false
            zoomFollowing?.cancel()
            StickyKeys.shared.releaseAll()
            HardwareKeys.releaseAll()
            HardwareMouse.shared.stop()
            VolumeClicks.shared.stop()
        }
        .modifier(ExternalMacDisplayModifier(presentation: MacPresentation(display: display, aspect: mac.aspect)))
        .task(id: bootAttempt) { await run() }
        .task { await Sharing.followMacClipboard() }
    }

    /// The shape of the Mac's screen: as it is now, or as it was asked for until it shows one.
    private var screenAspect: CGFloat {
        if let guestScreen, guestScreen.height > 0 { return guestScreen.width / guestScreen.height }
        return mac.aspect
    }

    /// Whether the window takes the shape of the Mac's screen. On visionOS, where a window is just that; an iPhone's
    /// or iPad's screen has the shape it has.
    private static var windowFollowsMac: Bool {
        #if os(visionOS)
        true
        #else
        false
        #endif
    }

    /// Whether the Mac's screen makes room when the keyboard opens: under an iPhone's or iPad's keyboard, which covers
    /// the screen. visionOS's floats in the room and covers nothing, so the Mac stays as it is.
    private static var keyboardTakesRoom: Bool {
        #if os(visionOS)
        false
        #else
        true
        #endif
    }

    /// When there is something of the app's to point at, iPadOS gets its own pointer back.
    private var pointerNeeded: Bool { state == 2 || showDetails || confirmStop || error != nil }

    // MARK: Layout

    /// Where everything goes, in points from the device's top left corner.
    private struct Layout {
        let screen: CGRect
        let touch: CGRect     // what is a trackpad besides the pad itself
        let fillsPhone: Bool
        let toolsY: CGFloat
        let pad: CGRect
        let insets: EdgeInsets
        var barY: CGFloat?    // where the controls go in the space beside the screen, if it has room for them

        var shown: CGSize {
            CGSize(width: min(touch.width / max(screen.width, 1), 1), height: min(touch.height / max(screen.height, 1), 1))
        }

        init(full: CGSize, insets: EdgeInsets, landscape: Bool, zoomed: Bool, typing: Bool, centre: CGPoint, aspect: CGFloat) {
            self.insets = insets
            let big = full.height >= 600 // an iPad on its side, or a window on one
            if zoomed {
                // Upright, as tall as the device. On its side, bigger than it fits: a big screen needs less.
                let height = landscape ? full.height * (big ? 1.5 : 2) : max(full.height - insets.bottom, full.width / aspect)
                let width = height * aspect
                let x = min(0, max(full.width - width, full.width / 2 - centre.x * width))
                let y = min(0, max(full.height - height, full.height / 2 - centre.y * height))
                screen = CGRect(x: x, y: y, width: width, height: height)
                touch = CGRect(origin: .zero, size: full)
                fillsPhone = true
                toolsY = 0
                pad = .zero
            } else if landscape, big {
                // Room to keep the controls off the Mac's menu bar, and the Mac above the on-screen keyboard.
                let bar: CGFloat = 62
                let room = typing ? full.height - insets.bottom - insets.top - bar - 8 : full.height
                // An iPad keeps clear of its side insets; a big iPhone (iPhone Duo) fills edge to edge.
                let side = Device.isPad ? 2 * max(insets.leading, insets.trailing) : 0
                let height = max(min(room, (full.width - side) / aspect), 200)
                let width = height * aspect
                let y = typing ? insets.top + bar : (full.height - height) / 2
                screen = CGRect(x: (full.width - width) / 2, y: y, width: width, height: height)
                touch = CGRect(origin: .zero, size: full)
                fillsPhone = true
                toolsY = 0
                pad = .zero
                if y - insets.top >= 54 { barY = insets.top + (y - insets.top) / 2 }
            } else if landscape {
                // Edge to edge. Phones wider than the Mac fill the height with room to spare beside the
                // Dynamic Island; a squarer phone (iPhone Duo) fills all of it, island and corners included.
                let height = min(full.height, full.width / aspect)
                let width = height * aspect
                screen = CGRect(x: (full.width - width) / 2, y: (full.height - height) / 2, width: width, height: height)
                touch = CGRect(origin: .zero, size: full)
                fillsPhone = true
                toolsY = 0
                pad = .zero
            } else {
                let width = full.width - 16
                let height = width / aspect
                screen = CGRect(x: 8, y: insets.top + 6, width: width, height: height)
                touch = screen
                fillsPhone = false
                toolsY = screen.maxY + 10
                let top = typing ? screen.maxY + 8 : toolsY + 54 + 10
                let bottom = full.height - insets.bottom - (typing ? 8 : 0)
                pad = CGRect(x: 8, y: top, width: width, height: max(bottom - top, 60))
            }
        }
    }

    // MARK: Upright

    @ViewBuilder private func uprightControls(_ layout: Layout) -> some View {
        #if !os(visionOS) // there the controls are an ornament under the window (visionBar)
        if !typing && !controlsHidden {
            HStack {
                tool("eye.slash", "Hide controls") { hideControls() }
                Spacer()
                tool("keyboard", "Keyboard") { typing = true }
                Spacer()
                pasteTool
                Spacer()
                tool("plus.magnifyingglass", "Zoom in") { zoomed = true }
                Spacer()
                tool("info.circle", "Details") { showDetails = true }
                Spacer()
                tool("power", "Shut down", tint: Desk.bad) { stopTapped() }
            }
            .padding(.horizontal, 22)
            .frame(width: layout.pad.width, height: 54)
            .background(Desk.card, in: Capsule())
            .overlay(Capsule().stroke(Desk.hairline, lineWidth: 0.5))
            .position(x: layout.pad.midX, y: layout.toolsY + 27)
            .transition(.opacity)
        }
        #endif
        trackpadPanel(layout)
    }

    private func trackpadPanel(_ layout: Layout) -> some View {
        let compact = layout.pad.height < 260
        return VStack(spacing: 0) {
            ZStack {
                Trackpad()
                if compact {
                    Text("Trackpad").font(.system(size: 14)).foregroundStyle(Desk.faint).allowsHitTesting(false)
                } else {
                    VStack(spacing: 6) {
                        hint("Drag", "to move")
                        hint("Tap", "to click")
                        hint("Hold, then drag", "to grab")
                        hint("Two fingers", "to scroll")
                    }
                    .allowsHitTesting(false)
                }
            }
            Rectangle().fill(Desk.hairline).frame(height: 0.5)
            HStack(spacing: 0) {
                MouseButton(title: "Click", button: 0)
                Rectangle().fill(Desk.hairline).frame(width: 0.5)
                MouseButton(title: "Right-click", button: 1)
            }
            .frame(height: compact ? 50 : 70)
        }
        .background(Desk.card)
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).stroke(Desk.hairline, lineWidth: 0.5))
        .frame(width: layout.pad.width, height: layout.pad.height)
        .position(x: layout.pad.midX, y: layout.pad.midY)
    }

    private func hint(_ strong: String, _ rest: String) -> some View {
        (Text(strong).foregroundColor(Desk.dim).fontWeight(.semibold) + Text(" \(rest)").foregroundColor(Desk.faint))
            .font(.system(size: 15))
    }

    /// The system's paste button: iOS asks no permission for it, as it would if the app read the clipboard itself.
    private var pasteTool: some View {
        PasteButton(payloadType: String.self) { texts in
            if let text = texts.first { Sharing.paste(text) }
        }
        .labelStyle(.iconOnly)
        .buttonBorderShape(.circle)
        .tint(Desk.raised)
    }

    /// Hides the session's controls; four fingers on the screen bring them back. The first few times say so.
    private func hideControls() {
        controlsHidden = true
        typing = false
        guard revealHintsShown < 3 else { return }
        revealHintsShown += 1
        showRevealHint = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { showRevealHint = false }
    }

    private func tool(_ symbol: String, _ label: String, tint: Color = Desk.text, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(label)
    }

    // MARK: Filling the phone

    @ViewBuilder private func floatingControls(_ layout: Layout) -> some View {
        #if !os(visionOS) // there the controls are an ornament under the window (visionBar)
        let landscape = layout.touch.width > layout.touch.height
        let top = layout.insets.top + (landscape ? 8 : 6)
        let pill = HStack(spacing: 4) {
            tool("eye.slash", "Hide controls", tint: .white) { hideControls() }
            tool("keyboard", "Keyboard", tint: .white) { typing.toggle() }
            pasteTool
            tool(zoomed ? "minus.magnifyingglass" : "plus.magnifyingglass", zoomed ? "Zoom out" : "Zoom in", tint: zoomed ? Desk.accentLight : .white) { zoomed.toggle() }
            tool("info.circle", "Details", tint: .white) { showDetails = true }
            Rectangle().fill(Color.white.opacity(0.3)).frame(width: 1, height: 22).padding(.horizontal, 4)
            tool("power", "Shut down", tint: Desk.bad) { stopTapped() }
        }
        .padding(.horizontal, 8)
        .frame(height: 50)
        .deskGlass(in: Capsule())
        if controlsHidden {
            EmptyView()
        } else if let barY = layout.barY {
            pill.position(x: layout.touch.midX, y: barY)
        } else if landscape || typing {
            pill.position(x: layout.touch.midX, y: top + 25)
        } else {
            pill.position(x: layout.touch.midX, y: layout.touch.height - layout.insets.bottom - 34)
        }
        #endif
        if zoomed { zoomMap(layout) }
    }

    #if os(visionOS)
    /// The session's controls on visionOS, as an ornament under the window: keyboard, paste, zoom, details, shut down.
    private var visionBar: some View {
        HStack(spacing: 10) {
            // The rest of Henge (the Macs, a download in the Install tab, Settings) in a window of its own, beside this one.
            tool("macwindow.badge.plus", "Open a Henge window", tint: .white) { openWindow(id: RootView.windowID) }
            Rectangle().fill(Color.white.opacity(0.3)).frame(width: 1, height: 24).padding(.horizontal, 4)
            tool("keyboard", "Keyboard", tint: typing ? Desk.accentLight : .white) { typing.toggle() }
            pasteTool
            tool(zoomed ? "minus.magnifyingglass" : "plus.magnifyingglass", zoomed ? "Zoom out" : "Zoom in",
                 tint: zoomed ? Desk.accentLight : .white) { zoomed.toggle() }
            tool("info.circle", "Details", tint: .white) { showDetails = true }
            Rectangle().fill(Color.white.opacity(0.3)).frame(width: 1, height: 24).padding(.horizontal, 4)
            tool("power", "Shut down", tint: Desk.bad) { stopTapped() }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 16)
        .frame(height: 64)
        .glassBackgroundEffect(in: Capsule())
    }
    #endif

    /// The whole screen, small, with where the zoomed view is on it.
    private func zoomMap(_ layout: Layout) -> some View {
        let width: CGFloat = 112, height = width / mac.aspect
        let viewW = min(layout.touch.width / layout.screen.width, 1) * width
        let viewH = min(layout.touch.height / layout.screen.height, 1) * height
        let left = (-layout.screen.minX / layout.screen.width) * width
        let top = (-layout.screen.minY / layout.screen.height) * height
        return ZStack(alignment: .topLeading) {
            Color.black
            if let map { Image(uiImage: map).resizable() }
            RoundedRectangle(cornerRadius: 3).stroke(Color.white, lineWidth: 1.5)
                .frame(width: viewW, height: viewH)
                .offset(x: left, y: top)
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .padding(3)
        .deskGlass(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .position(x: layout.touch.width - width / 2 - 15, y: layout.insets.top + height / 2 + 20)
        .allowsHitTesting(false)
    }

    /// Keeps the pointer in view: the view moves when the pointer nears its edge.
    private func followPointer() async {
        var tick = 0
        while !Task.isCancelled {
            var x: Int32 = 0, y: Int32 = 0
            if henge_vm_pointer(&x, &y) == 0 {
                moveZoom(toward: CGPoint(x: CGFloat(x) / CGFloat(mac.screen.width), y: CGFloat(y) / CGFloat(mac.screen.height)))
            }
            if tick % 60 == 0, let image = MacPreview.capture(width: 224, height: Int(224 / mac.aspect)) { map = UIImage(cgImage: image) }
            tick += 1
            try? await Task.sleep(nanoseconds: 33_000_000)
        }
    }

    private func moveZoom(toward p: CGPoint) {
        // How much of the screen the view shows, and a margin inside that.
        let shownX = shown.width, shownY = shown.height
        let reachX = shownX * 0.3, reachY = shownY * 0.3
        var c = zoomCentre
        if p.x < c.x - reachX { c.x = p.x + reachX } else if p.x > c.x + reachX { c.x = p.x - reachX }
        if p.y < c.y - reachY { c.y = p.y + reachY } else if p.y > c.y + reachY { c.y = p.y - reachY }
        c.x = min(max(c.x, shownX / 2), 1 - shownX / 2)
        c.y = min(max(c.y, shownY / 2), 1 - shownY / 2)
        guard c != zoomCentre else { return }
        withAnimation(.linear(duration: 0.08)) { zoomCentre = c }
    }

    // MARK: Status

    private func errorCard(_ text: String, _ layout: Layout) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("This Mac could not start").font(.system(size: 17, weight: .semibold))
            Text(text).font(.system(size: 14)).foregroundStyle(Desk.dim)
            Button("Close") { close() }.font(.system(size: 15, weight: .semibold)).foregroundStyle(Desk.accentLight)
        }
        .padding(18)
        .frame(width: min(layout.touch.width, 390) - 32, alignment: .leading)
        .background(Desk.raised, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .position(x: (layout.fillsPhone ? layout.touch.midX : layout.pad.midX), y: layout.fillsPhone ? layout.touch.midY : layout.pad.midY)
    }

    private var phase: String {
        switch state {
        case 0: return error == nil ? "Starting…" : "Not started"
        case 1: return userCode ? "macOS is running" : "Booting"
        case 3: return "Finishing shutdown…"
        default: return "Stopped (\(String(cString: henge_vm_exit_reason())))"
        }
    }

    private var details: some View {
        NavigationStack {
            List {
                Section(phase) {
                    LabeledContent("CPUs on", value: "\(cpusOn) of \(cpus)")
                    LabeledContent("Temperature", value: Self.thermalLabel(thermalState))
                    LabeledContent("Translated blocks", value: String(format: "%.1f M/s", blocksPerSecond / 1e6))
                    LabeledContent("Network frames", value: "\(framesOut) out, \(framesIn) in")
                    LabeledContent("Up", value: "\(Int(Date().timeIntervalSince(started))) s")
                }
                Section("Display") {
                    Toggle("Color matching", isOn: $matchScreenColors)
                    LabeledContent("Brightness", value: "\(Int(screenBrightness * 100))%")
                    Slider(value: $screenBrightness, in: 0.4...1)
                    Text("Brightness dims only the Mac's screen.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Pointer") {
                    Picker("Size", selection: $cursorScale) {
                        Text("1×").tag(1)
                        Text("2×").tag(2)
                        Text("3×").tag(3)
                    }
                    .pickerStyle(.segmented)
                    Toggle("Sharp edges", isOn: $sharpCursor)
                    LabeledContent("Scroll speed", value: String(format: "%.1f×", scrollSpeed))
                    Slider(value: $scrollSpeed, in: 0.1...1.5)
                    Text("The Mac supplies a small pointer image. Enlarging it can look blurry; 1× is the sharpest on an iPad. Scroll speed changes apply immediately.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Sharing") {
                    LabeledContent("Clipboard and folder", value: helperRunning ? "On" : "Not set up")
                    if !helperRunning {
                        Button("Type the Set Up Command") {
                            showDetails = false
                            Task {
                                try? await Task.sleep(nanoseconds: 600_000_000)
                                await Sharing.typeSetUpCommand()
                            }
                        }
                    }
                    Text(helperRunning
                         ? "Put files in Files, Henge, Shared to see them in the Henge folder in this Mac's home folder. What you copy on the Mac is copied here too, and the paste button pastes from here into the Mac."
                         : "Once for each Mac: open Terminal on the Mac, tap this, then press Return. When macOS asks about henge-agent and local networks, choose Allow. It types \(Sharing.setUpCommand) and needs the Mac's keyboard layout to be U.S.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Lighter macOS") {
                    Button("Type the Lighter macOS Command") {
                        showDetails = false
                        Task {
                            try? await Task.sleep(nanoseconds: 600_000_000)
                            await Keys.typeSlowly(Sharing.lightenCommand)
                        }
                    }
                    Button("Type the Undo Command") {
                        showDetails = false
                        Task {
                            try? await Task.sleep(nanoseconds: 600_000_000)
                            await Keys.typeSlowly(Sharing.unlightenCommand)
                        }
                    }
                    Text("Less drawing for the emulated CPUs: window and Dock animations, desktop widgets, the screen saver and a moving wallpaper go. Open Terminal on the Mac, tap the button and press Return, then log out and back in. Also turn on Reduce Motion and Reduce Transparency in the Mac's System Settings, Accessibility. Undo puts it back, apart from the wallpaper. Needs the Mac's keyboard layout to be U.S.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Log") {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(log.suffix(30).enumerated()), id: \.offset) { _, line in
                            Text(line).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Details")
            .navigationBarTitleDisplayMode(.inline)
            #if os(visionOS)
            // A sheet is swiped away on iOS. visionOS has no such gesture: without a button it stays for good.
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { showDetails = false } }
            }
            #endif
        }
    }

    // MARK: Running

    private static func thermalLabel(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "Normal"
        case .fair: return "Warm"
        case .serious: return "Hot — performance reduced"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }

    private func run() async {
        error = nil
        state = 0
        userCode = false
        cpusOn = 0
        blocksPerSecond = 0
        framesOut = 0
        framesIn = 0
        zoomed = false
        controlsHidden = false
        showRevealHint = false
        zoomCentre = CGPoint(x: 0.5, y: 0.5)
        map = nil
        showWallpaperTip = false
        while henge_vm_state() == 3 && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard !Task.isCancelled else { return }
        guestScreen = nil
        #if os(visionOS)
        VisionPointer.shared.started = CGSize(width: mac.screen.width, height: mac.screen.height)
        #endif
        if let now = RunningMac.current, now.mac.id == mac.id, henge_vm_state() == 1 || henge_vm_state() == 4 {
            // This Mac is running: its view went away over it. visionOS takes a window's scene while the headset is
            // off and gives a new one back, which opens on the list of Macs; starting the Mac from there said "the
            // previous Mac is still running" over the Mac itself, which could be seen and used behind the message.
            HengeLog.log("session", "this Mac is running already: showing it again")
            UIApplication.shared.isIdleTimerDisabled = true
            HardwareMouse.shared.start()
            bootRAM = now.ram
            started = now.started
        } else {
        UIApplication.shared.isIdleTimerDisabled = true
        HardwareMouse.shared.start()
        let ram = GuestMemory.prepare(mac)
        HengeLog.log("session", "available memory \(henge_available_memory() >> 20) MB")
        guard ram >= 1024 else {
            error = "There is not room for this Mac's memory: it needs a few GB of free storage."
            return
        }
        var buffer = [CChar](repeating: 0, count: 256)
        JITBootstrap.releaseLingeringDebugger()
        Sharing.prepare()
        EngineTuning.apply()
        henge_vm_set_display(UInt32(mac.screen.width), UInt32(mac.screen.height))
        if mac.isRetina {
            henge_vm_set_display_mm(UInt32(Device.retinaMM.width), UInt32(Device.retinaMM.height))
        } else {
            henge_vm_set_display_mm(0, 0)
        }
        HengeLog.log("session", "screen \(mac.screen.width)x\(mac.screen.height) retina \(mac.isRetina)")
        var rc: Int32 = -1
        #if os(visionOS)
        if mac.isWindows {
            // A PC: firmware, its variables and the disk, and the installer disk for as long as it is there.
            if mac.winNeedsService {
                // A Windows from before the network driver: it is brought up to date on the way, in this same run.
                HengeLog.log("session", "this Windows is at level \(mac.winLevel): servicing it first")
                preparing = "Preparing an update for this Windows (network, screen, speed)…"
                let lean = UserDefaults.standard.bool(forKey: "henge.windows.lean")
                if let problem = await WindowsSetup.shared.buildService(mac, lean: lean, step: { preparing = "Updating this Windows: \($0)" }) {
                    HengeLog.log("session", "no service disk (\(problem)): starting Windows as it is")
                }
                preparing = nil
            }
            let installer = mac.winInstalling ? mac.winInstaller.path : nil
            HengeLog.log("session", "Windows PC\(installer == nil ? "" : ", installing")")
            WindowsFirmware.prepare(mac)
            var vars = mac.winVars.path
            let servicing = mac.winServicing
            if servicing, WindowsFirmware.unpack("edk2-arm-vars.fd", to: mac.winServiceVars) {
                vars = mac.winServiceVars.path // the PC's own name Windows first; the service disk has to start
                let screen = WindowsScreen.all.first { $0.width == mac.screen.width && $0.height == mac.screen.height }
                _ = henge_win_set_screen(vars, UInt32(screen?.width ?? WindowsScreen.standard.width), UInt32(screen?.height ?? WindowsScreen.standard.height))
                HengeLog.log("session", "a service run: the setup disk first")
            }
            windowsServicing = servicing
            rc = henge_vm_boot_windows(mac.winCode.path, vars, mac.winDisk.path, installer, servicing ? 1 : 0, nil, nil, ram, Int32(cpus),
                                       &buffer, buffer.count)
            if rc != 0 {
                error = String(cString: buffer)
                return
            }
        }
        #endif
        if rc != 0, InstantResume.enabled, let at = InstantResume.saved(for: mac, ramMB: ram, cpus: cpus) {
            HengeLog.log("resume", "picking up the Mac saved \(Int(Date().timeIntervalSince(at))) s ago")
            let t0 = Date()
            rc = henge_vm_resume(mac.rom.path, mac.disk.path, mac.aux.path, mac.ecid, mac.seed, ram, Int32(cpus),
                                 InstantResume.file(for: mac).path, InstantResume.ident(for: mac, ramMB: ram, cpus: cpus), &buffer, buffer.count)
            if rc == 0 {
                HengeLog.log("resume", String(format: "resumed in %.1f s", Date().timeIntervalSince(t0)))
            } else {
                HengeLog.log("resume", "could not resume (\(String(cString: buffer))); starting it from cold")
                buffer = [CChar](repeating: 0, count: 256)
            }
        }
        InstantResume.discard(for: mac) /* used or out of date: the disk moves on from here */
        if rc != 0 {
            rc = henge_vm_boot(mac.rom.path, mac.disk.path, mac.aux.path, mac.ecid, mac.seed, ram, Int32(cpus), &buffer, buffer.count)
        }
        if rc != 0 {
            error = String(cString: buffer)
            return
        }
        bootRAM = ram
        started = Date()
        var used = mac
        used.lastUsed = started
        Machines.shared.update(used)
        RunningMac.current = (mac, started, ram)
        }
        var lastBlocks = henge_vm_blocks()
        var lastTime = Date()
        var lastGPUFrames = henge_vm_gpu_frames()
        var tick = 0
        while !Task.isCancelled {
            state = henge_vm_state()
            if state == 3 || state == 4 { /* starting, stopping, or paused while Henge is in the background */
                try? await Task.sleep(nanoseconds: 100_000_000)
                continue
            }
            cpusOn = henge_vm_cpus_on()
            var screenW: Int32 = 0, screenH: Int32 = 0
            if henge_vm_display_size(&screenW, &screenH) == 0, screenW > 0, screenH > 0 {
                let now = CGSize(width: Int(screenW), height: Int(screenH))
                if now != guestScreen {
                    HengeLog.log("session", "the Mac's screen is \(screenW) x \(screenH)")
                    guestScreen = now
                }
            }
            userCode = userCode || henge_vm_guest_el0() != 0
            let now = Date(), blocks = henge_vm_blocks()
            blocksPerSecond = Double(blocks &- lastBlocks) / max(now.timeIntervalSince(lastTime), 0.001)
            lastBlocks = blocks
            lastTime = now
            framesOut = henge_vm_net_frames(1)
            framesIn = henge_vm_net_frames(0)
            helperRunning = Sharing.helperRunning
            log = Array(HengeLog.recentLines(200))
            let heat = ProcessInfo.processInfo.thermalState
            if heat.rawValue != thermalState.rawValue {
                thermalState = heat
                HengeLog.log("session", "thermal state: \(Self.thermalLabel(heat))")
            }
            if state == 2 {
                RunningMac.current = nil
                typing = false
                showDetails = false
                confirmStop = false
                zoomFollowing?.cancel()
                StickyKeys.shared.releaseAll()
                HardwareKeys.releaseAll()
                HardwareMouse.shared.stop()
                UIApplication.shared.isIdleTimerDisabled = false
                HengeLog.log("session", "showing stopped Mac: \(String(cString: henge_vm_exit_reason()))")
                #if os(visionOS)
                if windowsServicing, mac.winInstalling, henge_vm_restarts() >= 1 {
                    // The service disk did its work and restarted into Windows; however that Windows was left, it is done.
                    try? FileManager.default.removeItem(at: mac.winInstaller)
                    try? FileManager.default.removeItem(at: mac.winServiceMark)
                    try? FileManager.default.removeItem(at: mac.winServiceVars)
                    mac.winMarkCurrent()
                    HengeLog.log("windows", "the service run is finished: this Windows is at level \(WindowsSetup.level)")
                } else if mac.winInstalling, henge_vm_exit_outcome() == Int32(HENGE_VM_OUTCOME_SHUTDOWN.rawValue) {
                    // Windows shut itself down: that is the last step of its answer file. The installer disk has done its work.
                    try? FileManager.default.removeItem(at: mac.winInstaller)
                    try? FileManager.default.removeItem(at: mac.winServiceMark)
                    try? FileManager.default.removeItem(at: mac.winServiceVars)
                    windowsInstalled = !windowsServicing
                    mac.winMarkCurrent()
                    HengeLog.log("windows", "the installation is finished: the installer disk is removed")
                }
                #endif
                if henge_vm_exit_outcome() == Int32(HENGE_VM_OUTCOME_RESTART.rawValue) && henge_vm_can_start() != 0 {
                    bootAttempt += 1
                }
                break
            }
            tick += 1
            if tick % 10 == 0 {
                let gpuFrames = henge_vm_gpu_frames()
                HengeLog.log("perf", "blocks/s \(String(format: "%.0f", blocksPerSecond)), GPU frames/10s \(gpuFrames &- lastGPUFrames), "
                             + "network tx \(framesOut), rx \(framesIn), dns \(henge_vm_dns(0)) answered \(henge_vm_dns(2)) unanswered, "
                             + "thermal \(Self.thermalLabel(heat))")
                lastGPUFrames = gpuFrames
                JITBootstrap.releaseLingeringDebugger()
            }
            if tick == 60 && !stillWallpaperTipShown { // about when the desktop is up after a login
                stillWallpaperTipShown = true
                showWallpaperTip = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) { showWallpaperTip = false }
            }
            if tick % 30 == 0 { HengeLog.logFootprint("session") } // how close to the limit, for a memory kill leaves no crash report
            if tick % 60 == 0 { MacPreview.save(for: mac) }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    private func stopTapped() {
        if state == 1 { confirmStop = true } else { close() }
    }

    private func finish() {
        if state == 1 || state == 4 {
            MacPreview.saveNow(for: mac)
            henge_vm_stop()
        }
        InstantResume.discard(for: mac) /* turned off: nothing to pick up */
        close()
    }
}

/// The Mac the engine runs, for a view that has to find it again: on visionOS a window's scene can go away under a
/// running Mac (the headset taken off) and a new one open on the list of Macs.
@MainActor enum RunningMac {
    static var current: (mac: VirtualMac, started: Date, ram: UInt64)?
    /// Session views on screen now.
    static var shown = 0

    /// The Mac that is running with no view showing it.
    static var unshown: VirtualMac? {
        guard shown == 0, let current, henge_vm_state() == 1 || henge_vm_state() == 4 else { return nil }
        return current.mac
    }
}

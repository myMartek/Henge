import SwiftUI
import AVFAudio

@main
struct HengeApp: App {
    /// Answers for external display scenes before iOS 27 (LegacyExternalDisplay.swift).
    @UIApplicationDelegateAdaptor(HengeAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Order matters: HengeLog takes over stderr, so the engine's and the JIT
        // allocator's first lines land in Documents/henge.log too.
        HengeLog.start()
        HengeLog.log("boot", "address space: \(henge_largest_reservation_gb()) GB can be reserved in one piece")
        EngineTuning.apply()
        HengeLog.logFootprint("app-launch")
        JITBootstrap.noteLaunchState()
        HengeLog.log("app", "increased memory limit: \(Entitlements.increasedMemory ? "yes" : "no"); extended addressing: \(Entitlements.extendedAddressing ? "yes" : "no"); limit \(Entitlements.memoryLimitAtLaunch >> 20) MB")
        // Without the guard, a brk no debugger answers kills the app instead of failing.
        JITBootstrap.installTrapGuard()
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
        Machines.shared.collectImports()
        #if os(visionOS)
        // A Mac here gets a USB pointer that takes positions, so its pointer can be where visionOS's is (VisionPointer).
        // -henge.vision.usbPointer NO leaves it out, should a macOS not get on with it.
        if UserDefaults.standard.object(forKey: "henge.vision.usbPointer") as? Bool ?? true { setenv("HV_USB_POINTER", "1", 1) }
        // Testing: -henge.vision.displayModes YES has the Mac's display offer the other screens as well, for macOS to
        // list under Displays. Off: with them macOS Sequoia drew and never showed a frame (seen on a Vision Pro), so
        // the mode list is not laid out the way devices/pvg_lite.c guesses.
        if UserDefaults.standard.bool(forKey: "henge.vision.displayModes") {
            setenv("HV_DISPLAY_MODES", VisionScreen.all.map(\.tag).joined(separator: ","), 1)
        }
        // What a test left behind (the autopilot's winpack: a Windows disk packed for copying off, gigabytes of it).
        if ProcessInfo.processInfo.environment["HENGE_AUTOPILOT"] == nil {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            try? FileManager.default.removeItem(at: docs.appendingPathComponent("win-export"))
        }
        // Testing: -henge.pairing.autoStart YES starts pairing as the app opens, without the walkthrough.
        if UserDefaults.standard.bool(forKey: "henge.pairing.autoStart") {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                OnDevicePairing.shared.start()
            }
        }
        #endif
        // The display question: does this iOS have Apple's paravirtualized graphics at all?
        for path in ["/System/Library/Frameworks/ParavirtualizedGraphics.framework/ParavirtualizedGraphics",
                     "/System/Library/PrivateFrameworks/ParavirtualizedGraphics.framework/ParavirtualizedGraphics"] {
            HengeLog.log("app", "\(path): \(dlopen(path, RTLD_LAZY) != nil ? "present" : "absent")")
        }
    }

    var body: some Scene {
        // Named, so that visionOS can open a second one beside a running Mac (the session's bar has the button).
        WindowGroup(id: RootView.windowID) {
            RootView()
                .onOpenURL { url in HengeLog.log("app", "opened with \(url.absoluteString)") } // henge:// back from LocalDevVPN
        }
    }
}

struct RootView: View {
    enum Tab: Hashable { case macs, install, settings }
    static let windowID = "henge"

    /// Whether the tabs are there. On visionOS not while a Mac is on screen: their bar hangs at the window's left
    /// edge, where the pointer lands when it leaves the Mac's screen, and it opened whenever it did. What the tabs
    /// hold is one tap away in a second window (the session's bar opens it).
    private var showsTabs: Bool {
        #if os(visionOS)
        running == nil
        #else
        true
        #endif
    }

    @ObservedObject private var machines = Machines.shared
    @ObservedObject private var jit = JITCoordinator.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var running: VirtualMac?
    @State private var tab = Tab.macs
    @AppStorage(DeskAppearance.key) private var appearance = DeskAppearance.system

    var body: some View {
        ZStack {
            if showsTabs {
            TabView(selection: $tab) {
                HomeView(running: $running, tab: $tab)
                    .tabItem { Label("Macs", systemImage: "macwindow") }
                    .tag(Tab.macs)
                InstallView()
                    .tabItem { Label("Install", systemImage: "arrow.down.circle") }
                    .tag(Tab.install)
                SettingsView()
                    .tabItem { Label("Settings", systemImage: "gearshape") }
                    .tag(Tab.settings)
            }
            .tint(Desk.accentLight)
            }
            if let running {
                SessionView(mac: running) { self.running = nil }
                    .environment(\.colorScheme, .dark) // still dark while it fades out over a light page
                    .transition(.opacity)
            }
        }
        .deskPlainButtons()
        .background(WindowStyle(style: running != nil ? .dark : appearance.style))
        .sheet(isPresented: $jit.showSetup) { JITSetupFlow().deskPlainButtons() }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            #if os(visionOS)
            // A Mac running with no window on it (visionOS took the window's scene while the headset was off): this is its window.
            if running == nil, let mac = RunningMac.unshown {
                HengeLog.log("session", "a Mac is running without a window: showing it here")
                running = mac
            }
            #endif
            machines.collectImports()
            jit.enableAtLaunchIfAsked()
            // StikDebug can launch Henge before it attaches. A task also runs
            // on the first appearance, when there may be no phase change.
            for _ in 0..<100 {
                guard !Task.isCancelled else { return }
                if JITBootstrap.prewarmed || JITBootstrap.isLive {
                    jit.objectWillChange.send()
                    return
                }
                if JITBootstrap.debuggedFlag || JITBootstrap.canGrantOwnJIT {
                    JITBootstrap.prewarm()
                    // Readiness lives outside the observable coordinator.
                    jit.objectWillChange.send()
                    return
                }
                do { try await Task.sleep(nanoseconds: 100_000_000) }
                catch { return } // going into the background cancels this wait
            }
        }
        .onChange(of: jit.attachGeneration) { _ in JITBootstrap.prewarm() } // the built-in helper attached
        .task { // testing only: HENGE_AUTOPILOT
            await Autopilot.run { mac in
                // A session still on screen (its Mac stopped) is closed first: the same value again would start nothing.
                guard running != nil else { running = mac; return }
                running = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { running = mac }
            }
        }
    }
}

extension View {
    /// Husk's screens are written against an iOS 15 shim; Henge needs iOS 17, so this is the real thing.
    func hengeDestination<D: Hashable, C: View>(for data: D.Type, @ViewBuilder destination: @escaping (D) -> C) -> some View {
        navigationDestination(for: data, destination: destination)
    }
}

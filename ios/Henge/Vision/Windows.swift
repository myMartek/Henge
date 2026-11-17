// SPDX-License-Identifier: GPL-2.0-or-later
// visionOS spike: Windows 11 for ARM in the same app, from Microsoft's own download to the first desktop, with no
// computer in between.
//
// What runs it is WindowsiOS's engine (../../../WindowsiOS: Henge's with 4 KB pages and a PC around it), linked as
// one object and reached through the calls a Mac's session already makes (Native/henge-vm.c). What installs it is
// new here. WindowsiOS has Windows put on a disk by a Mac; this does the same steps on the device:
//   1. Microsoft's catalog (the one its Media Creation Tool reads) says which ESD image there is for each language;
//   2. the ESD is downloaded from Microsoft's servers and checked against the catalog's SHA-1;
//   3. an installer disk is made from it (WindowsiOS/xros/winmedia: wimlib and FatFs in this process);
//   4. the PC starts from that disk: Windows PE partitions the empty disk, applies Windows, makes it bootable and
//      restarts into it; Windows sets itself up by the answer file, logs in once and shuts down.
// After that the installer disk goes and the PC starts like any other machine.
#if os(visionOS)
import CryptoKit
import SwiftUI

extension VirtualMac {
    var isWindows: Bool { kind == "windows" }
    var winCode: URL { directory.appendingPathComponent("code.fd") }
    var winVars: URL { directory.appendingPathComponent("vars.fd") }
    var winDisk: URL { disk }
    var winInstaller: URL { directory.appendingPathComponent("installer.img") }
    /// Beside a setup disk that only services the Windows there is (WindowsSetup.service): the disk has to be started
    /// instead of that Windows, with firmware variables of its own for the run.
    var winServiceMark: URL { directory.appendingPathComponent("installer.service") }
    var winServiceVars: URL { directory.appendingPathComponent("vars-service.fd") }
    var winServicing: Bool { winInstalling && FileManager.default.fileExists(atPath: winServiceMark.path) }
    /// What this PC's Windows has been given so far: 0 for one installed by the first build (no network driver, no
    /// tuning, the small screen remembered), `WindowsSetup.level` for one that is up to date.
    var winLevelFile: URL { directory.appendingPathComponent("winmedia.level") }
    var winLevel: Int { (try? String(contentsOf: winLevelFile, encoding: .utf8)).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0 }
    /// Its Windows is installed and behind: it is serviced as it starts (SessionView), with no step for the person.
    var winNeedsService: Bool { isWindows && !winInstalling && winLevel < WindowsSetup.level }
    func winMarkCurrent() { try? "\(WindowsSetup.level)\n".write(to: winLevelFile, atomically: true, encoding: .utf8) }
    /// The installer disk is still there: Windows is not on its disk yet, or not through its first start.
    var winInstalling: Bool { isWindows && FileManager.default.fileExists(atPath: winInstaller.path) }
}

/// The screens a Windows PC can have: the firmware's modes (WindowsiOS/xros/patch_firmware.py). Windows draws without
/// a graphics card here, so every pixel is the emulated processor's work: bigger is slower.
enum WindowsScreen {
    static let all: [(width: Int, height: Int, title: String)] = [
        (1280, 720, "1280 × 720 (fastest)"), (1600, 900, "1600 × 900"), (1920, 1080, "1920 × 1080 (slowest)"),
    ]
    static let standard = (width: 1600, height: 900)
}

enum WindowsFirmware {
    /// A firmware file out of the bundle (bzip2: 64 MB that are nearly all empty).
    static func unpack(_ name: String, to file: URL) -> Bool {
        guard let packed = Bundle.main.url(forResource: name, withExtension: "bz2") ?? Bundle.main.url(forResource: name, withExtension: "bz2", subdirectory: "Windows") else { return false }
        return henge_bunzip2_file(packed.path, file.path) == 0
    }

    /// Before a PC starts: the firmware as this build has it (an earlier build's had three small screen modes), and
    /// the screen chosen for the PC in its variables.
    static func prepare(_ pc: VirtualMac) {
        let tmp = pc.winCode.appendingPathExtension("new")
        if unpack("edk2-aarch64-code.fd", to: tmp) {
            _ = try? FileManager.default.replaceItemAt(pc.winCode, withItemAt: tmp)
        }
        let want = WindowsScreen.all.first { $0.width == pc.screen.width && $0.height == pc.screen.height } ?? (WindowsScreen.standard.width, WindowsScreen.standard.height, "")
        let rc = henge_win_set_screen(pc.winVars.path, UInt32(want.width), UInt32(want.height))
        HengeLog.log("windows", "screen \(want.width) x \(want.height): \(rc == 0 ? "set in the firmware's variables" : rc == 1 ? "the firmware's own until its variables exist" : "could not be set")")
    }
}

/// One Windows image Microsoft offers: a language's ESD with every edition in it.
struct WindowsImage: Identifiable, Hashable {
    let language: String      // "de-de"
    let languageName: String  // "German"
    let fileName: String
    let url: URL
    let size: Int64
    let sha1: String
    var id: String { fileName }
}

enum WindowsCatalog {
    /// Where the Media Creation Tool for Windows 11 gets its list: a cabinet file with one products.xml in it.
    static let source = URL(string: "https://go.microsoft.com/fwlink/?LinkId=2156292")!

    static func fetch() async throws -> [WindowsImage] {
        let (cab, response) = try await URLSession.shared.data(from: source)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw problem("Microsoft's catalog did not answer.") }
        var out: UnsafeMutablePointer<UInt8>?
        var length = 0
        let rc = cab.withUnsafeBytes { henge_cab_first_file($0.bindMemory(to: UInt8.self).baseAddress, cab.count, &out, &length) }
        guard rc == 0, let out else { throw problem("Microsoft's catalog could not be unpacked.") }
        defer { free(out) }
        let xml = String(decoding: UnsafeBufferPointer(start: out, count: length), as: UTF8.self)
        var seen = Set<String>(), images: [WindowsImage] = []
        for entry in xml.components(separatedBy: "</File>") { // one image each; "<File" alone also begins FileName and FilePath
            func value(_ tag: String) -> String {
                guard let a = entry.range(of: "<\(tag)>"), let b = entry.range(of: "</\(tag)>", range: a.upperBound..<entry.endIndex) else { return "" }
                return String(entry[a.upperBound..<b.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let name = value("FileName")
            // The consumer image for ARM: Home, Pro and their kin in one file. (The business one is for volume licences.)
            guard value("Architecture").uppercased() == "ARM64", name.contains("CLIENTCONSUMER_RET"), seen.insert(name).inserted,
                  let url = URL(string: value("FilePath")), let size = Int64(value("Size")) else { continue }
            images.append(WindowsImage(language: value("LanguageCode").lowercased(), languageName: value("Language"), fileName: name,
                                       url: url, size: size, sha1: value("Sha1").lowercased()))
        }
        guard !images.isEmpty else { throw problem("Microsoft's catalog lists no Windows for ARM.") }
        return images.sorted { $0.languageName.localizedCaseInsensitiveCompare($1.languageName) == .orderedAscending }
    }

    static func problem(_ text: String) -> NSError {
        NSError(domain: "Henge", code: 20, userInfo: [NSLocalizedDescriptionKey: text])
    }
}

/// Windows from Microsoft's servers onto a new PC's installer disk. One at a time.
@MainActor final class WindowsSetup: ObservableObject {
    static let shared = WindowsSetup()
    /// What an installation gives a Windows now (VirtualMac.winLevel): 2 is the network driver, the tuning and the
    /// screen the firmware starts in.
    nonisolated static let level = 2

    enum Phase: Equatable {
        case idle
        case catalog
        case choosing
        case downloading(have: Int64, total: Int64)
        case checking
        case preparing(step: String, fraction: Double)
        case ready(UUID)       // the PC is in the list with its installer disk: start it
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var images: [WindowsImage] = []
    @Published var language = ""
    private var work: Task<Void, Never>?

    var busy: Bool {
        switch phase {
        case .downloading, .checking, .preparing: return true
        default: return false
        }
    }

    /// The images Microsoft offers, with the device's language picked if there is one for it.
    func loadCatalog() {
        guard images.isEmpty, phase != .catalog, !busy else { return }
        phase = .catalog
        Task {
            do {
                images = try await WindowsCatalog.fetch()
                if language.isEmpty {
                    let mine = Locale.preferredLanguages.map { $0.lowercased() }
                    language = mine.compactMap { tag in images.first { $0.language == tag }?.language }.first
                        ?? mine.compactMap { tag in images.first { $0.language.hasPrefix(tag.prefix(2) + "-") }?.language }.first
                        ?? "en-us"
                }
                phase = .choosing
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    /// The network card's driver (Red Hat's NetKVM, from the bundle), which Windows does not bring, into `folder`.
    nonisolated static func drivers(into folder: URL) -> Bool {
        let fm = FileManager.default
        try? fm.removeItem(at: folder)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for file in ["netkvm.inf", "netkvm.sys", "netkvm.cat", "netkvmp.exe"] {
            let name = (file as NSString).deletingPathExtension, ext = (file as NSString).pathExtension
            guard let from = Bundle.main.url(forResource: name, withExtension: ext) ?? Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Windows"),
                  (try? fm.copyItem(at: from, to: folder.appendingPathComponent(file))) != nil else { return false }
        }
        return true
    }

    /// For a PC whose Windows is installed already: a disk that adds the network driver and turns background work off,
    /// then shuts down. The PC is started with it once. Needs a Windows image that was downloaded (for its Windows PE).
    func service(_ pc: VirtualMac, lean: Bool) {
        guard !busy else { return }
        work = Task {
            phase = .preparing(step: "Reading the Windows image", fraction: -1)
            if let problem = await buildService(pc, lean: lean) { phase = .failed(problem) } else { phase = .ready(pc.id) }
        }
    }

    /// Makes the service disk for `pc` (a minute or two). nil, or what went wrong. `step` is told what is being done.
    func buildService(_ pc: VirtualMac, lean: Bool, step: ((String) -> Void)? = nil) async -> String? {
        let fm = FileManager.default
        let folder = Machines.root.appendingPathComponent("Restore images", isDirectory: true)
        let names = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
        guard let name = names.first(where: { $0.hasSuffix(".esd") }) else {
            return "The Windows image this PC was installed from is not there any more. Install Windows once more to download it."
        }
        let poll = Task { @MainActor in
            while !Task.isCancelled {
                let now = String(cString: henge_win_media_step())
                if !now.isEmpty {
                    if case .preparing = self.phase { self.phase = .preparing(step: now, fraction: henge_win_media_progress()) }
                    let fraction = henge_win_media_progress()
                    step?(fraction >= 0 ? "\(now) (\(Int(fraction * 100)) %)" : now)
                }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
        defer { poll.cancel() }
        let drivers = pc.directory.appendingPathComponent("drivers-tmp")
        let have = Self.drivers(into: drivers)
        defer { try? fm.removeItem(at: drivers) }
        let esd = folder.appendingPathComponent(name).path, image = pc.winInstaller.path, tmp = pc.directory.appendingPathComponent("media-tmp").path
        let driverPath: String? = have ? drivers.path : nil
        let result = await Task.detached(priority: .userInitiated) { () -> (Int32, String) in
            var err = [CChar](repeating: 0, count: 256)
            let rc = henge_win_service_build(esd, image, tmp, driverPath, lean ? 1 : 0, &err, err.count)
            return (rc, String(cString: err))
        }.value
        guard result.0 == 0 else { return "The service disk could not be made: \(result.1)" }
        fm.createFile(atPath: pc.winServiceMark.path, contents: nil)
        HengeLog.log("windows", "service disk ready for \(pc.name)")
        return nil
    }

    func cancel() {
        work?.cancel()
        work = nil
        phase = images.isEmpty ? .idle : .choosing
    }

    func reset() { phase = images.isEmpty ? .idle : .choosing }

    /// Downloads the chosen language's image, makes a PC for it and that PC's installer disk.
    func begin(user: String, edition: String, lean: Bool = false) {
        guard !busy, let image = images.first(where: { $0.language == language }) else { return }
        work = Task { await run(image, user: user, edition: edition, lean: lean) }
    }

    private func run(_ image: WindowsImage, user: String, edition: String, lean: Bool) async {
        let fm = FileManager.default
        let folder = Machines.root.appendingPathComponent("Restore images", isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let esd = folder.appendingPathComponent(image.fileName), part = folder.appendingPathComponent(image.fileName + ".part")
        do {
            // 1. The image, picked up where an earlier download stopped.
            if !fm.fileExists(atPath: esd.path) {
                phase = .downloading(have: RangedDownload.size(of: part), total: image.size)
                var attempts = 0
                while RangedDownload.size(of: part) < image.size {
                    try Task.checkCancellation()
                    let download = RangedDownload(url: image.url, part: part) { have, total in
                        Task { @MainActor in
                            if case .downloading = self.phase { self.phase = .downloading(have: have, total: total > 0 ? total : image.size) }
                        }
                    }
                    do {
                        try await download.run()
                        attempts = 0
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        attempts += 1
                        HengeLog.log("windows", "download stopped (\(error.localizedDescription)); attempt \(attempts)")
                        if attempts >= 8 { throw error }
                        try await Task.sleep(nanoseconds: 3_000_000_000)
                    }
                }
                phase = .checking
                let digest = try await Task.detached(priority: .userInitiated) { try Self.sha1(of: part) }.value
                guard digest == image.sha1 else {
                    try? fm.removeItem(at: part)
                    throw WindowsCatalog.problem("The download does not match what Microsoft's catalog says it should be. It was deleted: try again.")
                }
                try fm.moveItem(at: part, to: esd)
                HengeLog.log("windows", "\(image.fileName): downloaded and checked")
            }

            // 2. The PC: firmware, its empty variables, an empty disk.
            try Task.checkCancellation()
            phase = .preparing(step: "Making the PC", fraction: -1)
            var pc = VirtualMac(name: "Windows 11", ecid: 0, seed: 0, ramMB: 4096, diskBytes: 64 << 30)
            pc.kind = "windows"
            pc.osName = "Windows 11"
            pc.screenWidth = WindowsScreen.standard.width
            pc.screenHeight = WindowsScreen.standard.height
            try fm.createDirectory(at: pc.directory, withIntermediateDirectories: true)
            Machines.excludeFromBackup(pc.directory)
            guard WindowsFirmware.unpack("edk2-aarch64-code.fd", to: pc.winCode), WindowsFirmware.unpack("edk2-arm-vars.fd", to: pc.winVars) else {
                throw WindowsCatalog.problem("The PC's firmware could not be unpacked.")
            }
            guard fm.createFile(atPath: pc.winDisk.path, contents: nil), truncate(pc.winDisk.path, off_t(pc.diskBytes)) == 0 else {
                throw WindowsCatalog.problem("The PC's disk could not be made.")
            }

            // 3. The installer disk, from the image.
            let poll = Task { @MainActor in
                while !Task.isCancelled {
                    if case .preparing = self.phase {
                        let step = String(cString: henge_win_media_step())
                        if !step.isEmpty { self.phase = .preparing(step: step, fraction: henge_win_media_progress()) }
                    }
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
            }
            defer { poll.cancel() }
            // The network card's driver, which Windows does not bring: it goes onto the installer disk.
            let drivers = pc.directory.appendingPathComponent("drivers-tmp")
            let haveDrivers = Self.drivers(into: drivers)
            if !haveDrivers { HengeLog.log("windows", "the network driver is not in the bundle: Windows will have no network") }
            let driverPath: String? = haveDrivers ? drivers.path : nil
            defer { try? fm.removeItem(at: drivers) }
            let installer = pc.winInstaller.path, tmp = pc.directory.appendingPathComponent("media-tmp").path
            let name = user.trimmingCharacters(in: .whitespaces)
            let zone = Self.windowsTimeZone()
            let result = await Task.detached(priority: .userInitiated) { () -> (Int32, String, String) in
                var info = [CChar](repeating: 0, count: 256), err = [CChar](repeating: 0, count: 256)
                let rc = henge_win_media_build(esd.path, installer, tmp, edition, name.isEmpty ? nil : name, "VISIONPRO", zone, driverPath, lean ? 1 : 0,
                                               &info, info.count, &err, err.count)
                return (rc, String(cString: info), String(cString: err))
            }.value
            guard result.0 == 0 else {
                try? fm.removeItem(at: pc.directory)
                throw WindowsCatalog.problem("The installer disk could not be made: \(result.2)")
            }
            let made = result.1.components(separatedBy: "\t")
            if let edition = made.first, !edition.isEmpty { pc.osName = edition }
            HengeLog.log("windows", "installer disk ready: \(result.1.replacingOccurrences(of: "\t", with: ", "))")
            Machines.shared.add(pc)
            phase = .ready(pc.id)
        } catch is CancellationError {
            phase = images.isEmpty ? .idle : .choosing
        } catch {
            HengeLog.log("windows", "setup failed: \(error.localizedDescription)")
            phase = .failed(error.localizedDescription)
        }
    }

    nonisolated private static func sha1(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = Insecure.SHA1()
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Windows's name for the time zone here, for the ones this is likely to run in; Windows asks nothing if it is wrong.
    nonisolated private static func windowsTimeZone() -> String {
        let names = ["Europe/Berlin": "W. Europe Standard Time", "Europe/Vienna": "W. Europe Standard Time", "Europe/Zurich": "W. Europe Standard Time",
                     "Europe/Amsterdam": "W. Europe Standard Time", "Europe/Rome": "W. Europe Standard Time", "Europe/Stockholm": "W. Europe Standard Time",
                     "Europe/Paris": "Romance Standard Time", "Europe/Madrid": "Romance Standard Time", "Europe/Brussels": "Romance Standard Time",
                     "Europe/London": "GMT Standard Time", "Europe/Dublin": "GMT Standard Time", "Europe/Warsaw": "Central European Standard Time",
                     "Europe/Prague": "Central Europe Standard Time", "Europe/Budapest": "Central Europe Standard Time",
                     "America/New_York": "Eastern Standard Time", "America/Chicago": "Central Standard Time", "America/Denver": "Mountain Standard Time",
                     "America/Los_Angeles": "Pacific Standard Time", "Asia/Tokyo": "Tokyo Standard Time", "Asia/Shanghai": "China Standard Time",
                     "Asia/Kolkata": "India Standard Time", "Australia/Sydney": "AUS Eastern Standard Time"]
        return names[TimeZone.current.identifier] ?? "UTC"
    }
}

/// In a PC's settings: bring a Windows that is installed already up to what a new installation gets.
struct WindowsServiceCard: View {
    let pc: VirtualMac
    @ObservedObject private var setup = WindowsSetup.shared
    @AppStorage("henge.windows.lean") private var lean = false

    var body: some View {
        DeskHeading("Network and speed")
        VStack(alignment: .leading, spacing: 10) {
            Text(pc.winNeedsService ? "This Windows was installed before Henge gave it a network driver. That is done by itself the next time this PC starts: it shows a console for a minute first."
                                    : "Adds the network card's driver to this Windows again and turns off background work (search indexing, telemetry, widgets, animations). Nothing is reinstalled and nothing of yours is touched.")
                .font(.system(size: 13)).foregroundStyle(Desk.dim)
            Toggle("Also turn off Defender and Windows Update", isOn: $lean)
            Text("The largest gain in speed and heat, and a real loss of protection.").font(.system(size: 12)).foregroundStyle(Desk.faint)
            switch setup.phase {
            case let .preparing(step, fraction):
                if fraction >= 0 { ProgressView(value: min(max(fraction, 0), 1)) } else { ProgressView() }
                Text(step).font(.system(size: 13)).foregroundStyle(Desk.dim)
            case let .ready(id) where id == pc.id:
                Text("Ready. Start this PC: it shows a console for a minute, restarts by itself and comes up as Windows.")
                    .font(.system(size: 14, weight: .semibold))
            case let .failed(text):
                NoticeRow(symbol: "exclamationmark.triangle.fill", text: text, tint: Desk.bad)
                Button("Prepare") { setup.reset(); setup.service(pc, lean: lean) }.buttonStyle(DeskButtonStyle())
            default:
                if pc.winInstalling {
                    Text("A setup disk is attached: start this PC to run it.").font(.system(size: 14, weight: .semibold))
                } else {
                    Button("Prepare") { setup.service(pc, lean: lean) }.buttonStyle(DeskButtonStyle())
                }
            }
        }
        .padding(17)
        .deskCard()
    }
}

/// Choosing a language, then watching the download and the installer disk being made.
struct WindowsInstallView: View {
    @ObservedObject private var setup = WindowsSetup.shared
    @Environment(\.dismiss) private var dismiss
    @AppStorage("henge.windows.user") private var user = "User"
    @AppStorage("henge.windows.edition") private var edition = "Professional"
    @AppStorage("henge.windows.lean") private var lean = false
    /// Starts the PC that was made.
    let start: (VirtualMac) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Windows 11 for ARM is downloaded from Microsoft's servers (about 4.5 GB) and installed on a new PC here. Windows needs a licence of its own to be activated.")
                        .font(.system(size: 14)).foregroundStyle(Desk.dim)
                    content
                }
                .padding(20)
            }
            .background(Desk.page)
            .navigationTitle("Install Windows")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(setup.busy ? "Hide" : "Close") { dismiss() }
                }
            }
        }
        .onAppear { setup.loadCatalog() }
    }

    @ViewBuilder private var content: some View {
        switch setup.phase {
        case .idle, .catalog:
            HStack(spacing: 10) {
                ProgressView()
                Text("Asking Microsoft which versions there are…").font(.system(size: 15))
            }
        case .choosing:
            DeskHeading("Language")
            Picker("Language", selection: $setup.language) {
                ForEach(setup.images) { image in
                    Text("\(image.languageName) (\(image.language))").tag(image.language)
                }
            }
            .pickerStyle(.menu)
            .padding(.horizontal, 17).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .deskCard()
            DeskHeading("Edition")
            Picker("Edition", selection: $edition) {
                Text("Windows 11 Pro").tag("Professional")
                Text("Windows 11 Home").tag("Core")
            }
            .pickerStyle(.segmented)
            DeskHeading("Your account's name")
            TextField("User", text: $user)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(.horizontal, 17).padding(.vertical, 12)
                .deskCard()
            DeskHeading("Speed")
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Turn off Defender and Windows Update", isOn: $lean)
                Text("Windows runs on an emulated processor here, and what it does in the background costs speed and heat. Search indexing, telemetry, widgets and animations are turned off either way. Defender and Windows Update are the largest cost by far, but they are what protects Windows: turn them off only for a PC you do not trust with anything.")
                    .font(.system(size: 13)).foregroundStyle(Desk.dim)
            }
            .padding(17)
            .deskCard()
            if let image = setup.images.first(where: { $0.language == setup.language }) {
                Text("\(image.fileName), \(ByteText.string(UInt64(image.size)))").font(.system(size: 12)).foregroundStyle(Desk.faint)
            }
            Button("Download and install") { setup.begin(user: user, edition: edition, lean: lean) }
                .buttonStyle(DeskButtonStyle())
                .disabled(setup.language.isEmpty)
        case let .downloading(have, total):
            progress("Downloading Windows from Microsoft", detail: "\(ByteText.string(UInt64(max(have, 0)))) of \(ByteText.string(UInt64(max(total, 0))))",
                     fraction: total > 0 ? Double(have) / Double(total) : -1)
            Button("Stop") { setup.cancel() }.font(.system(size: 15, weight: .semibold)).foregroundStyle(Desk.accentLight)
        case .checking:
            progress("Checking the download", detail: "Against the checksum in Microsoft's catalog", fraction: -1)
        case let .preparing(step, fraction):
            progress("Making the installer disk", detail: step, fraction: fraction)
        case let .ready(id):
            Text("The installer disk is ready.").font(.system(size: 17, weight: .semibold))
            Text("Start the PC now: Windows PE copies Windows onto its disk, then Windows sets itself up and shuts down when it is done. That takes a while, and the window shows it as it goes. Leave it running until it has shut down.")
                .font(.system(size: 14)).foregroundStyle(Desk.dim)
            Button("Start the installation") {
                if let pc = Machines.shared.all.first(where: { $0.id == id }) {
                    setup.reset()
                    dismiss()
                    start(pc)
                }
            }
            .buttonStyle(DeskButtonStyle())
        case let .failed(text):
            NoticeRow(symbol: "exclamationmark.triangle.fill", text: text, tint: Desk.bad)
            Button("Try again") { setup.reset(); setup.loadCatalog() }.buttonStyle(DeskButtonStyle())
        }
    }

    private func progress(_ title: String, detail: String, fraction: Double) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 17, weight: .semibold))
            if fraction >= 0 { ProgressView(value: min(max(fraction, 0), 1)) } else { ProgressView() }
            Text(detail).font(.system(size: 13)).foregroundStyle(Desk.dim)
        }
        .padding(17)
        .frame(maxWidth: .infinity, alignment: .leading)
        .deskCard()
    }
}
#endif

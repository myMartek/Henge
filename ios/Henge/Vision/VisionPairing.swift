// SPDX-License-Identifier: GPL-2.0-or-later
#if os(visionOS)
import dnssd
import Foundation
import SwiftUI

/// Pairing on an Apple Vision Pro, for the built-in JIT helper. The same name and shape as iOS's OnDevicePairing
/// (JIT/JITPairing.swift), so the walkthrough serves both, but the other way round:
///
/// iOS 27 finds a "pairable host" from Settings and connects to it, and the host shows the code. visionOS pairs as
/// tvOS does. With Settings › General › Remote Devices open it advertises `_remotepairing-manual-pairing._tcp`; a
/// host connects and asks to pair; the headset shows the code; the host sends it back. Henge is that host for its
/// own headset (libhenge_rpclient, xros/tools/henge-pair), and the code is typed into Henge.
///
/// The headset resets a connection that comes from itself, so Henge reaches it at 10.7.0.1 through its loopback
/// tunnel (VisionTunnel), as the helper does.
///
/// Log category "jit-pairing": states only, never the code or identifiers.
@MainActor final class OnDevicePairing: ObservableObject {
    static let shared = OnDevicePairing()

    /// Shown in Remote Devices as the paired computer.
    static let hostName = "Henge"
    static let timeout: TimeInterval = 300

    enum Phase: Equatable {
        case idle
        /// Looking for the headset's pairing service, or the code has been sent.
        case waiting
        /// The headset shows its code: `submit` takes what the person types. The string is unused here.
        case pin(String)
        case paired(device: String)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    /// iOS's worry (pairing from Settings puts Henge in the background). A visionOS window stays as it is.
    let backgroundLimited = false

    /// Needs the loopback tunnel, which a build signed by a free team does not have.
    static var isSupported: Bool { VisionTunnel.isBundled }
    static var deviceKind: String { Device.name }

    var isShowingPin: Bool {
        if case .pin = phase { return true }
        return false
    }

    var active: Bool {
        switch phase {
        case .waiting, .pin: return true
        default: return false
        }
    }

    /// One per attempt: where the typed code reaches the thread that pairs.
    private var code = CodeBox()
    /// Counts attempts, so that what a cancelled one reports later is dropped.
    private var attempt = 0

    private init() {}

    private func log(_ line: String) { HengeLog.log("jit-pairing", line) }

    func start() {
        guard Self.isSupported, !active else { return }
        attempt += 1
        let run = attempt
        code = CodeBox()
        phase = .waiting
        log("started")
        if LocalDevVPN.isConnected {
            findAndPair(run)
        } else {
            VisionTunnel.start { [weak self] failure in
                guard let self, self.attempt == run, self.active else { return }
                if let failure { self.fail(failure) } else { self.findAndPair(run) }
            }
        }
    }

    /// The code the headset shows, as typed.
    func submit(_ text: String) {
        let digits = text.filter(\.isNumber)
        guard case .pin = phase, !digits.isEmpty else { return }
        phase = .waiting
        log("code entered")
        code.give(digits)
    }

    /// Stops a pairing in progress. `reason` is shown as the failure; nil returns to idle.
    func cancel(reason: String? = nil) {
        guard active else { return }
        attempt += 1
        code.cancel()
        phase = reason.map(Phase.failed) ?? .idle
        log(reason == nil ? "cancelled" : "stopped")
    }

    /// Forget a finished or failed attempt so the walkthrough starts clean.
    func reset() {
        guard !active else { return }
        phase = .idle
    }

    private func fail(_ message: String) {
        attempt += 1
        code.cancel()
        phase = .failed(message)
        log("failed")
    }

    private func findAndPair(_ run: Int) {
        let box = code
        DispatchQueue.global(qos: .userInitiated).async {
            let service = ManualPairingService.resolve(timeout: 30)
            HengeLog.log("jit-pairing", "service lookup: \(service.detail)")
            guard let port = service.port else {
                DispatchQueue.main.async {
                    guard self.attempt == run else { return }
                    self.fail("This \(Device.name) is not offering to pair. Open Settings › General › Remote Devices, "
                            + "leave it open, and try again.")
                }
                return
            }
            var bytes: UnsafeMutablePointer<UInt8>?
            var length = 0
            var failure: UnsafeMutablePointer<CChar>?
            let context = Unmanaged.passRetained(box)
            defer { context.release() }
            let status = henge_rpclient_pair("10.7.0.1", port, Self.hostName, { context in
                guard let context else { return nil }
                let box = Unmanaged<CodeBox>.fromOpaque(context).takeUnretainedValue()
                DispatchQueue.main.async { OnDevicePairing.shared.codeWanted(box) }
                return box.wait(timeout: OnDevicePairing.timeout).flatMap { strdup($0) }
            }, context.toOpaque(), &bytes, &length, &failure)
            let data = bytes.map { Data(bytes: $0, count: length) }
            henge_rpclient_bytes_free(bytes, length)
            let message = failure.map { String(cString: $0) }
            henge_rpclient_string_free(failure)
            DispatchQueue.main.async { self.finished(run, status: status, data: data, message: message) }
        }
    }

    /// The headset took the request and shows its code.
    private func codeWanted(_ box: CodeBox) {
        guard box === code, active else { return }
        phase = .pin("")
        log("the headset shows its code")
    }

    private func finished(_ run: Int, status: Int32, data: Data?, message: String?) {
        guard attempt == run else { return } // cancelled meanwhile
        switch status {
        case 0:
            do {
                guard let data else { throw NSError(domain: "HengeJIT", code: 20) }
                try JITCoordinator.shared.storeOnDevicePairing(data)
                phase = .paired(device: "this \(Device.name)")
                log("paired")
            } catch {
                fail("Pairing finished, but Henge could not save the pairing file.")
            }
        case 2:
            phase = .idle
            log("cancelled")
        default:
            HengeLog.log("jit-pairing", "failed: \(message ?? "no reason given")")
            fail(Self.explain(message))
        }
    }

    private static func explain(_ message: String?) -> String {
        let text = message ?? ""
        if text.contains("could not connect") || text.contains("ConnectionReset") || text.contains("ConnectionRefused") {
            return "Henge could not reach this \(Device.name)'s pairing service. Keep Settings › General › Remote Devices "
                 + "open and try again."
        }
        return "Pairing failed. Check the code and try again, with Settings › General › Remote Devices open."
    }
}

/// Hands the typed code to the thread that waits for it.
final class CodeBox: @unchecked Sendable {
    private let ready = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var value: String?

    func give(_ code: String) {
        lock.lock(); value = code; lock.unlock()
        ready.signal()
    }

    func cancel() { ready.signal() }

    /// The code, or nil when cancelled or nobody typed one in time.
    func wait(timeout: TimeInterval) -> String? {
        _ = ready.wait(timeout: .now() + timeout)
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

/// Finds the port of this headset's `_remotepairing-manual-pairing._tcp` service, which it advertises only while
/// Remote Devices is open in Settings. Read from the service's SRV record (DNSServiceResolve), as the helper's
/// RSDPortResolver does for `_remotepairing._tcp`. Blocks: call it off the main thread.
enum ManualPairingService {
    struct Result {
        var port: UInt16?
        var detail: String
    }

    private static let serviceType = "_remotepairing-manual-pairing._tcp"

    static func resolve(timeout: TimeInterval) -> Result {
        let state = State()
        let queue = DispatchQueue(label: "com.henge.app.manual-pairing")
        let context = Unmanaged.passRetained(state)
        defer { context.release() }

        var browseRef: DNSServiceRef?
        let browseError = DNSServiceBrowse(&browseRef, 0, 0, serviceType, "local.", browseCallback, context.toOpaque())
        guard browseError == kDNSServiceErr_NoError, let browseRef else {
            return Result(port: nil, detail: "browse could not start (\(browseError))")
        }
        state.queue = queue
        DNSServiceSetDispatchQueue(browseRef, queue)

        let found = state.done.wait(timeout: .now() + timeout) == .success
        return queue.sync {
            DNSServiceRefDeallocate(browseRef)
            state.resolveRefs.forEach(DNSServiceRefDeallocate)
            state.resolveRefs.removeAll()
            state.finished = true
            if found, let port = state.port { return Result(port: port, detail: "port \(port), \(state.seen) service(s) seen") }
            var detail = "none within \(Int(timeout))s: \(state.seen) service(s) seen"
            if let error = state.lastError {
                detail += Int(error) == Int(kDNSServiceErr_PolicyDenied) ? ", Local Network access is off for Henge" : ", error \(error)"
            }
            return Result(port: nil, detail: detail)
        }
    }

    /// Only touched on `queue` once the browse has started.
    private final class State {
        let done = DispatchSemaphore(value: 0)
        var queue: DispatchQueue?
        var resolveRefs: [DNSServiceRef] = []
        var seen = 0
        var port: UInt16?
        var lastError: DNSServiceErrorType?
        var finished = false
    }

    private static let browseCallback: DNSServiceBrowseReply = { _, flags, interface, error, name, type, domain, context in
        guard let context else { return }
        let state = Unmanaged<State>.fromOpaque(context).takeUnretainedValue()
        guard !state.finished, state.port == nil else { return }
        guard error == kDNSServiceErr_NoError else { state.lastError = error; return }
        guard (flags & kDNSServiceFlagsAdd) != 0, let name, let type, let domain else { return }
        state.seen += 1
        var resolveRef: DNSServiceRef?
        let resolveError = DNSServiceResolve(&resolveRef, 0, interface, name, type, domain, resolveCallback, context)
        guard resolveError == kDNSServiceErr_NoError, let resolveRef, let queue = state.queue else {
            state.lastError = resolveError
            return
        }
        state.resolveRefs.append(resolveRef)
        DNSServiceSetDispatchQueue(resolveRef, queue)
    }

    private static let resolveCallback: DNSServiceResolveReply = { _, _, _, error, _, _, port, _, _, context in
        guard let context else { return }
        let state = Unmanaged<State>.fromOpaque(context).takeUnretainedValue()
        guard error == kDNSServiceErr_NoError else { state.lastError = error; return }
        let value = UInt16(bigEndian: port) // network byte order
        guard value != 0, state.port == nil, !state.finished else { return }
        state.port = value
        state.done.signal()
    }
}
#endif

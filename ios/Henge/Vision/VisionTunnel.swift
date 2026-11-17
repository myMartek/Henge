// SPDX-License-Identifier: GPL-2.0-or-later
#if os(visionOS)
import Foundation
import NetworkExtension

/// Starts Henge's own loopback tunnel (ios/HengeVisionTunnel), which stands in for LocalDevVPN on visionOS.
/// The first start has visionOS ask whether Henge may add a VPN configuration.
enum VisionTunnel {
    static var providerIdentifier: String { (Bundle.main.bundleIdentifier ?? "com.henge.app") + ".Tunnel" }

    /// Whether the extension is in this install (a build signed without the Network Extensions capability leaves it out).
    static var isBundled: Bool {
        guard let plugins = Bundle.main.builtInPlugInsURL else { return false }
        return FileManager.default.fileExists(atPath: plugins.appendingPathComponent("HengeVisionTunnel.appex").path)
    }

    /// A start has been asked for in this launch: a second failure is the helper's to report, not a reason to ask again.
    nonisolated(unsafe) static var attempted = false

    /// Calls back on the main thread with nil once the tunnel is up, or with what went wrong.
    static func start(completion: @escaping (String?) -> Void) {
        attempted = true
        let finish: (String?) -> Void = { failure in
            HengeLog.log("jit", failure.map { "loopback tunnel: \($0)" } ?? "loopback tunnel is up")
            DispatchQueue.main.async { completion(failure) }
        }
        guard isBundled else { return finish("This build of Henge has no loopback tunnel (it needs a paid developer team to sign).") }
        NETunnelProviderManager.loadAllFromPreferences { managers, error in
            if let error { return finish("Could not read the VPN configurations: \(error.localizedDescription)") }
            let manager = managers?.first {
                ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == providerIdentifier
            } ?? NETunnelProviderManager()
            let configuration = NETunnelProviderProtocol()
            configuration.providerBundleIdentifier = providerIdentifier
            configuration.serverAddress = "This Apple Vision Pro"
            manager.protocolConfiguration = configuration
            manager.localizedDescription = "Henge loopback"
            manager.isEnabled = true
            manager.saveToPreferences { error in
                if let error { return finish("The VPN configuration was not added: \(error.localizedDescription)") }
                // A manager just saved has to be loaded again before it can connect.
                manager.loadFromPreferences { error in
                    if let error { return finish("Could not load the VPN configuration: \(error.localizedDescription)") }
                    do { try manager.connection.startVPNTunnel() } catch {
                        return finish("The loopback tunnel did not start: \(error.localizedDescription)")
                    }
                    wait(for: manager, until: Date().addingTimeInterval(20), finish: finish)
                }
            }
        }
    }

    private static func wait(for manager: NETunnelProviderManager, until deadline: Date, finish: @escaping (String?) -> Void) {
        switch manager.connection.status {
        case .connected: return finish(nil)
        case .invalid: return finish("The loopback tunnel's configuration is not valid.")
        default: break
        }
        guard Date() < deadline else {
            return finish("The loopback tunnel did not come up within 20 seconds (status \(manager.connection.status.rawValue)).")
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) { wait(for: manager, until: deadline, finish: finish) }
    }
}
#endif

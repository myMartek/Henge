// SPDX-License-Identifier: GPL-2.0-or-later
import NetworkExtension

/// Henge's loopback tunnel for visionOS: what LocalDevVPN is on iOS, inside the app.
///
/// The built-in JIT helper has to connect to this device's own pairing service, and the device resets a connection
/// that comes from itself (tried on a Vision Pro M5, visionOS 27.3: the same pairing file is accepted from a Mac and
/// reset from the headset's own Wi-Fi address). So the connection takes a detour through a tunnel interface, where
/// it arrives like one from outside. The scheme and its addresses are StosVPN's (SideStore, MIT), which
/// LocalDevVPN and StikJIT's default of 10.7.0.1 follow:
///
///   the tunnel is 10.7.0.0/24 and the device's own address on it is 10.7.0.0;
///   a packet from 10.7.0.0 to 10.7.0.1 is sent back in as one from 10.7.0.1 to 10.7.0.0, and the reply likewise.
///
/// Exchanging the two addresses leaves the IPv4 and TCP checksums as they were, so nothing else is rewritten.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private static let device: UInt32 = 0x0A07_0000 // 10.7.0.0, this device
    private static let peer: UInt32 = 0x0A07_0001   // 10.7.0.1, where the helper looks for it

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "10.7.0.0")
        let ipv4 = NEIPv4Settings(addresses: ["10.7.0.0"], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = [NEIPv4Route(destinationAddress: "10.7.0.0", subnetMask: "255.255.255.0")]
        ipv4.excludedRoutes = [.default()]
        settings.ipv4Settings = ipv4
        setTunnelNetworkSettings(settings) { [weak self] error in
            if error == nil { self?.reflect() }
            completionHandler(error)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        completionHandler()
    }

    private func reflect() {
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self else { return }
            var out = packets
            for index in out.indices where protocols[index].int32Value == AF_INET && out[index].count >= 20 {
                out[index].withUnsafeMutableBytes { bytes in
                    let source = UInt32(bigEndian: bytes.loadUnaligned(fromByteOffset: 12, as: UInt32.self))
                    let destination = UInt32(bigEndian: bytes.loadUnaligned(fromByteOffset: 16, as: UInt32.self))
                    if source == Self.device { bytes.storeBytes(of: Self.peer.bigEndian, toByteOffset: 12, as: UInt32.self) }
                    if destination == Self.peer { bytes.storeBytes(of: Self.device.bigEndian, toByteOffset: 16, as: UInt32.self) }
                }
            }
            self.packetFlow.writePackets(out, withProtocols: protocols)
            self.reflect()
        }
    }
}

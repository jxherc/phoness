import NetworkExtension

// loopback vpn. packets to 10.7.0.1 get their src/dst swapped and go straight back in,
// so the app can reach the phone's own lockdownd like a computer on wifi would.
// same idea as stosvpn / localdevvpn, which stikdebug uses.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    override func startTunnel(options: [String: NSObject]?) async throws {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        let v4 = NEIPv4Settings(addresses: ["10.7.0.0"], subnetMasks: ["255.255.255.0"])
        v4.includedRoutes = [NEIPv4Route(destinationAddress: "10.7.0.1", subnetMask: "255.255.255.255")]
        settings.ipv4Settings = v4
        try await setTunnelNetworkSettings(settings)
        pump()
    }

    override func stopTunnel(with reason: NEProviderStopReason) async {}

    private func pump() {
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self else { return }
            var out: [Data] = []
            var outProtocols: [NSNumber] = []
            for (p, proto) in zip(packets, protocols) {
                // only ipv4 to 10.7.0.1 is routed here, anything else gets dropped.
                // swapping src/dst keeps every checksum valid
                guard p.count >= 20, p[p.startIndex] >> 4 == 4 else { continue }
                var p = Data(p)
                let src = p.subdata(in: 12..<16)
                p.replaceSubrange(12..<16, with: p.subdata(in: 16..<20))
                p.replaceSubrange(16..<20, with: src)
                out.append(p)
                outProtocols.append(proto)
            }
            if !out.isEmpty { self.packetFlow.writePackets(out, withProtocols: outProtocols) }
            self.pump()
        }
    }
}

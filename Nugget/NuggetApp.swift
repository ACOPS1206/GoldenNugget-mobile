import SwiftUI
import Minimuxer

@main
struct PoCApp: App {
    init() {
        // LocalDevVPN compatibility: only start our own WireGuard server
        // (em_proxy at 127.0.0.1:51820) when no LocalDevVPN-style tunnel
        // (NEPacketTunnelProvider with iface 10.7.1.1) is already up.
        let tunnelUp = Tunnel.isInterfaceUp()
        print("Tunnel status: \(Tunnel.describe()) — em_proxy \(tunnelUp ? "skipped (LocalDevVPN active)" : "starting")")
        if !tunnelUp {
            let emproxy = Minimuxer.shared().emproxy
            emproxy.setHandshakeClient(host: "127.0.0.1", port: 51820, enabled: false)
            Task {
                do {
                    try await emproxy.start(host: "127.0.0.1", port: 51820)
                } catch {
                    print("em_proxy failed to start: \(error)")
                }
            }
        }
    }
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
import SwiftUI

@main
struct PoCApp: App {
    init() {
        setenv("USBMUXD_SOCKET_ADDRESS", "127.0.0.1:27015", 1)
        _ = start_emotional_damage("127.0.0.1:51820")
    }
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
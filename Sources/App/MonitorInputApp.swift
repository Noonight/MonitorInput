import AppKit

@main
enum MonitorInputApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = MonitorMenuBar()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

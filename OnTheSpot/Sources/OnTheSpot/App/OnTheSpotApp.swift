import SwiftUI
import AppKit

@main
struct OnTheSpotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var settings = AppSettings()

    var body: some Scene {
        WindowGroup {
            ContentView(settings: settings)
                .onAppear {
                    // Set sharingType on the main window once it exists
                    ScreenHider.hideAllWindows()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 320, height: 560)
        Settings {
            SettingsView(settings: settings)
        }
    }
}

/// Observes new window creation and sets sharingType = .none on every window.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowObserver: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        ScreenHider.hideAllWindows()

        // Watch for new windows being created (e.g. Settings window)
        windowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let window = notification.object as? NSWindow
            Task { @MainActor in
                _ = self
                window?.sharingType = .none
            }
        }
    }
}

/// Utility to set sharingType = .none on all app windows.
@MainActor
enum ScreenHider {
    static func hideAllWindows() {
        for window in NSApp.windows {
            window.sharingType = .none
        }
    }
}

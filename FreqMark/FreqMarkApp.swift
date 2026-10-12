import SwiftUI

@main
struct FreqMarkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup(id: "main-window") {
            ContentView()
                .frame(minWidth: 940, minHeight: 620)
        }
        .windowStyle(.automatic)
    }
}

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

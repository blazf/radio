import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct RadioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var player = RadioPlayer()
    @StateObject private var loginItem = LoginItem()

    var body: some Scene {
        Window("Radio", id: "main") {
            ContentView()
                .environmentObject(player)
        }
        .windowResizability(.contentSize)

        MenuBarExtra {
            MenuBarContent()
                .environmentObject(player)
                .environmentObject(loginItem)
        } label: {
            Image(systemName: "radio")
        }
    }
}

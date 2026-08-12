import AppKit
import SwiftUI

@main
struct ModelCompareStudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState()

    init() {
        AppDelegate.state = state
    }

    var body: some Scene {
        WindowGroup("Model Compare Studio") {
            ContentView()
                .environmentObject(state)
                .frame(minWidth: 1060, idealWidth: 1340, minHeight: 680, idealHeight: 900)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1340, height: 900)
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Conversation") { state.newConversation() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Divider()
                Button("Export Latest Comparison as PDF…") { state.beginPDFExport() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                Button("Open Latest Results") { state.openLatest() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by the App so termination can persist any last preference edits.
    static weak var state: AppState?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A bare Resources binary launched outside LaunchServices does not
        // become active on its own; without this its window never becomes key
        // and text fields refuse keyboard input.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        AppDelegate.state?.persistAllPreferences()
    }
}

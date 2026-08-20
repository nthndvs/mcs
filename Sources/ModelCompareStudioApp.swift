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
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { state.checkForUpdatesManually() }
            }
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
        AppDelegate.state?.checkForUpdatesOnLaunch()
        // A restored window frame can sit partly above the menu bar (e.g.
        // after disconnecting an external display), clipping the title bar
        // and traffic-light buttons. Pull it back onto the visible screen.
        DispatchQueue.main.async { self.constrainWindowsToVisibleScreen() }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(constrainWindowsToVisibleScreen),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    /// Moves any window whose title bar is above the screen's visible area
    /// back down so the window controls are reachable. (Bottom overflow is
    /// left alone: the title bar is still grabbable in that case.)
    @objc private func constrainWindowsToVisibleScreen() {
        for window in NSApp.windows where window.isVisible && window.styleMask.contains(.titled) {
            guard let screen = window.screen ?? NSScreen.main else { continue }
            let visible = screen.visibleFrame
            var frame = window.frame
            guard frame.maxY > visible.maxY else { continue }
            if frame.height > visible.height {
                frame.size.height = visible.height
                frame.origin.y = visible.minY
            } else {
                frame.origin.y = visible.maxY - frame.height
            }
            window.setFrame(frame, display: true, animate: false)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        AppDelegate.state?.persistAllPreferences()
    }
}

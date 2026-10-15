import AppKit
import SwiftUI

@main
struct WritingAssistantApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra("Writing Assistant", systemImage: "pencil.line") {
            MenuContent(state: delegate.state)
        }
        .menuBarExtraStyle(.menu)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        state.start()
        if CommandLine.arguments.contains("--probe") {
            state.runProbe()
        }
    }
}

struct MenuContent: View {
    @ObservedObject var state: AppState

    var body: some View {
        if state.accessibilityGranted {
            Text("Accessibility: granted")
        } else {
            Text("Accessibility: not granted")
            Button("Open System Settings…") { state.openAccessibilitySettings() }
        }

        Divider()

        Toggle("Launch at Login", isOn: Binding(
            get: { state.launchAtLogin },
            set: { state.setLaunchAtLogin($0) }
        ))
        if let error = state.launchAtLoginError {
            Text("Login item error: \(error)")
        }

        #if DEBUG
        Divider()
        Text("Debug")
        Text(state.envSummary)
        Button("Probe spell checker") { state.runProbe() }
        if let summary = state.probeSummary {
            Text(summary)
        }
        #endif

        Divider()
        Button("Quit Writing Assistant") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

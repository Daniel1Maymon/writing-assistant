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
        Toggle("Save accepted fixes", isOn: Binding(
            get: { state.saveAcceptedFixes },
            set: { state.setSaveAcceptedFixes($0) }
        ))
        Button("My mistakes…") { state.showMistakes() }
        if let error = state.launchAtLoginError {
            Text("Login item error: \(error)")
        }

        Divider()
        Text(state.aiSummary)
        if state.aiCapReached {
            Text("⚠︎ Daily AI limit reached: word checks only until tomorrow")
        }
        Button(state.hasKey ? "Change OpenRouter Key…" : "Set OpenRouter Key…") { state.askForKey() }

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

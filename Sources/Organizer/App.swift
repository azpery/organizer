import SwiftUI
import AppKit

@main
struct OrganizerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = Store.shared

    var body: some Scene {
        WindowGroup("Organizer", id: "main") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 980, minHeight: 640)
        }
        .windowToolbarStyle(.unified(showsTitle: true))

        WindowGroup("Tâche", id: "task", for: String.self) { $taskId in
            if let taskId {
                TaskDetailView(taskId: taskId)
                    .environmentObject(store)
                    .frame(minWidth: 880, minHeight: 560)
            }
        }
        .defaultSize(width: 1180, height: 820)
        .commands {
            CommandMenu("Chrono") {
                Button(store.runningEntry == nil ? "Démarrer le chrono" : "Arrêter le chrono") {
                    if store.runningEntry != nil { store.stopTimer() }
                    else { store.startTimer(description: "", projectId: nil, taskId: nil) }
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        Task { @MainActor in
            Store.shared.startAPI()
            StatusItemController.shared = StatusItemController(store: Store.shared)
            Demo.start()
            guard !Demo.active else { return }
            Store.shared.startGitLabPolling()
            Store.shared.startCalendarPolling()
            Store.shared.startMailPolling()
            Store.shared.startJiraPolling()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MailSource.terminateRunning()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { Task { @MainActor in WindowOpener.showMain() } }
        return true
    }
}

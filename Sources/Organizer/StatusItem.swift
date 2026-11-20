import AppKit
import SwiftUI
import Combine

/// Clockify-style badge in the macOS menu bar: shows the running timer, click opens the quick panel.
@MainActor
final class StatusItemController: NSObject {
    static var shared: StatusItemController?

    private let store: Store
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var ticker: Timer?
    private var cancellable: AnyCancellable?
    private var lastTitle = "-"

    init(store: Store) {
        self.store = store
        super.init()
        popover.behavior = .transient
        popover.animates = true
        let hosting = NSHostingController(rootView: MenuBarPanel().environmentObject(store))
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting

        if let button = item.button {
            button.target = self
            button.action = #selector(toggle)
            button.imagePosition = .imageLeading
        }
        cancellable = store.$entries.receive(on: RunLoop.main).sink { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
        refresh()
    }

    private func refresh() {
        guard let button = item.button else { return }
        let running = store.runningEntry
        let title = running.map { " " + Fmt.hms(Date().timeIntervalSince($0.start)) } ?? ""
        guard title != lastTitle else { return }
        let wasRunning = !lastTitle.isEmpty && lastTitle != "-"
        lastTitle = title

        if (running != nil) != wasRunning || button.image == nil {
            let symbol = running != nil ? "record.circle.fill" : "timer"
            let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "Organizer")
            img?.isTemplate = running == nil
            button.image = running != nil
                ? img?.withSymbolConfiguration(.init(paletteColors: [.systemRed]))
                : img
        }
        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium),
        ])
        button.toolTip = running.map { $0.description.isEmpty ? "Chrono en cours" : $0.description } ?? "Organizer"
    }

    @objc private func toggle() {
        guard let button = item.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func closePopover() { popover.performClose(nil) }
}

/// Lets non-scene code (status item popover) reopen the main window.
@MainActor
enum WindowOpener {
    static var open: (() -> Void)?
    static var openTask: ((String) -> Void)?

    static func showMain() {
        StatusItemController.shared?.closePopover()
        NSApp.activate(ignoringOtherApps: true)
        if let w = NSApp.windows.first(where: { $0.canBecomeMain && $0.isVisible == false && $0.title == "Organizer" })
            ?? NSApp.windows.first(where: { $0.canBecomeMain }) {
            w.makeKeyAndOrderFront(nil)
        } else {
            open?()
        }
    }
}

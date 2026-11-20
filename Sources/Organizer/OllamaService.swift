import SwiftUI

/// Starts / stops the local Ollama server on demand (Homebrew service).
/// `brew services run` starts it without registering it at login, so Ollama never launches by itself;
/// `brew services stop` stops it and removes any login registration.
@MainActor
final class OllamaService: ObservableObject {
    static let shared = OllamaService()

    /// nil while unknown.
    @Published var running: Bool?
    @Published var busy = false
    @Published var error: String?

    private static var brew: String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func refresh() {
        guard !busy else { return }
        Task { running = (try? await Ollama.models()) != nil }
    }

    func set(_ on: Bool) {
        guard !busy else { return }
        guard let brew = Self.brew else { error = "Homebrew introuvable : lance Ollama à la main."; return }
        busy = true
        error = nil
        Task {
            let ok = await Task.detached { () -> Bool in
                let p = Process()
                p.executableURL = URL(fileURLWithPath: brew)
                p.arguments = ["services", on ? "run" : "stop", "ollama"]
                p.standardOutput = Pipe(); p.standardError = Pipe()
                do { try p.run() } catch { return false }
                p.waitUntilExit()
                return p.terminationStatus == 0
            }.value
            // The server takes a moment to come up (or go down).
            var state = !on
            for _ in 0..<12 {
                state = (try? await Ollama.models()) != nil
                if state == on { break }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            running = state
            if state != on { error = ok ? "Ollama n'a pas \(on ? "démarré" : "été arrêté")" : "La commande brew services a échoué" }
            busy = false
        }
    }
}

/// On/off switch for Ollama, usable anywhere.
struct OllamaToggle: View {
    @ObservedObject private var service = OllamaService.shared
    var compact = false

    var body: some View {
        HStack(spacing: 8) {
            if service.busy { ProgressView().controlSize(.small) }
            else { Circle().fill(service.running == true ? Color.green : Color.secondary.opacity(0.5)).frame(width: 8, height: 8) }
            if !compact || service.error != nil {
                Text(service.error ?? (service.busy ? "…" : service.running == true ? "Ollama actif" : "Ollama arrêté"))
                    .font(.callout).foregroundStyle(service.error == nil ? Color.secondary : Color.orange)
            }
            Toggle("Ollama", isOn: Binding(get: { service.running == true }, set: { service.set($0) }))
                .toggleStyle(.switch).controlSize(.small).labelsHidden()
                .disabled(service.busy)
        }
        .help("Démarrer ou arrêter Ollama. Il n'est jamais lancé automatiquement.")
        .onAppear { service.refresh() }
    }
}

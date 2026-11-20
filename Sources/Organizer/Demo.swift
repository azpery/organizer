import AppKit

/// Demo mode, used to try the app or take screenshots without touching real data.
///
///     ORGANIZER_DEMO_DIR=/tmp/organizer-demo .build/debug/Organizer
///
/// - data lives in that folder (database, api.json) instead of Application Support ;
/// - the local API listens on `ORGANIZER_DEMO_PORT` (47899 by default) ;
/// - no background sync (Jira, GitLab, calendar, mail) and no real disk scan ;
/// - `ORGANIZER_SHOT=file.png` saves a picture of the window after `ORGANIZER_SHOT_DELAY` seconds, then quits.
enum Demo {
    private static let env = ProcessInfo.processInfo.environment

    static let dir: URL? = env["ORGANIZER_DEMO_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
    static var active: Bool { dir != nil }
    static var port: UInt16 { UInt16(env["ORGANIZER_DEMO_PORT"] ?? "") ?? 47899 }

    /// Called once at launch.
    @MainActor
    static func start() {
        guard active else { return }
        if let look = env["ORGANIZER_DEMO_APPEARANCE"] {
            NSApp.appearance = NSAppearance(named: look == "dark" ? .darkAqua : .aqua)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) else { return }
            let size = NSSize(width: Double(env["ORGANIZER_DEMO_WIDTH"] ?? "") ?? 1280, height: Double(env["ORGANIZER_DEMO_HEIGHT"] ?? "") ?? 800)
            window.setFrame(NSRect(origin: window.frame.origin, size: size), display: true)
            window.center()
        }
        guard let shot = env["ORGANIZER_SHOT"], !shot.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + (Double(env["ORGANIZER_SHOT_DELAY"] ?? "") ?? 3)) {
            capture(to: URL(fileURLWithPath: shot))
            NSApp.terminate(nil)
        }
    }

    /// Renders the app's own main window (title bar included) to a PNG.
    @MainActor
    private static func capture(to url: URL) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }),
              let view = window.contentView?.superview,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// Made-up cleaning results, so that screenshots never show real file names.
    static var cleanCategories: [CleanCategory] {
        func item(_ name: String, _ detail: String, _ gb: Double, _ pre: Bool = true) -> CleanItem {
            CleanItem(url: URL(fileURLWithPath: "/demo/\(name)"), name: name, detail: detail, size: Int64(gb * 1_000_000_000), preselected: pre)
        }
        return [
            CleanCategory(id: "caches", title: "Caches des applications", icon: "shippingbox", colorHex: "#4F7CFF",
                          hint: "Fichiers temporaires recréés automatiquement par les apps.", permanent: true,
                          items: [item("com.musique.player", "", 11.4), item("Navigateur", "", 2.8), item("com.editeur.code", "", 1.7), item("com.messagerie.app", "", 0.9)]),
            CleanCategory(id: "dev", title: "Caches de développement", icon: "hammer", colorHex: "#7B5CFF",
                          hint: "Xcode, npm, Gradle… Re-téléchargés ou recompilés au besoin.", permanent: true,
                          items: [item("MonApp-abcdefgh", "Xcode · DerivedData", 9.6), item("Cache npm", "npm", 6.9), item("Store pnpm", "pnpm", 5.2), item("Caches Gradle", "Gradle", 3.1)]),
            CleanCategory(id: "builds", title: "Dépendances et builds de projets", icon: "folder.badge.gearshape", colorHex: "#FF9F0A",
                          hint: "node_modules, .build, Pods… Réinstallables (npm install, swift build). Rien n'est coché par défaut.", permanent: true,
                          items: [item("api › target", "~/Projets/api", 8.4, false), item("site › node_modules", "~/Projets/site", 2.3, false), item("mobile › Pods", "~/Projets/mobile/ios", 1.8, false)]),
            CleanCategory(id: "logs", title: "Journaux", icon: "doc.plaintext", colorHex: "#8E8E93",
                          hint: "Logs et rapports de plantage.", permanent: true, items: [item("DiagnosticReports", "", 0.31), item("Editeur", "", 0.12)]),
            CleanCategory(id: "trash", title: "Corbeille", icon: "trash", colorHex: "#FF453A",
                          hint: "Vider la corbeille libère définitivement l'espace.", permanent: true, items: [item("Corbeille", "42 éléments", 3.6)]),
            CleanCategory(id: "downloads", title: "Vieux téléchargements", icon: "arrow.down.circle", colorHex: "#30B0C7",
                          hint: "Dans Téléchargements depuis plus de 90 jours. Déplacés dans la corbeille.", permanent: false,
                          items: [item("installeur-2.4.dmg", "Ajouté il y a 7 mois", 1.9, false), item("export-photos.zip", "Ajouté il y a 5 mois", 1.2, false)]),
            CleanCategory(id: "large", title: "Gros fichiers", icon: "doc.badge.ellipsis", colorHex: "#FF375F",
                          hint: "Fichiers de plus de 200 Mo dans Documents, Bureau, Téléchargements, Vidéos, Musique. Déplacés dans la corbeille.", permanent: false,
                          items: [item("conference-2025.mov", "~/Movies", 7.8, false), item("sauvegarde-site.tar", "~/Documents/Archives", 4.4, false), item("machine-virtuelle.img", "~/Documents", 3.9, false)]),
        ]
    }
}

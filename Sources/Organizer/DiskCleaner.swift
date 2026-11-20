import Foundation
import AppKit

/// One thing that can be removed (a folder or a file).
struct CleanItem: Identifiable, Hashable {
    var id: String { url.path }
    let url: URL
    let name: String
    var detail: String = ""
    var size: Int64
    var modified: Date? = nil
    /// Checked by default after a scan.
    var preselected = true
}

struct CleanCategory: Identifiable {
    let id: String
    let title: String
    let icon: String
    let colorHex: String
    let hint: String
    /// true: removed for good (regenerable data). false: moved to the Trash.
    let permanent: Bool
    var items: [CleanItem] = []

    var total: Int64 { items.reduce(0) { $0 + $1.size } }
}

struct InstalledApp: Identifiable, Hashable {
    var id: String { url.path }
    let url: URL
    let name: String
    let bundleId: String?
    var size: Int64
    var lastUsed: Date?
    var running: Bool
}

enum DiskFmt {
    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func ago(_ date: Date?) -> String {
        guard let date else { return "jamais utilisée" }
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Scanning (synchronous, run off the main thread)

enum DiskScan {
    static let fm = FileManager.default
    static var home: URL { fm.homeDirectoryForCurrentUser }
    static var trash: URL { home.appendingPathComponent(".Trash") }

    private static let sizeKeys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]

    /// Disk space really used by a file or a whole folder (symlinks are not followed).
    static func size(_ url: URL) -> Int64 {
        guard let v = try? url.resourceValues(forKeys: Set(sizeKeys)) else { return 0 }
        if v.isDirectory != true || v.isSymbolicLink == true {
            return Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
        }
        guard let e = fm.enumerator(at: url, includingPropertiesForKeys: sizeKeys, options: [], errorHandler: { _, _ in true }) else { return 0 }
        var total: Int64 = 0
        while let f = e.nextObject() as? URL {
            if Task.isCancelled { break }
            if let r = try? f.resourceValues(forKeys: Set(sizeKeys)) {
                total += Int64(r.totalFileAllocatedSize ?? r.fileAllocatedSize ?? 0)
            }
        }
        return total
    }

    static func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) }

    static func children(_ url: URL) -> [URL] {
        (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.contentModificationDateKey], options: [])) ?? []
    }

    static func modified(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    static func tilde(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    private static func item(_ url: URL, name: String? = nil, detail: String = "", preselected: Bool = true, minSize: Int64 = 0) -> CleanItem? {
        guard exists(url) else { return nil }
        let s = size(url)
        guard s > minSize else { return nil }
        return CleanItem(url: url, name: name ?? url.lastPathComponent, detail: detail, size: s, modified: modified(url), preselected: preselected)
    }

    private static func sorted(_ items: [CleanItem]) -> [CleanItem] { items.sorted { $0.size > $1.size } }

    static let mb: Int64 = 1_000_000

    // MARK: Categories

    static func userCaches() -> CleanCategory {
        let dir = home.appendingPathComponent("Library/Caches")
        let own = Bundle.main.bundleIdentifier ?? "local.organizer.app"
        let items = children(dir).compactMap { u -> CleanItem? in
            let n = u.lastPathComponent
            guard n != own, !n.hasPrefix(".") else { return nil }
            // System caches are listed but left unchecked.
            return item(u, preselected: !n.hasPrefix("com.apple."), minSize: mb)
        }
        return CleanCategory(id: "caches", title: "Caches des applications", icon: "shippingbox", colorHex: "#4F7CFF",
                             hint: "Fichiers temporaires recréés automatiquement par les apps.", permanent: true, items: sorted(items))
    }

    static func logs() -> CleanCategory {
        let dir = home.appendingPathComponent("Library/Logs")
        let items = children(dir).compactMap { item($0, minSize: mb) }
        return CleanCategory(id: "logs", title: "Journaux", icon: "doc.plaintext", colorHex: "#8E8E93",
                             hint: "Logs et rapports de plantage.", permanent: true, items: sorted(items))
    }

    static func devCaches() -> CleanCategory {
        var items: [CleanItem] = []
        let xcode = home.appendingPathComponent("Library/Developer/Xcode")
        for u in children(xcode.appendingPathComponent("DerivedData")) where !u.lastPathComponent.hasPrefix(".") {
            if let i = item(u, detail: "Xcode · DerivedData", minSize: mb) { items.append(i) }
        }
        for sub in ["iOS DeviceSupport", "watchOS DeviceSupport", "tvOS DeviceSupport"] {
            for u in children(xcode.appendingPathComponent(sub)) {
                if let i = item(u, detail: "Xcode · \(sub)", minSize: mb) { items.append(i) }
            }
        }
        if let i = item(xcode.appendingPathComponent("Archives"), name: "Archives Xcode",
                        detail: "Builds archivés (utiles pour symboliquer d'anciens crashs)", preselected: false, minSize: mb) { items.append(i) }

        let known: [(String, String, String, Bool)] = [
            ("Library/Developer/CoreSimulator/Caches", "Caches des simulateurs", "Xcode", true),
            (".npm/_cacache", "Cache npm", "npm", true),
            (".npm/_npx", "Cache npx", "npm", true),
            (".yarn/cache", "Cache Yarn", "Yarn", true),
            (".yarn/berry/cache", "Cache Yarn Berry", "Yarn", true),
            ("Library/pnpm/store", "Store pnpm", "pnpm", true),
            (".bun/install/cache", "Cache Bun", "Bun", true),
            (".gradle/caches", "Caches Gradle", "Gradle", true),
            (".m2/repository", "Dépôt Maven local", "Maven (re-téléchargé au prochain build)", false),
            (".cocoapods/repos", "Specs CocoaPods", "CocoaPods", true),
            (".cargo/registry/cache", "Cache Cargo", "Rust", true),
            (".composer/cache", "Cache Composer", "PHP", true),
            (".swiftpm/cache", "Cache SwiftPM", "Swift", true),
            (".pub-cache", "Cache Pub", "Dart / Flutter", false),
        ]
        for (path, name, detail, pre) in known {
            if let i = item(home.appendingPathComponent(path), name: name, detail: detail, preselected: pre, minSize: mb) { items.append(i) }
        }
        for u in children(home.appendingPathComponent(".cache")) {
            if let i = item(u, detail: "~/.cache", minSize: mb) { items.append(i) }
        }
        return CleanCategory(id: "dev", title: "Caches de développement", icon: "hammer", colorHex: "#7B5CFF",
                             hint: "Xcode, npm, Gradle… Re-téléchargés ou recompilés au besoin.", permanent: true, items: sorted(items))
    }

    /// Folders where projects usually live.
    private static var projectRoots: [URL] {
        ["Documents", "Developer", "Projects", "Projets", "workspace", "Workspace", "Code", "code", "dev", "Sites", "src", "Desktop"]
            .map { home.appendingPathComponent($0) }
            .filter { exists($0) }
    }

    /// Dependency / build folders inside projects (node_modules, .build, Pods…).
    static func projectBuilds() -> CleanCategory {
        var found: [URL] = []
        var seen = Set<String>()
        func walk(_ dir: URL, depth: Int) {
            if Task.isCancelled || depth > 7 { return }
            let subs = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey], options: [])) ?? []
            let names = Set(subs.map(\.lastPathComponent))
            for u in subs {
                guard let v = try? u.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]),
                      v.isDirectory == true, v.isSymbolicLink != true, v.isPackage != true else { continue }
                let n = u.lastPathComponent
                let match: Bool
                switch n {
                case "node_modules", ".next", ".nuxt", ".turbo", ".parcel-cache": match = true
                case ".build": match = names.contains("Package.swift")
                case "Pods": match = names.contains("Podfile")
                case "target": match = names.contains("Cargo.toml") || names.contains("pom.xml")
                case "vendor": match = names.contains("composer.json")
                case ".gradle": match = names.contains("build.gradle") || names.contains("build.gradle.kts") || names.contains("settings.gradle")
                case "DerivedData": match = true
                default: match = false
                }
                if match {
                    if seen.insert(u.resolvingSymlinksInPath().path).inserted { found.append(u) }
                } else if !n.hasPrefix(".") && n != "Library" {
                    walk(u, depth: depth + 1)
                }
            }
        }
        for r in projectRoots { walk(r, depth: 0) }
        let items = found.compactMap { u -> CleanItem? in
            let project = u.deletingLastPathComponent()
            return item(u, name: "\(project.lastPathComponent) › \(u.lastPathComponent)", detail: tilde(project), preselected: false, minSize: 5 * mb)
        }
        return CleanCategory(id: "builds", title: "Dépendances et builds de projets", icon: "folder.badge.gearshape", colorHex: "#FF9F0A",
                             hint: "node_modules, .build, Pods… Réinstallables (npm install, swift build). Rien n'est coché par défaut.",
                             permanent: true, items: sorted(items))
    }

    static func oldDownloads(olderThanDays days: Int = 90) -> CleanCategory {
        let dir = home.appendingPathComponent("Downloads")
        let limit = Date().addingTimeInterval(-Double(days) * 86400)
        let keys: [URLResourceKey] = [.contentModificationDateKey, .addedToDirectoryDateKey]
        let subs = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        let items = subs.compactMap { u -> CleanItem? in
            let v = try? u.resourceValues(forKeys: Set(keys))
            let last = max(v?.contentModificationDate ?? .distantPast, v?.addedToDirectoryDate ?? .distantPast)
            guard last != Date.distantPast, limit > last else { return nil }
            let s = size(u)
            guard s > 0 else { return nil }
            return CleanItem(url: u, name: u.lastPathComponent, detail: "Ajouté \(DiskFmt.ago(last))", size: s, modified: last, preselected: false)
        }
        return CleanCategory(id: "downloads", title: "Vieux téléchargements", icon: "arrow.down.circle", colorHex: "#30B0C7",
                             hint: "Dans Téléchargements depuis plus de \(days) jours. Déplacés dans la corbeille.", permanent: false, items: sorted(items))
    }

    static func largeFiles(minSize: Int64 = 200 * 1_000_000, limit: Int = 80) -> CleanCategory {
        var items: [CleanItem] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .contentModificationDateKey]
        let skip: Set<String> = ["node_modules", "Pods", "DerivedData"]
        for root in ["Downloads", "Documents", "Desktop", "Movies", "Music"].map({ home.appendingPathComponent($0) }) {
            guard let e = fm.enumerator(at: root, includingPropertiesForKeys: keys,
                                        options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in true }) else { continue }
            while let f = e.nextObject() as? URL {
                if Task.isCancelled { break }
                if skip.contains(f.lastPathComponent) { e.skipDescendants(); continue }
                guard let v = try? f.resourceValues(forKeys: Set(keys)), v.isRegularFile == true,
                      let s = v.totalFileAllocatedSize, Int64(s) >= minSize else { continue }
                items.append(CleanItem(url: f, name: f.lastPathComponent, detail: tilde(f.deletingLastPathComponent()),
                                       size: Int64(s), modified: v.contentModificationDate, preselected: false))
            }
        }
        return CleanCategory(id: "large", title: "Gros fichiers", icon: "doc.badge.ellipsis", colorHex: "#FF375F",
                             hint: "Fichiers de plus de \(DiskFmt.size(minSize)) dans Documents, Bureau, Téléchargements, Vidéos, Musique. Déplacés dans la corbeille.",
                             permanent: false, items: Array(sorted(items).prefix(limit)))
    }

    static func trashCategory() -> CleanCategory {
        var cat = CleanCategory(id: "trash", title: "Corbeille", icon: "trash", colorHex: "#FF453A",
                                hint: "Vider la corbeille libère définitivement l'espace.", permanent: true)
        if let subs = try? fm.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil, options: []) {
            let real = subs.filter { $0.lastPathComponent != ".DS_Store" }
            if !real.isEmpty {
                cat.items = [CleanItem(url: trash, name: "Corbeille", detail: "\(real.count) élément\(real.count > 1 ? "s" : "")", size: size(trash))]
            }
        } else {
            // macOS protects ~/.Trash: without Full Disk Access we can't measure it, but Finder can empty it.
            cat.items = [CleanItem(url: trash, name: "Corbeille", detail: "Taille inconnue (accès protégé par macOS) — vidée via le Finder",
                                   size: 0, preselected: false)]
        }
        return cat
    }

    // MARK: Applications

    static func applications() -> [InstalledApp] {
        let dirs = [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")]
        var urls: [URL] = []
        for d in dirs {
            for u in children(d) {
                if u.pathExtension == "app" { urls.append(u) }
                else if (try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    urls += children(u).filter { $0.pathExtension == "app" }
                }
            }
        }
        let own = Bundle.main.bundleIdentifier
        return urls.compactMap { u in
            let bundleId = Bundle(url: u)?.bundleIdentifier
            if bundleId != nil, bundleId == own { return nil }
            let used = NSMetadataItem(url: u)?.value(forAttribute: kMDItemLastUsedDate as String) as? Date
            return InstalledApp(url: u, name: u.deletingPathExtension().lastPathComponent, bundleId: bundleId,
                                size: size(u), lastUsed: used, running: false)
        }
    }

    /// Support files an app leaves in ~/Library.
    static func leftovers(of app: InstalledApp) -> [CleanItem] {
        let lib = home.appendingPathComponent("Library")
        var paths: [String] = ["Application Support/\(app.name)", "Caches/\(app.name)", "Logs/\(app.name)"]
        if let b = app.bundleId {
            paths += ["Application Support/\(b)", "Caches/\(b)", "Preferences/\(b).plist", "Saved Application State/\(b).savedState",
                      "Containers/\(b)", "HTTPStorages/\(b)", "HTTPStorages/\(b).binarycookies", "WebKit/\(b)",
                      "Cookies/\(b).binarycookies", "Application Scripts/\(b)"]
        }
        return paths.compactMap { p in
            let u = lib.appendingPathComponent(p)
            guard exists(u) else { return nil }
            return CleanItem(url: u, name: u.lastPathComponent, detail: tilde(u.deletingLastPathComponent()), size: size(u))
        }
    }

    // MARK: Removal

    /// Only paths well inside the home folder (or an app bundle in /Applications) can be removed.
    static func isRemovable(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        if path.hasPrefix("/Applications/") && path.hasSuffix(".app") { return true }
        let homePath = home.standardizedFileURL.path
        guard path.hasPrefix(homePath + "/") else { return false }
        let rel = path.dropFirst(homePath.count + 1).split(separator: "/")
        if rel.contains("..") { return false }
        if rel.first == "Library" { return rel.count >= 3 }
        return rel.count >= 2
    }

    /// Returns nil on success, or an error message.
    static func remove(_ url: URL, permanent: Bool) -> String? {
        if url.path == trash.path { return emptyTrash() }
        guard isRemovable(url) else { return "chemin refusé : \(tilde(url))" }
        do {
            if permanent { try fm.removeItem(at: url) } else { try fm.trashItem(at: url, resultingItemURL: nil) }
            return nil
        } catch {
            return "\(url.lastPathComponent) : \(error.localizedDescription)"
        }
    }

    private static func emptyTrash() -> String? {
        if let subs = try? fm.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil, options: []) {
            var failed = 0
            for u in subs where (try? fm.removeItem(at: u)) == nil { failed += 1 }
            return failed == 0 ? nil : "Corbeille : \(failed) élément(s) non supprimé(s)"
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "tell application \"Finder\" to empty trash"]
        p.standardOutput = Pipe(); p.standardError = Pipe()
        do { try p.run() } catch { return "Corbeille : \(error.localizedDescription)" }
        p.waitUntilExit()
        return p.terminationStatus == 0 ? nil : "Corbeille : le Finder n'a pas pu la vider"
    }

    static func diskSpace() -> (total: Int64, free: Int64) {
        let v = try? home.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        return (Int64(v?.volumeTotalCapacity ?? 0), v?.volumeAvailableCapacityForImportantUsage ?? 0)
    }
}

// MARK: - State

@MainActor
final class DiskCleaner: ObservableObject {
    static let shared = DiskCleaner()

    @Published var categories: [CleanCategory] = []
    @Published var selected: Set<String> = []
    @Published var apps: [InstalledApp] = []
    @Published var scanning = false
    @Published var scanningApps = false
    @Published var cleaning = false
    @Published var lastScan: Date?
    @Published var diskTotal: Int64 = 0
    @Published var diskFree: Int64 = 0

    private static let order = ["caches", "dev", "builds", "logs", "trash", "downloads", "large"]
    private var scanTask: Task<Void, Never>?

    init() { refreshDisk() }

    func refreshDisk() {
        if Demo.active { diskTotal = 500_000_000_000; diskFree = 61_300_000_000; return }
        let d = DiskScan.diskSpace()
        diskTotal = d.total; diskFree = d.free
    }

    func scan() {
        if Demo.active {
            categories = Demo.cleanCategories
            selected = Set(categories.flatMap { $0.items.filter(\.preselected).map(\.id) })
            lastScan = Date()
            return
        }
        scanTask?.cancel()
        scanning = true
        categories = []
        selected = []
        refreshDisk()
        scanTask = Task {
            await withTaskGroup(of: CleanCategory.self) { group in
                group.addTask { DiskScan.userCaches() }
                group.addTask { DiskScan.devCaches() }
                group.addTask { DiskScan.projectBuilds() }
                group.addTask { DiskScan.logs() }
                group.addTask { DiskScan.trashCategory() }
                group.addTask { DiskScan.oldDownloads() }
                group.addTask { DiskScan.largeFiles() }
                for await cat in group {
                    if Task.isCancelled { continue }
                    categories.append(cat)
                    categories.sort { (Self.order.firstIndex(of: $0.id) ?? 99) < (Self.order.firstIndex(of: $1.id) ?? 99) }
                    selected.formUnion(cat.items.filter(\.preselected).map(\.id))
                }
            }
            if !Task.isCancelled {
                scanning = false
                lastScan = Date()
            }
        }
    }

    func scanApps() {
        guard !scanningApps, !Demo.active else { return }
        scanningApps = true
        Task {
            var list = await Task.detached { DiskScan.applications() }.value
            let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.standardizedFileURL.path })
            for i in list.indices { list[i].running = running.contains(list[i].url.standardizedFileURL.path) }
            apps = list
            scanningApps = false
        }
    }

    // MARK: Selection

    /// Selected items, without duplicates nor items nested inside another selected one.
    var selectedItems: [(item: CleanItem, permanent: Bool)] {
        var byPath: [String: (CleanItem, Bool)] = [:]
        for cat in categories {
            for i in cat.items where selected.contains(i.id) {
                // If a file shows up in two categories, the safest mode (Trash) wins.
                if let existing = byPath[i.id] { byPath[i.id] = (existing.0, existing.1 && cat.permanent) }
                else { byPath[i.id] = (i, cat.permanent) }
            }
        }
        let paths = byPath.keys.sorted()
        var kept: [String] = []
        for p in paths where !kept.contains(where: { p.hasPrefix($0 + "/") }) { kept.append(p) }
        return kept.compactMap { byPath[$0] }.map { (item: $0.0, permanent: $0.1) }
    }

    var selectedSize: Int64 { selectedItems.reduce(0) { $0 + $1.item.size } }

    func toggle(_ item: CleanItem) {
        if selected.contains(item.id) { selected.remove(item.id) } else { selected.insert(item.id) }
    }

    func setAll(_ cat: CleanCategory, _ on: Bool) {
        let ids = cat.items.map(\.id)
        if on { selected.formUnion(ids) } else { selected.subtract(ids) }
    }

    // MARK: Cleaning

    /// Removes the selection. Returns (bytes freed or trashed, error messages).
    func cleanSelected() async -> (freed: Int64, errors: [String]) {
        // The Trash is emptied last, so that what we just moved there is freed too.
        let trashPath = DiskScan.trash.path
        let targets = selectedItems.filter { $0.item.id != trashPath } + selectedItems.filter { $0.item.id == trashPath }
        cleaning = true
        let result = await Task.detached { () -> (Int64, [String], Set<String>) in
            var freed: Int64 = 0
            var errors: [String] = []
            var removed = Set<String>()
            for t in targets {
                if let e = DiskScan.remove(t.item.url, permanent: t.permanent) { errors.append(e) }
                else { freed += t.item.size; removed.insert(t.item.id) }
            }
            return (freed, errors, removed)
        }.value
        for i in categories.indices {
            categories[i].items.removeAll { item in
                result.2.contains(item.id) || result.2.contains { item.id.hasPrefix($0 + "/") }
            }
        }
        selected.subtract(result.2)
        selected = selected.filter { id in categories.contains { $0.items.contains { $0.id == id } } }
        cleaning = false
        refreshDisk()
        return (result.0, result.1)
    }

    /// Moves an app and the chosen support files to the Trash.
    func uninstall(_ app: InstalledApp, leftovers: [CleanItem]) async -> (freed: Int64, errors: [String]) {
        let result = await Task.detached { () -> (Int64, [String]) in
            var freed: Int64 = 0
            var errors: [String] = []
            if let e = DiskScan.remove(app.url, permanent: false) { return (0, [e]) }
            freed += app.size
            for l in leftovers {
                if let e = DiskScan.remove(l.url, permanent: false) { errors.append(e) } else { freed += l.size }
            }
            return (freed, errors)
        }.value
        if result.0 > 0 { apps.removeAll { $0.id == app.id } }
        refreshDisk()
        return result
    }
}

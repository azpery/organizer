import SwiftUI
import AppKit

struct CleanerView: View {
    @EnvironmentObject var store: Store
    @StateObject private var cleaner = DiskCleaner.shared
    @AppStorage("cleanerTab") private var tab = "clean"
    @State private var confirmClean = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                DiskUsageCard(cleaner: cleaner)
                Picker("", selection: $tab) {
                    Text("Nettoyage").tag("clean")
                    Text("Applications").tag("apps")
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()

                if tab == "clean" { cleanList } else { AppsList(cleaner: cleaner) }
            }
            .padding(20)
        }
        .navigationTitle("Nettoyage")
        .toolbar {
            Button {
                if tab == "clean" { cleaner.scan() } else { cleaner.scanApps() }
            } label: { Label("Analyser", systemImage: "arrow.clockwise") }
                .disabled(cleaner.scanning || cleaner.scanningApps || cleaner.cleaning)
        }
        .safeAreaInset(edge: .bottom) {
            if tab == "clean", !cleaner.categories.isEmpty { cleanBar }
        }
        .onAppear {
            cleaner.refreshDisk()
            if cleaner.lastScan == nil && !cleaner.scanning { cleaner.scan() }
        }
        .onChange(of: tab) { _, t in
            if t == "apps" && cleaner.apps.isEmpty { cleaner.scanApps() }
        }
        .task { if tab == "apps" && cleaner.apps.isEmpty { cleaner.scanApps() } }
    }

    @ViewBuilder
    private var cleanList: some View {
        if cleaner.scanning {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Analyse du disque en cours…").font(.callout).foregroundStyle(.secondary)
            }
        }
        ForEach(cleaner.categories) { cat in
            CleanCategoryCard(cleaner: cleaner, category: cat)
        }
        if !cleaner.scanning && cleaner.categories.allSatisfy({ $0.items.isEmpty }) {
            Card { EmptyState(icon: "sparkles", title: "Rien à nettoyer", message: "Aucun fichier superflu trouvé.") }
        }
    }

    private var cleanBar: some View {
        let items = cleaner.selectedItems
        let size = items.reduce(Int64(0)) { $0 + $1.item.size }
        let permanent = items.filter(\.permanent).count
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(items.isEmpty ? "Rien de sélectionné" : "\(items.count) élément\(items.count > 1 ? "s" : "") · \(DiskFmt.size(size))")
                    .font(.headline)
                Text("Caches et builds : suppression définitive · fichiers personnels : corbeille")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if cleaner.cleaning { ProgressView().controlSize(.small) }
            Button { confirmClean = true } label: {
                Label("Nettoyer…", systemImage: "sparkles").padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .disabled(items.isEmpty || cleaner.cleaning || cleaner.scanning)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
        .confirmationDialog("Nettoyer \(DiskFmt.size(size)) ?", isPresented: $confirmClean) {
            Button("Nettoyer", role: .destructive) {
                Task {
                    let r = await cleaner.cleanSelected()
                    if r.errors.isEmpty {
                        store.showToast("✓ \(DiskFmt.size(r.freed)) nettoyés")
                    } else {
                        store.showToast("\(DiskFmt.size(r.freed)) nettoyés · \(r.errors.count) échec\(r.errors.count > 1 ? "s" : "") (\(r.errors[0]))")
                    }
                }
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("\(permanent) élément\(permanent > 1 ? "s" : "") supprimé\(permanent > 1 ? "s" : "") définitivement (caches, builds, corbeille), \(items.count - permanent) déplacé\(items.count - permanent > 1 ? "s" : "") dans la corbeille.")
        }
    }
}

// MARK: - Disk usage

private struct DiskUsageCard: View {
    @ObservedObject var cleaner: DiskCleaner

    var body: some View {
        let used = max(0, cleaner.diskTotal - cleaner.diskFree)
        let ratio = cleaner.diskTotal > 0 ? Double(used) / Double(cleaner.diskTotal) : 0
        let reclaim = cleaner.categories.reduce(Int64(0)) { $0 + $1.total }
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Label("Macintosh HD", systemImage: "internaldrive").font(.headline)
                    Spacer()
                    Text("\(DiskFmt.size(cleaner.diskFree)) libres").font(.system(.title3, design: .rounded).weight(.semibold))
                    Text("sur \(DiskFmt.size(cleaner.diskTotal))").font(.callout).foregroundStyle(.secondary)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.08))
                        Capsule()
                            .fill(LinearGradient(colors: ratio > 0.9 ? [.orange, .red] : [Color(hex: "#4F7CFF"), Color(hex: "#7B5CFF")],
                                                 startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(8, geo.size.width * ratio))
                    }
                }
                .frame(height: 10)
                HStack {
                    Text("\(DiskFmt.size(used)) utilisés (\(Int((ratio * 100).rounded())) %)").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if reclaim > 0 {
                        Text("\(DiskFmt.size(reclaim)) récupérables trouvés").font(.caption.weight(.semibold)).foregroundStyle(.green)
                    }
                }
            }
        }
    }
}

// MARK: - Categories

private struct CleanCategoryCard: View {
    @ObservedObject var cleaner: DiskCleaner
    let category: CleanCategory
    @State private var expanded = false
    @State private var showAll = false

    private var selectedCount: Int { category.items.filter { cleaner.selected.contains($0.id) }.count }

    var body: some View {
        let color = Color(hex: category.colorHex)
        let count = selectedCount
        Card(padding: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Button {
                        cleaner.setAll(category, count < category.items.count)
                    } label: {
                        Image(systemName: count == 0 ? "circle" : count == category.items.count ? "checkmark.circle.fill" : "minus.circle.fill")
                            .font(.title3).foregroundStyle(count == 0 ? Color.secondary : color)
                    }
                    .buttonStyle(.plain).disabled(category.items.isEmpty)
                    .help("Tout cocher / décocher")

                    Image(systemName: category.icon)
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(color.gradient))
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(category.title).font(.headline)
                            if !category.permanent { Pill(text: "Corbeille", color: .secondary, systemImage: "arrow.uturn.backward") }
                        }
                        Text(category.hint).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(category.items.isEmpty ? "—" : DiskFmt.size(category.total))
                            .font(.system(.title3, design: .rounded).weight(.semibold)).monospacedDigit()
                        Text("\(category.items.count) élément\(category.items.count > 1 ? "s" : "")").font(.caption).foregroundStyle(.tertiary)
                    }
                    Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .opacity(category.items.isEmpty ? 0 : 1)
                }
                .padding(14)
                .contentShape(Rectangle())
                .onTapGesture { if !category.items.isEmpty { withAnimation(.snappy(duration: 0.2)) { expanded.toggle() } } }

                if expanded {
                    Divider()
                    let shown = showAll ? category.items : Array(category.items.prefix(12))
                    LazyVStack(spacing: 0) {
                        ForEach(shown) { item in
                            CleanItemRow(cleaner: cleaner, item: item, color: color)
                        }
                        if category.items.count > shown.count {
                            Button("Afficher les \(category.items.count - shown.count) autres") { showAll = true }
                                .buttonStyle(.link).padding(10)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }
}

private struct CleanItemRow: View {
    @ObservedObject var cleaner: DiskCleaner
    let item: CleanItem
    let color: Color
    @State private var hover = false

    var body: some View {
        let on = cleaner.selected.contains(item.id)
        HStack(spacing: 10) {
            Image(systemName: on ? "checkmark.square.fill" : "square")
                .foregroundStyle(on ? color : Color.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).font(.callout).lineLimit(1).truncationMode(.middle)
                if !item.detail.isEmpty {
                    Text(item.detail).font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer()
            if hover {
                Button { NSWorkspace.shared.activateFileViewerSelecting([item.url]) } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.borderless).help("Afficher dans le Finder")
            }
            Text(item.size > 0 ? DiskFmt.size(item.size) : "—").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
        .background(hover ? Color.primary.opacity(0.04) : .clear)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { cleaner.toggle(item) }
        .contextMenu {
            Button("Afficher dans le Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            Button("Copier le chemin") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.url.path, forType: .string)
            }
        }
    }
}

// MARK: - Applications

private struct AppsList: View {
    @EnvironmentObject var store: Store
    @ObservedObject var cleaner: DiskCleaner
    @State private var sort = "size"
    @State private var search = ""
    @State private var uninstalling: InstalledApp?

    private var apps: [InstalledApp] {
        let list = cleaner.apps.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
        switch sort {
        case "used": return list.sorted { ($0.lastUsed ?? .distantPast) < ($1.lastUsed ?? .distantPast) }
        case "name": return list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        default: return list.sorted { $0.size > $1.size }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Rechercher une application", text: $search)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                Picker("Trier", selection: $sort) {
                    Text("Les plus lourdes").tag("size")
                    Text("Les moins utilisées").tag("used")
                    Text("Nom").tag("name")
                }
                .labelsHidden().fixedSize()
                Spacer()
                if cleaner.scanningApps {
                    ProgressView().controlSize(.small)
                    Text("Analyse des applications…").font(.callout).foregroundStyle(.secondary)
                } else {
                    Text("\(cleaner.apps.count) apps · \(DiskFmt.size(cleaner.apps.reduce(0) { $0 + $1.size }))")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Card(padding: 0) {
                LazyVStack(spacing: 0) {
                    ForEach(apps) { app in
                        AppRow(app: app) { uninstalling = app }
                        Divider().padding(.leading, 60)
                    }
                    if apps.isEmpty && !cleaner.scanningApps {
                        EmptyState(icon: "app.dashed", title: "Aucune application")
                    }
                }
            }
        }
        .sheet(item: $uninstalling) { app in
            UninstallSheet(cleaner: cleaner, app: app).environmentObject(store)
        }
    }
}

private struct AppRow: View {
    let app: InstalledApp
    let onUninstall: () -> Void

    private var stale: Bool {
        guard let d = app.lastUsed else { return true }
        return d < Date().addingTimeInterval(-180 * 86400)
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                .resizable().frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(app.name).font(.callout.weight(.medium)).lineLimit(1)
                    if app.running { Pill(text: "Ouverte", color: .green) }
                    else if stale { Pill(text: "Peu utilisée", color: .orange) }
                }
                Text("Dernière utilisation : \(DiskFmt.ago(app.lastUsed))").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(DiskFmt.size(app.size)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            Button("Désinstaller…", action: onUninstall)
                .disabled(app.running)
                .help(app.running ? "Quitte l'application avant de la désinstaller" : "Déplacer l'app et ses fichiers dans la corbeille")
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .contextMenu {
            Button("Afficher dans le Finder") { NSWorkspace.shared.activateFileViewerSelecting([app.url]) }
        }
    }
}

private struct UninstallSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var cleaner: DiskCleaner
    let app: InstalledApp
    @State private var leftovers: [CleanItem] = []
    @State private var keep: Set<String> = []
    @State private var loading = true
    @State private var working = false

    private var chosen: [CleanItem] { leftovers.filter { !keep.contains($0.id) } }

    var body: some View {
        let total = app.size + chosen.reduce(0) { $0 + $1.size }
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path)).resizable().frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Désinstaller \(app.name)").font(.title2.weight(.semibold))
                    Text("Tout est déplacé dans la corbeille : tu peux encore revenir en arrière.").font(.callout).foregroundStyle(.secondary)
                }
            }
            Card(padding: 0) {
                ScrollView {
                    VStack(spacing: 0) {
                        row(checked: true, locked: true, name: app.url.lastPathComponent, detail: DiskScan.tilde(app.url.deletingLastPathComponent()), size: app.size) {}
                        if loading {
                            HStack { ProgressView().controlSize(.small); Text("Recherche des fichiers associés…").font(.callout).foregroundStyle(.secondary) }
                                .padding(12)
                        }
                        ForEach(leftovers) { l in
                            Divider()
                            row(checked: !keep.contains(l.id), locked: false, name: l.name, detail: l.detail, size: l.size) {
                                if keep.contains(l.id) { keep.remove(l.id) } else { keep.insert(l.id) }
                            }
                        }
                    }
                }
                .frame(maxHeight: 280)
            }
            HStack {
                Text("Total : \(DiskFmt.size(total))").font(.headline)
                Spacer()
                Button("Annuler") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Désinstaller") {
                    working = true
                    Task {
                        let r = await cleaner.uninstall(app, leftovers: chosen)
                        if r.errors.isEmpty { store.showToast("✓ \(app.name) désinstallée (\(DiskFmt.size(r.freed)) dans la corbeille)") }
                        else { store.showToast("Désinstallation incomplète : \(r.errors[0])") }
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent).tint(.red)
                .disabled(loading || working)
            }
        }
        .padding(22)
        .frame(width: 540)
        .task {
            let a = app
            leftovers = await Task.detached { DiskScan.leftovers(of: a) }.value
            loading = false
        }
    }

    private func row(checked: Bool, locked: Bool, name: String, detail: String, size: Int64, toggle: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .foregroundStyle(checked ? (locked ? Color.secondary : Color.accentColor) : Color.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.callout).lineLimit(1).truncationMode(.middle)
                Text(detail).font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text(DiskFmt.size(size)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .contentShape(Rectangle())
        .onTapGesture { if !locked { toggle() } }
    }
}

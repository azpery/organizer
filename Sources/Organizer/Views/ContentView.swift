import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable {
    case today, assistant, timer, board, backlog, mindmap, genart, notes, artifacts, reports, invoices, projects, clients, cleaner, settings
    var id: Self { self }

    var title: String {
        switch self {
        case .today: "Aujourd'hui"
        case .assistant: "Assistant"
        case .timer: "Chrono"
        case .board: "Tableau"
        case .backlog: "Backlog"
        case .mindmap: "Mind mapping"
        case .genart: "Generative art"
        case .notes: "Notes"
        case .artifacts: "Artifacts"
        case .reports: "Rapports"
        case .invoices: "Factures"
        case .clients: "Clients"
        case .projects: "Projets"
        case .cleaner: "Nettoyage"
        case .settings: "Réglages"
        }
    }

    var icon: String {
        switch self {
        case .today: "sun.max"
        case .assistant: "sparkles"
        case .timer: "timer"
        case .board: "square.grid.3x1.below.line.grid.1x2"
        case .backlog: "tray.full"
        case .mindmap: "point.3.connected.trianglepath.dotted"
        case .genart: "paintpalette"
        case .notes: "note.text"
        case .artifacts: "sparkles.rectangle.stack"
        case .reports: "chart.bar.xaxis"
        case .invoices: "doc.text"
        case .clients: "person.2"
        case .projects: "folder"
        case .cleaner: "internaldrive"
        case .settings: "gearshape"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var store: Store
    @AppStorage("sidebar") private var selectionRaw = SidebarItem.timer.rawValue
    private var selection: Binding<SidebarItem?> {
        Binding(get: { SidebarItem(rawValue: selectionRaw) ?? .timer }, set: { selectionRaw = ($0 ?? .timer).rawValue })
    }
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationSplitView {
            List(selection: selection) {
                Section("Organizer") {
                    ForEach([SidebarItem.today, .assistant, .timer, .board, .backlog, .mindmap, .genart, .notes, .artifacts, .reports, .invoices]) { item in
                        row(item)
                    }
                }
                Section("Facettes") {
                    SidebarFacets()
                }
                Section("Configuration") {
                    ForEach([SidebarItem.projects, .clients, .cleaner, .settings]) { item in row(item) }
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
            .safeAreaInset(edge: .bottom) { SidebarTimerBadge().padding(10) }
        } detail: {
            Group {
                switch selection.wrappedValue ?? .timer {
                case .today: TodayView()
                case .assistant: AssistantView()
                case .timer: TimerView()
                case .board: BoardView()
                case .backlog: BacklogView()
                case .mindmap: MindMapView()
                case .genart: GenerativeArtView()
                case .notes: NotesView()
                case .artifacts: ArtifactsView()
                case .reports: ReportsView()
                case .invoices: InvoicesView()
                case .clients: ClientsView()
                case .projects: ProjectsView()
                case .cleaner: CleanerView()
                case .settings: SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .onAppear {
            WindowOpener.open = { openWindow(id: "main") }
            WindowOpener.openTask = { openWindow(id: "task", value: $0) }
        }
        .overlay(alignment: .bottom) {
            if let toast = store.toast {
                HStack(spacing: 8) {
                    Image(systemName: toast.hasPrefix("Jira :") || toast.hasPrefix("Ticket") || toast.hasPrefix("✓") ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(toast.hasPrefix("Jira :") || toast.hasPrefix("Ticket") || toast.hasPrefix("✓") ? .green : .orange)
                    Text(toast.hasPrefix("✓ ") ? String(toast.dropFirst(2)) : toast).font(.callout).lineLimit(2)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(Capsule().fill(.regularMaterial).shadow(color: .black.opacity(0.2), radius: 10, y: 4))
                .padding(.bottom, 20)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .onTapGesture { store.toast = nil }
            }
        }
        .animation(.spring(duration: 0.35), value: store.toast)
    }

    @ViewBuilder
    private func row(_ item: SidebarItem) -> some View {
        Label {
            HStack {
                Text(item.title)
                Spacer()
                if let count = badge(item) {
                    Text("\(count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: item.icon)
        }
        .tag(item)
    }

    private func badge(_ item: SidebarItem) -> Int? {
        switch item {
        case .board: store.tasks.filter { ($0.status == .todo || $0.status == .in_progress || $0.status == .almost_done) && store.taskInFacets($0) }.count
        case .backlog: store.tasks.filter { $0.status == .backlog && store.taskInFacets($0) }.count
        case .notes: store.notes.filter { store.inFacets($0.labels) }.count
        case .artifacts: store.artifacts.filter { store.inFacets($0.labels) }.count
        case .mindmap: store.mindmaps.filter { store.inFacets($0.labels) }.count
        case .invoices: store.invoices.filter { $0.status == .sent }.count
        default: nil
        }
    }
}

/// Running timer shown at the bottom of the sidebar.
struct SidebarTimerBadge: View {
    @EnvironmentObject var store: Store

    var body: some View {
        if let running = store.runningEntry {
            HStack(spacing: 10) {
                Circle().fill(.red).frame(width: 8, height: 8)
                    .shadow(color: .red, radius: 4)
                VStack(alignment: .leading, spacing: 2) {
                    Text(running.description.isEmpty ? "Sans description" : running.description)
                        .font(.caption.weight(.medium)).lineLimit(1)
                    LiveDuration(start: running.start, font: .system(.callout, design: .rounded).weight(.semibold))
                }
                Spacer()
                Button { store.stopTimer() } label: {
                    Image(systemName: "stop.fill").font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Arrêter")
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.regularMaterial))
        }
    }
}

/// Facet lens in the sidebar: picking facets scopes the whole app.
struct SidebarFacets: View {
    @EnvironmentObject var store: Store

    var body: some View {
        Button { withAnimation(.snappy) { store.activeFacets = [] } } label: {
            HStack {
                Image(systemName: "square.grid.2x2").frame(width: 18)
                Text("Toutes")
                Spacer()
                if store.activeFacets.isEmpty { Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(Color.accentColor) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        ForEach(store.allLabels, id: \.name) { l in
            Button {
                withAnimation(.snappy) {
                    if NSEvent.modifierFlags.contains(.command) {
                        if store.activeFacets.contains(l.name) { store.activeFacets.remove(l.name) } else { store.activeFacets.insert(l.name) }
                    } else {
                        store.activeFacets = store.activeFacets == [l.name] ? [] : [l.name]
                    }
                }
            } label: {
                HStack {
                    Circle().fill(LabelColor.color(for: l.name)).frame(width: 9, height: 9).frame(width: 18)
                    Text(l.name).lineLimit(1)
                        .fontWeight(store.activeFacets.contains(l.name) ? .semibold : .regular)
                    Spacer()
                    if store.activeFacets.contains(l.name) {
                        Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(LabelColor.color(for: l.name))
                    } else {
                        Text("\(l.count)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Clic : n'afficher que cette facette · ⌘-clic : en combiner plusieurs")
        }
    }
}

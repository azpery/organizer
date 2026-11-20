import SwiftUI

struct TaskEditTarget: Identifiable {
    let id = UUID()
    let task: TaskItem
    let isNew: Bool
}

struct BoardView: View {
    @EnvironmentObject var store: Store
    @AppStorage("board.context") private var contextRaw = ""
    @State private var projectFilter: String?
    @State private var search = ""
    @State private var editing: TaskEditTarget?
    @State private var showBacklogPicker = false
    @State private var showOldDone = false
    private var facets: Set<String> { store.activeFacets }

    private var context: Binding<WorkContext?> {
        Binding(get: { WorkContext(rawValue: contextRaw) }, set: { contextRaw = $0?.rawValue ?? "" })
    }

    private let columns: [TaskStatus] = [.todo, .in_progress, .almost_done, .done]

    var body: some View {
        let times = store.timeByTask
        VStack(spacing: 0) {
        FilterHeader(context: context, projectId: $projectFilter, facets: $store.activeFacets)
        HStack(alignment: .top, spacing: 16) {
            ForEach(columns) { status in
                BoardColumn(
                    status: status,
                    tasks: tasks(for: status),
                    times: times,
                    hiddenCount: status == .done && !showOldDone ? hiddenDoneCount : 0,
                    onShowHidden: { showOldDone = true },
                    onAdd: { newTask(status) },
                    onEdit: { editing = TaskEditTarget(task: $0, isNew: false) })
            }
        }
        .padding(20)
        }
        .navigationTitle("Tableau")
        .searchable(text: $search, placement: .toolbar, prompt: "Rechercher")
        .toolbar {
            ToolbarItemGroup {
                Button { showBacklogPicker = true } label: {
                    Label("Charger du backlog", systemImage: "tray.and.arrow.up")
                }
                .help("Ajouter des tâches du backlog au tableau")
                Button { newTask(.todo) } label: { Label("Nouvelle tâche", systemImage: "plus") }
            }
        }
        .sheet(item: $editing) { t in TaskEditor(task: t.task, isNew: t.isNew).environmentObject(store) }
        .sheet(isPresented: $showBacklogPicker) {
            BacklogPicker(context: context.wrappedValue, projectId: projectFilter, facets: facets).environmentObject(store)
        }
    }

    private var doneCutoff: Date { Calendar.app.date(byAdding: .day, value: -14, to: Date())! }

    private func tasks(for status: TaskStatus) -> [TaskItem] {
        var list = store.tasks(status: status, context: context.wrappedValue, projectId: projectFilter, labels: facets, search: search)
        if status == .done {
            list.sort { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
            if !showOldDone { list = list.filter { ($0.completedAt ?? .distantPast) >= doneCutoff } }
        }
        return list
    }

    private var hiddenDoneCount: Int {
        store.tasks(status: .done, context: context.wrappedValue, projectId: projectFilter, labels: facets, search: search)
            .filter { ($0.completedAt ?? .distantPast) < doneCutoff }.count
    }

    private func newTask(_ status: TaskStatus) {
        var t = TaskItem(title: "")
        t.status = status
        t.projectId = projectFilter
        t.context = context.wrappedValue ?? store.project(projectFilter)?.context ?? .pro
        t.labels = Array(facets).sorted()
        editing = TaskEditTarget(task: t, isNew: true)
    }
}

struct BoardColumn: View {
    @EnvironmentObject var store: Store
    let status: TaskStatus
    let tasks: [TaskItem]
    let times: [String: TimeInterval]
    var hiddenCount = 0
    var onShowHidden: () -> Void = {}
    let onAdd: () -> Void
    let onEdit: (TaskItem) -> Void
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: status.icon).foregroundStyle(status.color)
                Text(status.label).font(.headline)
                Text("\(tasks.count)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(status.color.opacity(0.15)))
                    .foregroundStyle(status.color)
                Spacer()
                Button(action: onAdd) { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .help("Ajouter une tâche")
            }
            .padding(.horizontal, 4)

            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(tasks) { task in
                        TaskCard(task: task, tracked: times[task.id] ?? 0, onEdit: { onEdit(task) })
                    }
                    if tasks.isEmpty {
                        Text(status == .todo ? "Glisse des tâches ici\nou charge-les depuis le backlog" : "Glisse des tâches ici")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity, minHeight: 90)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                                    .foregroundStyle(.quaternary)
                            )
                    }
                    if hiddenCount > 0 {
                        Button("+ \(hiddenCount) terminées il y a plus de 14 jours", action: onShowHidden)
                            .buttonStyle(.link)
                            .font(.caption)
                            .padding(.top, 4)
                    }
                }
                .padding(2)
            }
            .scrollIndicators(.never)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(targeted ? status.color.opacity(0.10) : Color.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(targeted ? status.color.opacity(0.6) : .clear, lineWidth: 2)
        )
        .animation(.easeOut(duration: 0.15), value: targeted)
        .dropDestination(for: String.self) { ids, _ in
            withAnimation(.spring(duration: 0.3)) {
                for id in ids { store.moveTask(id, to: status) }
            }
            return !ids.isEmpty
        } isTargeted: { targeted = $0 }
    }
}

struct TaskCard: View {
    @EnvironmentObject var store: Store
    @Environment(\.openWindow) private var openWindow
    let task: TaskItem
    let tracked: TimeInterval
    let onEdit: () -> Void
    @State private var hover = false

    private var isTracking: Bool { store.runningEntry?.taskId == task.id }

    var body: some View {
        let project = store.project(task.projectId)
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 6) {
                    if task.jiraKey != nil || task.priority > 0 {
                        HStack(spacing: 6) {
                            if let key = task.jiraKey { Pill(text: key, color: .blue, systemImage: "ticket") }
                            PriorityIcon(priority: task.priority)
                        }
                    }
                    Text(task.title.isEmpty ? "(sans titre)" : task.title)
                        .font(.system(.body, weight: .medium))
                        .strikethrough(task.status == .done, color: .secondary)
                        .foregroundStyle(task.status == .done ? .secondary : .primary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    if !task.labels.isEmpty {
                        FlowLayout(spacing: 4) {
                            ForEach(task.labels, id: \.self) { LabelChip(name: $0, compact: true) }
                        }
                    }
                    if let mrs = store.mergeRequests[task.id], let first = mrs.first {
                        MRBadge(mr: first, extra: mrs.count - 1)
                    }
                }
                Spacer(minLength: 0)
                if task.status != .done {
                    Button {
                        if isTracking { store.stopTimer() }
                        else { store.startTimer(description: task.title, projectId: task.projectId, taskId: task.id) }
                    } label: {
                        Image(systemName: isTracking ? "stop.fill" : "play.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(isTracking ? Color.red : Color.accentColor))
                    }
                    .buttonStyle(.plain)
                    .opacity(hover || isTracking ? 1 : 0)
                    .help(isTracking ? "Arrêter le chrono" : "Lancer le chrono sur cette tâche")
                }
            }

            HStack(spacing: 8) {
                if let project {
                    HStack(spacing: 5) {
                        Circle().fill(Color(hex: project.color)).frame(width: 7, height: 7)
                        Text(project.name).lineLimit(1)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Image(systemName: task.context.icon).font(.caption2).foregroundStyle(.tertiary)
                let linked = store.artifacts.filter { $0.taskId == task.id }.count + store.notes.filter { $0.taskId == task.id }.count
                if linked > 0 {
                    Label("\(linked)", systemImage: "paperclip")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .help("Notes et artifacts liés (double-clic pour les voir)")
                }
                Spacer(minLength: 0)
                if let due = task.dueDate {
                    Label(Fmt.date(due), systemImage: "calendar")
                        .font(.caption2)
                        .foregroundStyle(due < Date() && task.status != .done ? .red : .secondary)
                }
                if isTracking {
                    if let r = store.runningEntry {
                        LiveDuration(start: r.start, font: .caption.weight(.semibold))
                            .foregroundStyle(.red)
                    }
                } else if tracked > 0 {
                    Label(Fmt.short(tracked), systemImage: "clock")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if let est = task.estimateMinutes, est > 0 {
                ProgressView(value: min(tracked / Double(est * 60), 1))
                    .tint(tracked > Double(est * 60) ? .red : .accentColor)
                    .controlSize(.mini)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(hover ? 0.12 : 0.05), radius: hover ? 8 : 3, y: hover ? 3 : 1)
        )
        .overlay(alignment: .leading) {
            if let project {
                UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 12)
                    .fill(Color(hex: project.color))
                    .frame(width: 4)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isTracking ? Color.red.opacity(0.5) : Color.primary.opacity(0.06), lineWidth: isTracking ? 1.5 : 1)
        )
        .scaleEffect(hover ? 1.01 : 1)
        .animation(.easeOut(duration: 0.15), value: hover)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(count: 2) { openWindow(id: "task", value: task.id) }
        .draggable(task.id) {
            Text(task.title).padding(8).background(RoundedRectangle(cornerRadius: 8).fill(.regularMaterial))
        }
        .contextMenu { TaskContextMenu(task: task, onEdit: onEdit) }
    }
}

struct TaskContextMenu: View {
    @EnvironmentObject var store: Store
    @Environment(\.openWindow) private var openWindow
    let task: TaskItem
    let onEdit: () -> Void

    var body: some View {
        Button("Ouvrir la fiche") { openWindow(id: "task", value: task.id) }
        Button("Modifier…", action: onEdit)
        Button("Lancer le chrono") {
            store.startTimer(description: task.title, projectId: task.projectId, taskId: task.id)
        }
        Menu("Déplacer vers") {
            ForEach(TaskStatus.allCases) { s in
                Button { store.moveTask(task.id, to: s) } label: { Label(s.label, systemImage: s.icon) }
                    .disabled(s == task.status)
            }
        }
        Menu("Priorité") {
            ForEach([3, 2, 1, 0], id: \.self) { p in
                Button(["Aucune", "Basse", "Moyenne", "Haute"][p]) {
                    var t = task; t.priority = p; store.upsertTask(t)
                }
            }
        }
        if let key = task.jiraKey, let url = task.url.flatMap(URL.init(string:)) ?? Jira.browseURL(key) {
            Button("Ouvrir \(key) dans Jira") { NSWorkspace.shared.open(url) }
        }
        Divider()
        Button("Supprimer", role: .destructive) { store.deleteTask(task.id) }
    }
}

/// Sheet to pull backlog items onto the board.
struct BacklogPicker: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let context: WorkContext?
    let projectId: String?
    var facets: Set<String> = []
    @State private var selected: Set<String> = []
    @State private var search = ""

    var body: some View {
        let items = store.tasks(status: .backlog, context: context, projectId: projectId, labels: facets, search: search)
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Charger depuis le backlog").font(.title2.weight(.semibold))
                    Text("Sélectionne les tâches à placer dans « À faire »").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)
            TextField("Rechercher…", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 20)
                .padding(.bottom, 10)
            List {
                ForEach(items) { t in
                    Toggle(isOn: Binding(
                        get: { selected.contains(t.id) },
                        set: { if $0 { selected.insert(t.id) } else { selected.remove(t.id) } })
                    ) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(t.title)
                                HStack(spacing: 6) {
                                    ProjectLabel(projectId: t.projectId, font: .caption)
                                    ForEach(t.labels, id: \.self) { LabelChip(name: $0, compact: true) }
                                }
                            }
                            Spacer()
                            if let key = t.jiraKey { Pill(text: key, color: .blue) }
                            PriorityIcon(priority: t.priority)
                        }
                    }
                    .toggleStyle(.checkbox)
                    .padding(.vertical, 3)
                }
                if items.isEmpty { EmptyState(icon: "tray", title: "Backlog vide") }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            HStack {
                Button(selected.count == items.count && !items.isEmpty ? "Tout désélectionner" : "Tout sélectionner") {
                    selected = selected.count == items.count ? [] : Set(items.map(\.id))
                }
                .disabled(items.isEmpty)
                Spacer()
                Button("Annuler") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Ajouter \(selected.count) tâche\(selected.count > 1 ? "s" : "")") {
                    withAnimation { for id in selected { store.moveTask(id, to: .todo) } }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(selected.isEmpty)
            }
            .padding(20)
        }
        .frame(width: 560, height: 560)
    }
}

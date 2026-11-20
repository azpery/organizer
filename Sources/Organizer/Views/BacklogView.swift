import SwiftUI

struct BacklogView: View {
    @EnvironmentObject var store: Store
    @Environment(\.openWindow) private var openWindow
    @State private var quickTitle = ""
    @State private var selection: Set<String> = []
    @State private var search = ""
    @State private var context: WorkContext?
    @State private var projectFilter: String?
    @State private var editing: TaskEditTarget?
    @State private var jiraMessage: String?
    @State private var importingJira = false
    private var facets: Set<String> { store.activeFacets }

    var body: some View {
        let items = store.tasks(status: .backlog, context: context, projectId: projectFilter, labels: facets, search: search)
        let times = store.timeByTask
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "plus.circle.fill").foregroundStyle(Color.accentColor).font(.title3)
                TextField("Ajouter une tâche au backlog… (Entrée)", text: $quickTitle)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .onSubmit(addQuick)
                if let p = store.project(projectFilter) {
                    Pill(text: p.name, color: Color(hex: p.color))
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
            .padding([.horizontal, .top], 20)
            .padding(.bottom, 10)

            FilterHeader(context: $context, projectId: $projectFilter, facets: $store.activeFacets).padding(.top, -14).padding(.bottom, 10)

            if let jiraMessage {
                Text(jiraMessage).font(.callout).foregroundStyle(.secondary).padding(.bottom, 8)
            }

            if items.isEmpty {
                Spacer()
                EmptyState(icon: "tray", title: "Backlog vide",
                           message: "Ajoute des idées ici, puis charge-les dans le tableau quand tu es prêt.")
                Spacer()
            } else {
                List(items, selection: $selection) { t in
                    BacklogRow(task: t, tracked: times[t.id] ?? 0)
                }
                .listStyle(.inset(alternatesRowBackgrounds: false))
                .contextMenu(forSelectionType: String.self) { ids in
                    Button("Ajouter au tableau (À faire)") { moveToBoard(ids) }
                    if ids.count == 1, let t = store.task(ids.first) {
                        Button("Ouvrir la fiche") { openWindow(id: "task", value: t.id) }
                        Button("Modifier…") { editing = TaskEditTarget(task: t, isNew: false) }
                        Button("Lancer le chrono") { store.startTimer(description: t.title, projectId: t.projectId, taskId: t.id) }
                    }
                    Divider()
                    Button("Supprimer", role: .destructive) { ids.forEach(store.deleteTask) }
                } primaryAction: { ids in
                    if let id = ids.first { openWindow(id: "task", value: id) }
                }
                .onDeleteCommand { selection.forEach(store.deleteTask); selection = [] }
            }
        }
        .navigationTitle("Backlog")
        .searchable(text: $search, placement: .toolbar, prompt: "Rechercher")
        .toolbar {
            ToolbarItemGroup {
                if Jira.isConfigured && !Jira.projectKey.isEmpty {
                    Button { importJira() } label: {
                        Label("Importer \(Jira.projectKey)", systemImage: "arrow.down.circle")
                    }
                    .disabled(importingJira)
                    .help("Importer mes tickets Jira \(Jira.projectKey) non terminés")
                }
                Button { moveToBoard(selection) } label: {
                    Label("Au tableau", systemImage: "arrow.right.circle.fill")
                }
                .disabled(selection.isEmpty)
                .help("Placer la sélection dans « À faire »")
            }
        }
        .sheet(item: $editing) { t in TaskEditor(task: t.task, isNew: t.isNew).environmentObject(store) }
    }

    private func addQuick() {
        let title = quickTitle.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        var t = TaskItem(title: title)
        t.projectId = projectFilter
        t.context = context ?? store.project(projectFilter)?.context ?? .pro
        t.labels = Array(facets).sorted()
        if let key = Jira.detectKey(in: title) {
            t.jiraKey = key
            t.url = Jira.browseURL(key)?.absoluteString
        }
        withAnimation { store.upsertTask(t) }
        quickTitle = ""
    }

    private func moveToBoard(_ ids: Set<String>) {
        withAnimation { ids.forEach { store.moveTask($0, to: .todo) } }
        selection.subtract(ids)
    }

    private func importJira() {
        importingJira = true
        Task {
            do { jiraMessage = try await Jira.importIssues(store: store) }
            catch let e as APIError { jiraMessage = e.message }
            catch { jiraMessage = error.localizedDescription }
            importingJira = false
        }
    }
}

struct BacklogRow: View {
    @EnvironmentObject var store: Store
    let task: TaskItem
    let tracked: TimeInterval

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 2)
                .fill(store.project(task.projectId).map { Color(hex: $0.color) } ?? Color.secondary.opacity(0.3))
                .frame(width: 4, height: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(task.title).font(.body.weight(.medium)).lineLimit(1)
                HStack(spacing: 8) {
                    ProjectLabel(projectId: task.projectId, font: .caption)
                    ForEach(task.labels, id: \.self) { LabelChip(name: $0, compact: true) }
                    Image(systemName: task.context.icon).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if tracked > 0 {
                Label(Fmt.short(tracked), systemImage: "clock").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if let mrs = store.mergeRequests[task.id], let first = mrs.first { MRBadge(mr: first, extra: mrs.count - 1) }
            if let key = task.jiraKey { Pill(text: key, color: .blue, systemImage: "ticket") }
            PriorityIcon(priority: task.priority)
        }
        .padding(.vertical, 4)
    }
}

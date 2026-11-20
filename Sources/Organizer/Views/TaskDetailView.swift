import SwiftUI

/// Jira-like task page: rich description and context on the left, details panel on the right.
struct TaskDetailView: View {
    @EnvironmentObject var store: Store
    let taskId: String
    @State private var jira: JiraIssueDetail?
    @State private var jiraError: String?
    @State private var loadingJira = false
    @State private var editing: TaskEditTarget?
    @AppStorage("taskDetail.jiraExpanded") private var jiraExpanded = true

    var body: some View {
        if let task = store.task(taskId) {
            HStack(alignment: .top, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        header(task)
                        mainContent(task)
                    }
                    .padding(28)
                    .frame(maxWidth: 820, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                ScrollView {
                    sidebar(task).padding(20)
                }
                .frame(width: 320)
                .background(Color.primary.opacity(0.02))
            }
            .navigationTitle(task.jiraKey.map { "\($0) · \(task.title)" } ?? task.title)
            .task(id: task.jiraKey) { await loadJira(task) }
            .sheet(item: $editing) { t in TaskEditor(task: t.task, isNew: false).environmentObject(store) }
        } else {
            EmptyState(icon: "questionmark.square.dashed", title: "Tâche introuvable")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func loadJira(_ task: TaskItem) async {
        guard let key = task.jiraKey, Jira.isConfigured else { return }
        loadingJira = true
        do { jira = try await Jira.issueDetail(key: key); jiraError = nil }
        catch { jiraError = (error as? APIError)?.message ?? error.localizedDescription }
        loadingJira = false
    }

    // MARK: Header

    @ViewBuilder
    private func header(_ task: TaskItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                if let p = store.project(task.projectId) {
                    Circle().fill(Color(hex: p.color)).frame(width: 8, height: 8)
                    Text(p.name).foregroundStyle(.secondary)
                    Text("/").foregroundStyle(.tertiary)
                }
                if let type = jira?.type { Text(type).foregroundStyle(.secondary); Text("/").foregroundStyle(.tertiary) }
                if let key = task.jiraKey {
                    Button(key) { open(task) }.buttonStyle(.link)
                }
                if loadingJira { ProgressView().controlSize(.mini).padding(.leading, 4) }
            }
            .font(.callout)

            Text(task.title)
                .font(.system(size: 26, weight: .bold))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                PlayButton(task: task)
                Text(store.runningEntry?.taskId == task.id ? "Chrono en cours" : "Lancer le chrono").font(.callout).foregroundStyle(.secondary)
                Divider().frame(height: 18)
                Button { editing = TaskEditTarget(task: task, isNew: false) } label: { Label("Modifier", systemImage: "pencil") }
                if task.jiraKey != nil {
                    Button { open(task) } label: { Label("Ouvrir dans Jira", systemImage: "arrow.up.right.square") }
                }
                Spacer()
            }
            .controlSize(.regular)
        }
    }

    private func open(_ task: TaskItem) {
        if let u = task.url.flatMap(URL.init(string:)) ?? task.jiraKey.flatMap(Jira.browseURL) { NSWorkspace.shared.open(u) }
    }

    // MARK: Main column

    @ViewBuilder
    private func mainContent(_ task: TaskItem) -> some View {
        let notes = store.notes.filter { $0.taskId == task.id }.sorted { ($0.pinned ? 1 : 0, $0.createdAt) > ($1.pinned ? 1 : 0, $1.createdAt) }
        let artifacts = store.artifacts.filter { $0.taskId == task.id }
        let mrs = store.mergeRequests[task.id] ?? []
        let entries = store.entries.filter { $0.taskId == task.id }

        // Notes: my own notes on the ticket, first
        section("Notes", icon: "note.text", count: notes.isEmpty ? nil : notes.count) {
            VStack(alignment: .leading, spacing: 10) {
                NoteComposer(task: task)
                ForEach(notes) { n in TaskNoteCard(note: n, onOpen: { openNote(n.id) }) }
            }
        }

        if task.jiraKey == nil, !task.notes.isEmpty {
            section("Description", icon: "text.alignleft") { MarkdownPreview(text: task.notes) }
        } else if !task.notes.isEmpty {
            section("Suivi", icon: "list.bullet.clipboard") { MarkdownPreview(text: task.notes) }
        }

        // Links: Jira, GitLab, artifacts
        if task.jiraKey != nil || !mrs.isEmpty || !artifacts.isEmpty || task.url != nil {
            section("Liens", icon: "link") {
                VStack(alignment: .leading, spacing: 8) {
                    if let key = task.jiraKey {
                        LinkRow(icon: "ticket", color: .blue, title: "Jira · \(key)",
                                subtitle: jira.map { "\($0.status)\($0.assignee.map { " · \($0)" } ?? "")" } ?? "Ticket Jira") { open(task) }
                    } else if let u = task.url.flatMap(URL.init(string:)) {
                        LinkRow(icon: "globe", color: .gray, title: u.host ?? "Lien", subtitle: u.absoluteString) { NSWorkspace.shared.open(u) }
                    }
                    ForEach(mrs) { MRRow(mr: $0) }
                    if task.jiraKey != nil, mrs.isEmpty, GitLab.isConfigured {
                        Text("Aucune MR GitLab ne mentionne \(task.jiraKey!) (titre, branche ou description).")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                    ForEach(artifacts) { a in
                        LinkRow(icon: a.kind.icon, color: a.kind.color, title: a.title, subtitle: a.kind.label) {
                            if let u = URL(string: a.url) { NSWorkspace.shared.open(u) }
                        }
                    }
                }
            }
        }

        if let err = jiraError {
            Label(err, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
        }

        // Jira ticket, collapsible
        if task.jiraKey != nil {
            VStack(alignment: .leading, spacing: 14) {
                Button { withAnimation(.snappy) { jiraExpanded.toggle() } } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.right").font(.caption.weight(.bold))
                            .rotationEffect(.degrees(jiraExpanded ? 90 : 0)).foregroundStyle(.secondary)
                        Image(systemName: "ticket").foregroundStyle(.blue)
                        Text("Ticket Jira").font(.headline)
                        if let j = jira { Pill(text: j.status, color: .blue) }
                        if let j = jira, !j.comments.isEmpty {
                            Label("\(j.comments.count)", systemImage: "bubble.left").font(.caption).foregroundStyle(.secondary)
                        }
                        if loadingJira { ProgressView().controlSize(.mini) }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if jiraExpanded {
                    VStack(alignment: .leading, spacing: 22) { jiraContent() }
                        .padding(.leading, 20)
                        .transition(.opacity)
                }
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.blue.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.blue.opacity(0.15)))
        }

        if !entries.isEmpty {
            section("Temps passé", icon: "clock", count: entries.count) {
                VStack(spacing: 0) {
                    ForEach(Array(entries.prefix(15).enumerated()), id: \.element.id) { i, e in
                        if i > 0 { Divider() }
                        HStack {
                            Text(Fmt.dayHeader(e.start)).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
                            Text(e.description.isEmpty ? "—" : e.description).lineLimit(1)
                            Spacer()
                            Text(Fmt.hms(e.duration)).monospacedDigit()
                        }
                        .font(.callout)
                        .padding(.vertical, 6)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func jiraContent() -> some View {
        section("Description", icon: "text.alignleft") {
            if let d = jira?.descriptionMarkdown, !d.isEmpty {
                MarkdownPreview(text: d)
            } else if loadingJira {
                Text("Chargement depuis Jira…").foregroundStyle(.secondary)
            } else {
                Text("Aucune description.").foregroundStyle(.tertiary)
            }
        }

        if let j = jira, !(j.links.isEmpty && j.parent == nil) {
            section("Tickets liés", icon: "link", count: j.links.count + (j.parent == nil ? 0 : 1)) {
                VStack(spacing: 6) {
                    ForEach(([j.parent].compactMap { $0 } + j.links)) { l in
                        HStack(spacing: 8) {
                            Text(l.relation).font(.caption).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
                            Button(l.key) { if let u = Jira.browseURL(l.key) { NSWorkspace.shared.open(u) } }.buttonStyle(.link)
                            Text(l.summary).lineLimit(1)
                            Spacer()
                            Pill(text: l.status, color: .secondary)
                        }
                    }
                }
            }
        }

        if let j = jira, !j.attachments.isEmpty {
            section("Pièces jointes", icon: "paperclip", count: j.attachments.count) {
                FlowLayout(spacing: 8) {
                    ForEach(j.attachments) { a in
                        Button { if let u = URL(string: a.url) { NSWorkspace.shared.open(u) } } label: {
                            Label(a.filename, systemImage: "doc").font(.callout)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }

        if let j = jira {
            section("Commentaires Jira", icon: "bubble.left.and.bubble.right", count: j.comments.count) {
                if j.comments.isEmpty {
                    Text("Aucun commentaire.").foregroundStyle(.tertiary)
                } else {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(j.comments) { c in
                            HStack(alignment: .top, spacing: 10) {
                                Avatar(name: c.author)
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text(c.author).font(.callout.weight(.semibold))
                                        if let d = c.date { Text("\(Fmt.date(d)) à \(Fmt.time(d))").font(.caption).foregroundStyle(.secondary) }
                                    }
                                    MarkdownPreview(text: c.markdown)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func openNote(_ id: String) {
        UserDefaults.standard.set(id, forKey: "notes.selected")
        UserDefaults.standard.set(SidebarItem.notes.rawValue, forKey: "sidebar")
        WindowOpener.showMain()
    }

    private func section<Content: View>(_ title: String, icon: String, count: Int? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(.secondary)
                Text(title).font(.headline)
                if let count { Text("\(count)").font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
            }
            content()
        }
    }

    // MARK: Sidebar

    @ViewBuilder
    private func sidebar(_ task: TaskItem) -> some View {
        let tracked = store.trackedTime(task: task.id)
        VStack(alignment: .leading, spacing: 18) {
            Menu {
                ForEach(TaskStatus.allCases) { s in
                    Button { store.moveTask(task.id, to: s) } label: { Label(s.label, systemImage: s.icon) }
                }
            } label: {
                Label(task.status.label, systemImage: task.status.icon).fontWeight(.semibold)
            }
            .menuStyle(.button)
            .buttonStyle(.borderedProminent)
            .tint(task.status.color)
            .controlSize(.large)
            .fixedSize()
            .help(task.jiraKey != nil ? "Change aussi le statut dans Jira" : "Changer le statut")

            Card(padding: 14) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Détails").font(.headline)
                    if let j = jira {
                        detail("Statut Jira", j.status)
                        detail("Responsable", j.assignee ?? "Non assigné")
                        detail("Rapporteur", j.reporter ?? "—")
                        if let p = j.priority { detail("Priorité Jira", p) }
                    }
                    detail("Priorité", ["Aucune", "Basse", "Moyenne", "Haute"][min(3, max(0, task.priority))])
                    if let d = task.dueDate ?? jira?.due {
                        detail("Échéance", Fmt.date(d), color: d < Date() && task.status != .done ? .red : nil)
                    }
                    detail("Contexte", task.context.label)
                    if let p = store.project(task.projectId) { detail("Projet", p.name) }
                    Divider()
                    detail("Temps passé", Fmt.short(tracked))
                    if let est = task.estimateMinutes, est > 0 {
                        detail("Estimation", Fmt.short(Double(est * 60)))
                        ProgressView(value: min(tracked / Double(est * 60), 1)).tint(tracked > Double(est * 60) ? .red : .accentColor)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Facettes").font(.headline)
                FacetChipsEditor(labels: Binding(get: { store.task(taskId)?.labels ?? [] },
                                                 set: { var t = task; t.labels = $0; store.upsertTask(t, syncToJira: false) }))
            }

            if let labels = jira?.labels, !labels.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Libellés Jira").font(.headline)
                    FlowLayout(spacing: 6) { ForEach(labels, id: \.self) { Pill(text: $0, color: .secondary) } }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                if let c = jira?.created ?? Optional(task.createdAt) { Text("Créé le \(Fmt.date(c))") }
                if let u = jira?.updated ?? Optional(task.updatedAt) { Text("Mis à jour le \(Fmt.date(u)) à \(Fmt.time(u))") }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func detail(_ label: String, _ value: String, color: Color? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.callout).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
            Text(value).font(.callout).foregroundStyle(color ?? .primary).textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}

struct Avatar: View {
    let name: String
    var body: some View {
        let initials = name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
        Text(initials.uppercased())
            .font(.caption.weight(.bold))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(Circle().fill(LabelColor.color(for: name).gradient))
    }
}

/// Quick note composer on a task page: the first line becomes the title.
struct NoteComposer: View {
    @EnvironmentObject var store: Store
    let task: TaskItem
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            TextField("Ajouter une note sur ce ticket… (Markdown, ⌘↩ pour enregistrer)", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(2...12)
                .focused($focused)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(focused ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.1)))
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                HStack {
                    Button("Annuler") { text = "" }.keyboardShortcut(.cancelAction)
                    Button("Ajouter la note") { save() }.keyboardShortcut(.return, modifiers: .command).buttonStyle(.borderedProminent)
                }
                .controlSize(.small)
            }
        }
    }

    private func save() {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        let first = body.components(separatedBy: .newlines).first ?? body
        var title = first.replacingOccurrences(of: "#", with: "").trimmingCharacters(in: .whitespaces)
        if title.count > 70 { title = String(title.prefix(70)) + "…" }
        let prefix = task.jiraKey.map { "\($0) · " } ?? ""
        _ = store.upsertNote(Note(title: prefix + title, body: body, labels: task.labels, taskId: task.id))
        text = ""
    }
}

/// A note shown in full on the task page, editable inline (Apple notes are read-only).
struct TaskNoteCard: View {
    @EnvironmentObject var store: Store
    let note: Note
    let onOpen: () -> Void
    @State private var editing = false
    @State private var draft = ""
    @State private var expanded = false
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if note.isAppleNote { Image(systemName: "applelogo").font(.caption).foregroundStyle(.secondary) }
                if note.pinned { Image(systemName: "pin.fill").font(.caption).foregroundStyle(.orange) }
                Text(note.title).font(.callout.weight(.semibold)).lineLimit(1)
                Spacer()
                Text("\(Fmt.date(note.createdAt)) à \(Fmt.time(note.createdAt))").font(.caption).foregroundStyle(.secondary)
                Menu {
                    if !note.isAppleNote { Button { draft = note.body; editing = true } label: { Label("Modifier", systemImage: "pencil") } }
                    Button { onOpen() } label: { Label("Ouvrir dans Notes", systemImage: "arrow.up.right.square") }
                    Button { var n = note; n.pinned.toggle(); _ = store.upsertNote(n, touch: false) } label: {
                        Label(note.pinned ? "Désépingler" : "Épingler", systemImage: "pin")
                    }
                    if !note.isAppleNote {
                        Divider()
                        Button(role: .destructive) { confirmDelete = true } label: { Label("Supprimer", systemImage: "trash") }
                    }
                } label: { Image(systemName: "ellipsis.circle").foregroundStyle(.secondary) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            if editing {
                TextEditor(text: $draft)
                    .font(.body)
                    .frame(minHeight: 120)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
                HStack {
                    Spacer()
                    Button("Annuler") { editing = false }
                    Button("Enregistrer") {
                        var n = note; n.body = draft; _ = store.upsertNote(n); editing = false
                    }
                    .keyboardShortcut(.return, modifiers: .command).buttonStyle(.borderedProminent)
                }
                .controlSize(.small)
            } else {
                let long = note.body.count > 700
                MarkdownPreview(text: long && !expanded ? String(note.body.prefix(700)) + "…" : note.body)
                if long {
                    Button(expanded ? "Réduire" : "Tout afficher") { withAnimation { expanded.toggle() } }
                        .buttonStyle(.link).font(.caption)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
        .onTapGesture(count: 2) { if !note.isAppleNote && !editing { draft = note.body; editing = true } }
        .confirmationDialog("Supprimer cette note ?", isPresented: $confirmDelete) {
            Button("Supprimer", role: .destructive) { store.deleteNote(note.id) }
        }
    }
}

/// Clickable link line (Jira, external URL, artifact).
struct LinkRow: View {
    let icon: String
    let color: Color
    let title: String
    let subtitle: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: 7).fill(color.gradient))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.callout.weight(.medium)).lineLimit(1)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(hover ? Color.accentColor : .secondary)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 10).fill(hover ? Color.primary.opacity(0.05) : Color(nsColor: .controlBackgroundColor)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

import SwiftUI

struct TaskEditor: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var task: TaskItem
    let isNew: Bool
    @State private var hasDue: Bool
    @State private var estimateText: String
    @FocusState private var titleFocused: Bool
    @State private var createInJira = false

    init(task: TaskItem, isNew: Bool) {
        _task = State(initialValue: task)
        self.isNew = isNew
        _hasDue = State(initialValue: task.dueDate != nil)
        _estimateText = State(initialValue: task.estimateMinutes.map { String(format: "%.1f", Double($0) / 60).replacingOccurrences(of: ".0", with: "") } ?? "")
    }

    private var entries: [TimeEntry] { store.entries.filter { $0.taskId == task.id } }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Pill(text: task.status.label, color: task.status.color, systemImage: task.status.icon)
                    if let key = task.jiraKey { Pill(text: key, color: .blue, systemImage: "ticket") }
                    Spacer()
                    if !isNew {
                        Label(Fmt.hms(entries.reduce(0) { $0 + $1.duration }), systemImage: "clock")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                TextField("Titre de la tâche", text: $task.title, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.title2.weight(.semibold))
                    .focused($titleFocused)
            }
            .padding([.horizontal, .top], 22)
            .padding(.bottom, 6)

            Form {
                Section {
                    Picker("Statut", selection: $task.status) {
                        ForEach(TaskStatus.allCases) { s in Label(s.label, systemImage: s.icon).tag(s) }
                    }
                    Picker("Projet", selection: $task.projectId) {
                        Text("Aucun").tag(String?.none)
                        ForEach(store.projects.filter { !$0.archived || $0.id == task.projectId }) { p in
                            Text(p.name).tag(Optional(p.id))
                        }
                    }
                    Picker("Contexte", selection: $task.context) {
                        ForEach(WorkContext.allCases) { c in Label(c.label, systemImage: c.icon).tag(c) }
                    }
                    .pickerStyle(.segmented)
                    Picker("Priorité", selection: $task.priority) {
                        Text("Aucune").tag(0); Text("Basse").tag(1); Text("Moyenne").tag(2); Text("Haute").tag(3)
                    }
                }
                Section("Facettes") {
                    LabelEditor(labels: $task.labels)
                }
                Section("Planification") {
                    Toggle("Échéance", isOn: $hasDue)
                    if hasDue {
                        DatePicker("Date", selection: Binding(get: { task.dueDate ?? Date() }, set: { task.dueDate = $0 }),
                                   displayedComponents: .date)
                    }
                    TextField("Estimation (heures)", text: $estimateText, prompt: Text("ex. 2,5"))
                }
                Section("Jira") {
                    if task.jiraKey == nil && Jira.isConfigured && !Jira.projectKey.isEmpty {
                        Toggle("Créer aussi le ticket dans Jira (\(Jira.projectKey))", isOn: $createInJira)
                    }
                    HStack {
                        TextField("Clé du ticket", text: Binding(
                            get: { task.jiraKey ?? "" },
                            set: { task.jiraKey = $0.isEmpty ? nil : $0.uppercased() }), prompt: Text(Jira.sampleKey()))
                        if let key = task.jiraKey, let url = Jira.browseURL(key) {
                            Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "arrow.up.right.square") }
                                .buttonStyle(.borderless)
                                .help("Ouvrir dans Jira")
                        }
                    }
                    TextField("Lien", text: Binding(get: { task.url ?? "" }, set: { task.url = $0.isEmpty ? nil : $0 }),
                              prompt: Text("https://…"))
                }
                if let mrs = store.mergeRequests[task.id], !mrs.isEmpty {
                    Section("Merge Requests GitLab") {
                        ForEach(mrs) { MRRow(mr: $0) }
                    }
                }
                let linkedNotes = store.notes.filter { $0.taskId == task.id }
                let linkedArtifacts = store.artifacts.filter { $0.taskId == task.id }
                if !linkedNotes.isEmpty || !linkedArtifacts.isEmpty {
                    Section("Notes et artifacts liés") {
                        ForEach(linkedArtifacts) { a in
                            Button { if let u = URL(string: a.url) { NSWorkspace.shared.open(u) } } label: {
                                Label(a.title, systemImage: a.kind.icon).foregroundStyle(a.kind.color)
                            }
                            .buttonStyle(.plain)
                        }
                        ForEach(linkedNotes) { n in
                            Label(n.title, systemImage: "note.text").foregroundStyle(.secondary)
                        }
                    }
                }
                Section("Notes") {
                    TextEditor(text: $task.notes)
                        .font(.body)
                        .frame(minHeight: 70)
                        .scrollContentBackground(.hidden)
                }
                if !entries.isEmpty {
                    Section("Temps passé (\(entries.count) entrées)") {
                        ForEach(entries.prefix(8)) { e in
                            HStack {
                                Text(Fmt.dayHeader(e.start)).foregroundStyle(.secondary)
                                Text(e.description).lineLimit(1)
                                Spacer()
                                Text(Fmt.hms(e.duration)).monospacedDigit()
                            }
                            .font(.callout)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                if !isNew {
                    Button("Supprimer", role: .destructive) {
                        store.deleteTask(task.id)
                        dismiss()
                    }
                    .foregroundStyle(.red)
                }
                Spacer()
                Button("Annuler") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Créer" : "Enregistrer", action: save)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(task.title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(22)
        }
        .frame(width: 580, height: 720)
        .onAppear { if isNew { titleFocused = true } }
        .onChange(of: task.projectId) { _, newValue in
            if let p = store.project(newValue) { task.context = p.context }
        }
    }

    private func save() {
        var t = task
        t.title = t.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !hasDue { t.dueDate = nil }
        let est = Double(estimateText.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces))
        t.estimateMinutes = est.map { Int(($0 * 60).rounded()) }
        if t.jiraKey == nil, let key = Jira.detectKey(in: t.title) { t.jiraKey = key }
        if let key = t.jiraKey, t.url == nil { t.url = Jira.browseURL(key)?.absoluteString }
        let saved = store.upsertTask(t)
        if createInJira, saved.jiraKey == nil {
            let s = store
            Task {
                do { _ = try await s.createJiraIssue(for: saved.id) }
                catch { s.showToast((error as? APIError)?.message ?? error.localizedDescription) }
            }
        }
        dismiss()
    }
}

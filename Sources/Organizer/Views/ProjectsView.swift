import SwiftUI

struct ProjectsView: View {
    @EnvironmentObject var store: Store
    @State private var newName = ""
    @State private var showArchived = false
    @State private var confirmDelete: Project?

    var body: some View {
        let totals = projectTotals
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Image(systemName: "folder.badge.plus").foregroundStyle(Color.accentColor).font(.title3)
                    TextField("Nouveau projet… (Entrée)", text: $newName)
                        .textFieldStyle(.plain).font(.title3)
                        .onSubmit {
                            let name = newName.trimmingCharacters(in: .whitespaces)
                            guard !name.isEmpty else { return }
                            withAnimation { store.upsertProject(Project(name: name)) }
                            newName = ""
                        }
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))

                FacetBar(selected: $store.activeFacets).padding(.horizontal, -20)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 14)], spacing: 14) {
                    ForEach(store.projects.filter { (showArchived || !$0.archived) && store.projectInFacets($0) }) { p in
                        ProjectCard(project: p, total: totals[p.id] ?? 0,
                                    openTasks: store.tasks.filter { $0.projectId == p.id && $0.status != .done }.count,
                                    onDelete: { confirmDelete = p })
                    }
                }
                if store.projects.isEmpty {
                    Card { EmptyState(icon: "folder", title: "Aucun projet", message: "Crée un projet ou importe-les depuis Clockify (Réglages).") }
                }
            }
            .padding(24)
        }
        .navigationTitle("Projets")
        .toolbar {
            Toggle(isOn: $showArchived) { Label("Archivés", systemImage: "archivebox") }
                .help("Afficher les projets archivés")
        }
        .confirmationDialog("Supprimer « \(confirmDelete?.name ?? "") » ?", isPresented: Binding(
            get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Supprimer", role: .destructive) {
                if let p = confirmDelete { store.deleteProject(p.id) }
            }
        } message: {
            Text("Les tâches et entrées de temps seront conservées, sans projet.")
        }
    }

    private var projectTotals: [String: TimeInterval] {
        var map: [String: TimeInterval] = [:]
        for e in store.entries { if let p = e.projectId { map[p, default: 0] += e.duration } }
        return map
    }
}

struct ProjectCard: View {
    @EnvironmentObject var store: Store
    let project: Project
    let total: TimeInterval
    let openTasks: Int
    let onDelete: () -> Void

    private func binding<T>(_ kp: WritableKeyPath<Project, T>) -> Binding<T> {
        Binding(get: { project[keyPath: kp] }, set: { v in
            var p = project
            p[keyPath: kp] = v
            store.upsertProject(p)
        })
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    ColorPicker("", selection: Binding(
                        get: { Color(hex: project.color) },
                        set: { var p = project; p.color = $0.hexString; store.upsertProject(p) }), supportsOpacity: false)
                        .labelsHidden()
                        .frame(width: 26)
                    TextField("Nom", text: binding(\.name))
                        .textFieldStyle(.plain)
                        .font(.headline)
                    Spacer()
                    Menu {
                        Button(project.archived ? "Désarchiver" : "Archiver") {
                            var p = project; p.archived.toggle(); store.upsertProject(p)
                        }
                        Divider()
                        Button("Supprimer…", role: .destructive, action: onDelete)
                    } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                }
                TextField("Client", text: Binding(
                    get: { project.client ?? "" },
                    set: { var p = project; p.client = $0.isEmpty ? nil : $0; store.upsertProject(p) }),
                    prompt: Text("Client"))
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Picker("", selection: binding(\.context)) {
                        ForEach(WorkContext.allCases) { c in Label(c.label, systemImage: c.icon).tag(c) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    Spacer()
                    if project.archived { Pill(text: "Archivé", color: .secondary, systemImage: "archivebox") }
                    if project.clockifyId != nil { Pill(text: "Clockify", color: .teal) }
                }
                FacetChipsEditor(labels: binding(\.labels))
                Divider()
                HStack {
                    Label("\(openTasks) tâche\(openTasks > 1 ? "s" : "") ouvertes", systemImage: "checklist")
                    Spacer()
                    Label(Fmt.short(total), systemImage: "clock")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
        .overlay(alignment: .top) {
            UnevenRoundedRectangle(topLeadingRadius: 14, topTrailingRadius: 14)
                .fill(Color(hex: project.color))
                .frame(height: 4)
        }
        .opacity(project.archived ? 0.6 : 1)
    }
}

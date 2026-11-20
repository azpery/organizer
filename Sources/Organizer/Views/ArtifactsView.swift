import SwiftUI

struct ArtifactEditTarget: Identifiable {
    let id = UUID()
    let item: ArtifactItem
    let isNew: Bool
}

struct ArtifactsView: View {
    @EnvironmentObject var store: Store
    @State private var search = ""
    @State private var kind: ArtifactKind?
    @State private var editing: ArtifactEditTarget?

    private var items: [ArtifactItem] {
        store.artifacts.filter { a in
            store.inFacets(a.labels)
                && (kind == nil || a.kind == kind)
                && (search.isEmpty || a.title.localizedCaseInsensitiveContains(search) || a.summary.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        let list = items
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Picker("Type", selection: $kind) {
                        Text("Tous les types").tag(ArtifactKind?.none)
                        Divider()
                        ForEach(ArtifactKind.allCases) { k in Label(k.label, systemImage: k.icon).tag(Optional(k)) }
                    }
                    .labelsHidden().fixedSize()
                    Spacer()
                    Text("\(list.count) élément\(list.count > 1 ? "s" : "")").font(.callout).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20)
                FacetBar(selected: $store.activeFacets)

                if list.isEmpty {
                    Card {
                        EmptyState(icon: "sparkles", title: "Aucun artifact",
                                   message: "Les artifacts, documents et liens que Claude crée pour toi apparaissent ici, rangés par facette.")
                    }
                    .padding(.horizontal, 20)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 14)], spacing: 14) {
                        ForEach(list) { a in
                            ArtifactCard(item: a, onEdit: { editing = ArtifactEditTarget(item: a, isNew: false) })
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }
            .padding(.vertical, 16)
        }
        .navigationTitle("Artifacts")
        .searchable(text: $search, placement: .toolbar, prompt: "Rechercher")
        .toolbar {
            Button {
                editing = ArtifactEditTarget(item: ArtifactItem(title: "", url: "", kind: .link, labels: Array(store.activeFacets).sorted()), isNew: true)
            } label: { Label("Ajouter", systemImage: "plus") }
        }
        .sheet(item: $editing) { t in ArtifactEditor(item: t.item, isNew: t.isNew).environmentObject(store) }
    }
}

struct ArtifactCard: View {
    @EnvironmentObject var store: Store
    let item: ArtifactItem
    let onEdit: () -> Void
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: item.kind.icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(item.kind.color.gradient))
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title.isEmpty ? "Sans titre" : item.title).font(.headline).lineLimit(2)
                    Text("\(item.kind.label) · \(Fmt.date(item.createdAt))").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
                    .opacity(hover ? 1 : 0)
            }
            if !item.summary.isEmpty {
                Text(item.summary).font(.callout).foregroundStyle(.secondary).lineLimit(3)
            }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                ForEach(item.labels, id: \.self) { LabelChip(name: $0, compact: true) }
                if let t = store.task(item.taskId) {
                    Pill(text: t.jiraKey ?? t.title, color: .blue, systemImage: "checklist")
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(hover ? 0.14 : 0.05), radius: hover ? 10 : 4, y: hover ? 4 : 1)
        )
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
        .scaleEffect(hover ? 1.01 : 1)
        .animation(.easeOut(duration: 0.15), value: hover)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { if let u = URL(string: item.url) { NSWorkspace.shared.open(u) } }
        .contextMenu {
            Button("Ouvrir") { if let u = URL(string: item.url) { NSWorkspace.shared.open(u) } }
            Button("Copier le lien") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.url, forType: .string)
            }
            Button("Modifier…", action: onEdit)
            Divider()
            Button("Supprimer", role: .destructive) { store.deleteArtifact(item.id) }
        }
    }
}

struct ArtifactEditor: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var item: ArtifactItem
    let isNew: Bool

    init(item: ArtifactItem, isNew: Bool) {
        _item = State(initialValue: item)
        self.isNew = isNew
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(isNew ? "Nouvel artifact" : "Artifact").font(.title2.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding([.horizontal, .top], 22)
            Form {
                TextField("Titre", text: $item.title)
                TextField("Lien", text: $item.url, prompt: Text("https://claude.ai/…"))
                Picker("Type", selection: $item.kind) {
                    ForEach(ArtifactKind.allCases) { k in Label(k.label, systemImage: k.icon).tag(k) }
                }
                TextField("Résumé", text: $item.summary, axis: .vertical).lineLimit(2...5)
                TaskLinkPicker(taskId: $item.taskId)
                Section("Facettes") { LabelEditor(labels: $item.labels) }
            }
            .formStyle(.grouped)
            HStack {
                if !isNew {
                    Button("Supprimer", role: .destructive) { store.deleteArtifact(item.id); dismiss() }.foregroundStyle(.red)
                }
                Spacer()
                Button("Annuler") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Ajouter" : "Enregistrer") { store.upsertArtifact(item); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(item.title.isEmpty || item.url.isEmpty)
            }
            .padding(22)
        }
        .frame(width: 520, height: 560)
    }
}

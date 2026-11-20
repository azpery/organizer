import SwiftUI

/// Small colored dot + "Projet: Tâche" label, Clockify style.
struct ProjectLabel: View {
    @EnvironmentObject var store: Store
    let projectId: String?
    var taskId: String? = nil
    var font: Font = .callout
    var placeholder = "Pas de projet"

    var body: some View {
        let project = store.project(projectId)
        let task = store.task(taskId)
        HStack(spacing: 6) {
            Circle()
                .fill(project.map { Color(hex: $0.color) } ?? Color.secondary.opacity(0.5))
                .frame(width: 8, height: 8)
            Group {
                if let project {
                    Text(project.name).foregroundStyle(Color(hex: project.color))
                        + Text(task.map { " › \($0.title)" } ?? "").foregroundStyle(.secondary)
                } else if let task {
                    Text(task.title).foregroundStyle(.secondary)
                } else {
                    Text(placeholder).foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
        }
        .font(font)
    }
}

/// Menu to pick a project, optionally drilling down to one of its open tasks.
struct ProjectTaskPicker: View {
    @EnvironmentObject var store: Store
    @Binding var projectId: String?
    @Binding var taskId: String?

    var body: some View {
        Menu {
            Button {
                projectId = nil; taskId = nil
            } label: { Label("Aucun projet", systemImage: "circle.dashed") }
            Divider()
            ForEach(store.activeProjects) { p in
                let tasks = store.openTasks(projectId: p.id)
                if tasks.isEmpty {
                    Button(p.name) { projectId = p.id; taskId = nil }
                } else {
                    Menu(p.name) {
                        Button("\(p.name) — sans tâche") { projectId = p.id; taskId = nil }
                        Divider()
                        ForEach(tasks) { t in
                            Button(t.jiraKey.map { "\($0) · \(t.title)" } ?? t.title) { projectId = p.id; taskId = t.id }
                        }
                    }
                }
            }
            let orphans = store.openTasks(projectId: nil)
            if !orphans.isEmpty {
                Divider()
                Menu("Tâches sans projet") {
                    ForEach(orphans) { t in Button(t.title) { projectId = nil; taskId = t.id } }
                }
            }
        } label: {
            ProjectLabel(projectId: projectId, taskId: taskId, placeholder: "Choisir un projet / une tâche")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

struct CircleIconButton: View {
    let systemImage: String
    var colors: [Color] = [Color(hex: "#4F7CFF"), Color(hex: "#7B5CFF")]
    var size: CGFloat = 44
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.36, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(Circle().fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)))
                .shadow(color: colors.first!.opacity(hover ? 0.55 : 0.3), radius: hover ? 10 : 6, y: 3)
                .scaleEffect(hover ? 1.06 : 1)
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.spring(duration: 0.25)) { hover = h } }
    }
}

/// Rounded card surface used throughout the app.
struct Card<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06))
            )
    }
}

struct Pill: View {
    let text: String
    var color: Color = .accentColor
    var systemImage: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text)
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .foregroundStyle(color)
        .background(Capsule().fill(color.opacity(0.14)))
    }
}

struct PriorityIcon: View {
    let priority: Int
    var body: some View {
        if priority > 0 {
            Image(systemName: priority >= 3 ? "flag.fill" : "flag")
                .font(.caption)
                .foregroundStyle(priority >= 3 ? .red : priority == 2 ? .orange : .secondary)
        }
    }
}

/// Segmented filter: Tous / Pro / Perso
struct ContextFilter: View {
    @Binding var context: WorkContext?
    var body: some View {
        Picker("Contexte", selection: $context) {
            Text("Tous").tag(WorkContext?.none)
            ForEach(WorkContext.allCases) { c in
                Text(c.label).tag(Optional(c))
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }
}

struct ProjectFilter: View {
    @EnvironmentObject var store: Store
    @Binding var projectId: String?
    var body: some View {
        Picker("Projet", selection: $projectId) {
            Text("Tous les projets").tag(String?.none)
            Divider()
            ForEach(store.activeProjects) { p in Text(p.name).tag(Optional(p.id)) }
        }
        .labelsHidden()
        .fixedSize()
    }
}

/// Filter row shown under the window toolbar: context, project, then facets.
struct FilterHeader<Trailing: View>: View {
    @Binding var context: WorkContext?
    @Binding var projectId: String?
    @Binding var facets: Set<String>
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                ContextFilter(context: $context)
                ProjectFilter(projectId: $projectId)
                Spacer()
                trailing
            }
            .padding(.horizontal, 20)
            FacetBar(selected: $facets)
        }
        .padding(.top, 14)
    }
}

extension FilterHeader where Trailing == EmptyView {
    init(context: Binding<WorkContext?>, projectId: Binding<String?>, facets: Binding<Set<String>>) {
        self.init(context: context, projectId: projectId, facets: facets) { EmptyView() }
    }
}

struct EmptyState: View {
    let icon: String
    let title: String
    var message: String = ""
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 30)).foregroundStyle(.tertiary)
            Text(title).font(.headline).foregroundStyle(.secondary)
            if !message.isEmpty { Text(message).font(.callout).foregroundStyle(.tertiary).multilineTextAlignment(.center) }
        }
        .frame(maxWidth: .infinity)
        .padding(30)
    }
}

/// Live HH:MM:SS display.
struct LiveDuration: View {
    let start: Date
    var font: Font = .system(size: 30, weight: .semibold, design: .rounded)
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            Text(Fmt.hms(ctx.date.timeIntervalSince(start)))
                .font(font)
                .monospacedDigit()
                .contentTransition(.numericText())
        }
    }
}

// MARK: - Facets

enum LabelColor {
    /// Stable color per facet name.
    static func color(for name: String) -> Color {
        var hash: UInt64 = 5381
        for b in name.lowercased().utf8 { hash = (hash &* 33) &+ UInt64(b) }
        return Color(hex: Palette.colors[Int(hash % UInt64(Palette.colors.count))])
    }
}

struct LabelChip: View {
    let name: String
    var selected = false
    var count: Int? = nil
    var compact = false

    var body: some View {
        let c = LabelColor.color(for: name)
        HStack(spacing: 5) {
            Circle().fill(c).frame(width: compact ? 5 : 7, height: compact ? 5 : 7)
            Text(name).lineLimit(1)
            if let count { Text("\(count)").foregroundStyle(selected ? c : Color.secondary).monospacedDigit() }
        }
        .font(compact ? .caption2.weight(.medium) : .callout.weight(.medium))
        .padding(.horizontal, compact ? 6 : 10)
        .padding(.vertical, compact ? 2 : 5)
        .foregroundStyle(selected ? c : Color.primary.opacity(compact ? 0.75 : 0.85))
        .background(Capsule().fill(c.opacity(selected ? 0.2 : (compact ? 0.12 : 0.07))))
        .overlay(Capsule().strokeBorder(selected ? c.opacity(0.7) : .clear, lineWidth: 1.2))
    }
}

/// Horizontal facet filter: "Toutes" + one chip per facet (multi-select, OR).
struct FacetBar: View {
    @EnvironmentObject var store: Store
    @Binding var selected: Set<String>

    var body: some View {
        let labels = store.allLabels
        if !labels.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    Button { withAnimation(.snappy) { selected = [] } } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "line.3.horizontal.decrease.circle")
                            Text("Toutes")
                        }
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .foregroundStyle(selected.isEmpty ? Color.white : .primary)
                        .background(Capsule().fill(selected.isEmpty ? Color.accentColor : Color.primary.opacity(0.07)))
                    }
                    .buttonStyle(.plain)
                    ForEach(labels, id: \.name) { l in
                        Button {
                            withAnimation(.snappy) {
                                if selected.contains(l.name) { selected.remove(l.name) } else { selected.insert(l.name) }
                            }
                        } label: {
                            LabelChip(name: l.name, selected: selected.contains(l.name), count: l.count)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 2)
            }
            .scrollIndicators(.never)
        }
    }
}

/// Edits a task's facets: removable chips + field with suggestions.
struct LabelEditor: View {
    @EnvironmentObject var store: Store
    @Binding var labels: [String]
    @State private var input = ""

    private var suggestions: [String] {
        store.allLabels.map(\.name).filter { name in
            !labels.contains(name) && (input.isEmpty || name.localizedCaseInsensitiveContains(input))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !labels.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(labels, id: \.self) { l in
                        HStack(spacing: 2) {
                            LabelChip(name: l, selected: true)
                            Button { labels.removeAll { $0 == l } } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            HStack {
                TextField("Ajouter une facette", text: $input, prompt: Text("ex. Refonte site"))
                    .onSubmit { add(input) }
                if !suggestions.isEmpty {
                    Menu {
                        ForEach(suggestions.prefix(30), id: \.self) { s in Button(s) { add(s) } }
                    } label: { Image(systemName: "tag") }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("Facettes existantes")
                }
            }
            if !input.isEmpty, !suggestions.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(suggestions.prefix(8), id: \.self) { s in
                        Button { add(s) } label: { LabelChip(name: s, compact: false) }.buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func add(_ raw: String) {
        let name = raw.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        // reuse existing spelling when the facet already exists
        let existing = store.allLabels.map(\.name).first { $0.caseInsensitiveCompare(name) == .orderedSame } ?? name
        if !labels.contains(existing) { labels.append(existing) }
        input = ""
    }
}

/// Simple wrapping layout for chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, width: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > maxWidth { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
            width = max(width, x - spacing)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX, x + s.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
        }
    }
}

/// Inline facet chips with a "+" popover editor.
struct FacetChipsEditor: View {
    @Binding var labels: [String]
    @State private var editing = false

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(labels, id: \.self) { LabelChip(name: $0, selected: true) }
            Button { editing = true } label: {
                Label(labels.isEmpty ? "Facette" : "", systemImage: "tag")
                    .font(.callout)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Capsule().strokeBorder(Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [3])))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .popover(isPresented: $editing, arrowEdge: .bottom) {
                LabelEditor(labels: $labels).padding(14).frame(width: 320)
            }
        }
    }
}

/// Picker for an optional linked task.
struct TaskLinkPicker: View {
    @EnvironmentObject var store: Store
    @Binding var taskId: String?

    var body: some View {
        Picker(selection: $taskId) {
            Text("Aucune tâche").tag(String?.none)
            Divider()
            ForEach(store.tasks.filter { $0.status != .done || $0.id == taskId }
                .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }) { t in
                Text(t.jiraKey.map { "\($0) · \(t.title)" } ?? t.title).tag(Optional(t.id))
            }
        } label: {
            Label("Tâche liée", systemImage: "checklist")
        }
    }
}

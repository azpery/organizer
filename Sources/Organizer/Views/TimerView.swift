import SwiftUI

struct EntryEditTarget: Identifiable {
    let id = UUID()
    let entry: TimeEntry
    let isNew: Bool
}

struct TimerView: View {
    @EnvironmentObject var store: Store
    @State private var daysShown = 14
    @State private var editing: EntryEditTarget?

    private struct DayGroup: Identifiable {
        let day: Date
        let entries: [TimeEntry]
        var id: Date { day }
        var total: TimeInterval { entries.reduce(0) { $0 + $1.duration } }
    }

    private var groups: [DayGroup] {
        let cal = Calendar.app
        let cutoff = cal.date(byAdding: .day, value: -daysShown, to: cal.startOfDay(for: Date()))!
        let list = store.entries.filter { !$0.isRunning && $0.start >= cutoff && store.entryInFacets($0) }
        return Dictionary(grouping: list) { cal.startOfDay(for: $0.start) }
            .map { DayGroup(day: $0.key, entries: $0.value.sorted { $0.start > $1.start }) }
            .sorted { $0.day > $1.day }
    }

    private func total(weekOffset: Int) -> TimeInterval {
        let cal = Calendar.app
        guard let base = cal.date(byAdding: .weekOfYear, value: weekOffset, to: Date()),
              let week = cal.dateInterval(of: .weekOfYear, for: base) else { return 0 }
        return store.entries(from: week.start, to: week.end).filter(store.entryInFacets).reduce(0) { $0 + $1.duration }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                TimerBar()
                FacetBar(selected: $store.activeFacets).padding(.horizontal, -20)

                HStack(spacing: 14) {
                    StatTile(title: "Aujourd'hui", value: Fmt.hms(todayTotal), icon: "sun.max.fill", tint: .orange)
                    StatTile(title: "Cette semaine", value: Fmt.hms(total(weekOffset: 0)), icon: "calendar", tint: .blue)
                    StatTile(title: "Semaine dernière", value: Fmt.hms(total(weekOffset: -1)), icon: "clock.arrow.circlepath", tint: .purple)
                }

                if groups.isEmpty {
                    Card { EmptyState(icon: "timer", title: "Aucune entrée", message: "Lance le chrono ou ajoute du temps manuellement.") }
                }

                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(Fmt.dayHeader(group.day)).font(.headline)
                            Spacer()
                            Text(Fmt.hms(group.total))
                                .font(.headline.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 4)
                        Card(padding: 0) {
                            VStack(spacing: 0) {
                                ForEach(Array(group.entries.enumerated()), id: \.element.id) { idx, entry in
                                    if idx > 0 { Divider().padding(.leading, 16) }
                                    EntryRow(entry: entry) { editing = EntryEditTarget(entry: entry, isNew: false) }
                                }
                            }
                        }
                    }
                }

                if !store.entries.isEmpty {
                    Button("Afficher les 2 semaines précédentes") { daysShown += 14 }
                        .buttonStyle(.link)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(24)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Chrono")
        .toolbar {
            ToolbarItem {
                Button {
                    editing = EntryEditTarget(entry: .newManual(), isNew: true)
                } label: {
                    Label("Ajouter du temps", systemImage: "plus")
                }
                .help("Ajouter une entrée manuellement")
            }
        }
        .sheet(item: $editing) { target in
            EntryEditor(entry: target.entry, isNew: target.isNew).environmentObject(store)
        }
    }

    private var todayTotal: TimeInterval {
        let start = Calendar.app.startOfDay(for: Date())
        return store.entries(from: start, to: start.addingTimeInterval(86400)).filter(store.entryInFacets).reduce(0) { $0 + $1.duration }
    }
}

struct StatTile: View {
    let title: String
    let value: String
    let icon: String
    let tint: Color

    var body: some View {
        Card {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(tint.opacity(0.14)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.caption).foregroundStyle(.secondary)
                    Text(value).font(.system(.title3, design: .rounded).weight(.semibold)).monospacedDigit()
                }
                Spacer(minLength: 0)
            }
        }
    }
}

/// "What are you working on?" bar.
struct TimerBar: View {
    @EnvironmentObject var store: Store
    var compact = false
    @State private var desc = ""
    @State private var projectId: String?
    @State private var taskId: String?
    @FocusState private var focused: Bool

    var body: some View {
        let running = store.runningEntry
        Card(padding: compact ? 12 : 18) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Sur quoi travailles-tu ?", text: $desc)
                        .textFieldStyle(.plain)
                        .font(compact ? .body : .title3)
                        .focused($focused)
                        .onSubmit(submit)
                    ProjectTaskPicker(projectId: $projectId, taskId: $taskId)
                }
                Spacer(minLength: 8)
                if let running {
                    LiveDuration(start: running.start,
                                 font: .system(size: compact ? 20 : 30, weight: .semibold, design: .rounded))
                    CircleIconButton(systemImage: "stop.fill",
                                     colors: [Color(hex: "#FF5C5C"), Color(hex: "#E8336D")],
                                     size: compact ? 36 : 48) { store.stopTimer() }
                } else {
                    Text("00:00:00")
                        .font(.system(size: compact ? 20 : 30, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                    CircleIconButton(systemImage: "play.fill", size: compact ? 36 : 48) { start() }
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(running != nil ? Color.red.opacity(0.35) : .clear, lineWidth: 1.5)
        )
        .onAppear(perform: syncFromRunning)
        .onChange(of: store.runningEntry?.id) { syncFromRunning() }
        .onChange(of: taskId) { _, newValue in
            if let t = store.task(newValue), desc.isEmpty { desc = t.title }
            updateRunning()
        }
        .onChange(of: projectId) { updateRunning() }
    }

    private func syncFromRunning() {
        if let r = store.runningEntry {
            desc = r.description
            projectId = r.projectId
            taskId = r.taskId
        }
    }

    private func start() {
        store.startTimer(description: desc, projectId: projectId, taskId: taskId)
    }

    private func submit() {
        if store.runningEntry == nil { start() } else { updateRunning() }
    }

    private func updateRunning() {
        guard var r = store.runningEntry else { return }
        guard r.description != desc || r.projectId != projectId || r.taskId != taskId else { return }
        r.description = desc
        r.projectId = projectId
        r.taskId = taskId
        store.upsertEntry(r)
    }
}

struct EntryRow: View {
    @EnvironmentObject var store: Store
    let entry: TimeEntry
    let onEdit: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(entry.description.isEmpty ? "(sans description)" : entry.description)
                    .font(.body.weight(.medium))
                    .foregroundStyle(entry.description.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    ProjectLabel(projectId: entry.projectId, taskId: entry.taskId, font: .callout)
                    ForEach(entry.tags, id: \.self) { Pill(text: $0, color: .secondary) }
                    if let jira = store.task(entry.taskId)?.jiraKey { Pill(text: jira, color: .blue) }
                    if entry.invoiceId != nil { Pill(text: "Facturé", color: .green, systemImage: "checkmark") }
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(Fmt.hms(entry.duration)).font(.system(.body, design: .rounded).weight(.semibold)).monospacedDigit()
                Text("\(Fmt.time(entry.start)) – \(entry.end.map(Fmt.time) ?? "…")")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Button {
                store.startTimer(description: entry.description, projectId: entry.projectId, taskId: entry.taskId)
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 11))
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.accentColor.opacity(hover ? 0.18 : 0.08)))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .opacity(hover ? 1 : 0.5)
            .help("Relancer cette entrée")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(hover ? Color.primary.opacity(0.035) : .clear)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: onEdit)
        .contextMenu {
            Button("Modifier…", action: onEdit)
            Button("Relancer") {
                store.startTimer(description: entry.description, projectId: entry.projectId, taskId: entry.taskId)
            }
            Button("Dupliquer") {
                var copy = entry
                copy.id = UUID().uuidString
                copy.clockifyId = nil
                store.upsertEntry(copy)
            }
            Divider()
            Button("Supprimer", role: .destructive) { store.deleteEntry(entry.id) }
        }
    }
}

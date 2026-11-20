import SwiftUI

struct EntryEditor: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss

    @State private var entry: TimeEntry
    let isNew: Bool
    @State private var day: Date
    @State private var startTime: Date
    @State private var endTime: Date
    @State private var tagsText: String

    init(entry: TimeEntry, isNew: Bool = false) {
        _entry = State(initialValue: entry)
        self.isNew = isNew
        _day = State(initialValue: entry.start)
        _startTime = State(initialValue: entry.start)
        _endTime = State(initialValue: entry.end ?? Date())
        _tagsText = State(initialValue: entry.tags.joined(separator: ", "))
    }

    private var isRunning: Bool { entry.end == nil && !isNew }

    private func combine(_ day: Date, _ time: Date) -> Date {
        let cal = Calendar.app
        let t = cal.dateComponents([.hour, .minute, .second], from: time)
        return cal.date(bySettingHour: t.hour ?? 0, minute: t.minute ?? 0, second: t.second ?? 0, of: day) ?? day
    }

    private var computedStart: Date { combine(day, startTime) }
    private var computedEnd: Date {
        let end = combine(day, endTime)
        return end <= computedStart ? Calendar.app.date(byAdding: .day, value: 1, to: end)! : end
    }

    private var taskChoices: [TaskItem] {
        store.tasks
            .filter { $0.projectId == entry.projectId && ($0.status != .done || $0.id == entry.taskId) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(isNew ? "Nouvelle entrée" : "Entrée de temps").font(.title2.weight(.semibold))
                Spacer()
                if isRunning { Pill(text: "En cours", color: .red, systemImage: "record.circle") }
            }
            .padding([.horizontal, .top], 22)

            Form {
                Section {
                    DatePicker("Date", selection: $day, displayedComponents: .date)
                    HStack {
                        DatePicker("Horaires", selection: $startTime, displayedComponents: .hourAndMinute)
                        if !isRunning {
                            Text("–").foregroundStyle(.secondary)
                            DatePicker("", selection: $endTime, displayedComponents: .hourAndMinute).labelsHidden()
                        }
                        Spacer()
                        Text(Fmt.hms(isRunning ? Date().timeIntervalSince(computedStart) : computedEnd.timeIntervalSince(computedStart)))
                            .font(.system(.title3, design: .rounded).weight(.semibold))
                            .monospacedDigit()
                    }
                }
                Section {
                    TextField("Description", text: $entry.description, prompt: Text("Sur quoi as-tu travaillé ?"), axis: .vertical)
                        .lineLimit(2...5)
                    Picker("Projet", selection: $entry.projectId) {
                        Text("Aucun").tag(String?.none)
                        ForEach(store.projects.filter { !$0.archived || $0.id == entry.projectId }) { p in
                            Text(p.name).tag(Optional(p.id))
                        }
                    }
                    Picker("Tâche", selection: $entry.taskId) {
                        Text("Aucune").tag(String?.none)
                        ForEach(taskChoices) { t in
                            Text(t.jiraKey.map { "\($0) · \(t.title)" } ?? t.title).tag(Optional(t.id))
                        }
                    }
                    TextField("Tags", text: $tagsText, prompt: Text("séparés par des virgules"))
                    Toggle("Facturable", isOn: $entry.billable)
                }
            }
            .formStyle(.grouped)
            .onChange(of: entry.projectId) { _, newValue in
                if let t = store.task(entry.taskId), t.projectId != newValue { entry.taskId = nil }
            }
            .onChange(of: entry.taskId) { _, newValue in
                if let t = store.task(newValue), entry.description.isEmpty { entry.description = t.title }
            }

            HStack {
                if !isNew {
                    Button("Supprimer", role: .destructive) {
                        store.deleteEntry(entry.id)
                        dismiss()
                    }
                    .foregroundStyle(.red)
                }
                Spacer()
                Button("Annuler") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Enregistrer", action: save)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(22)
        }
        .frame(width: 520)
    }

    private func save() {
        var e = entry
        e.start = computedStart
        e.end = isRunning ? nil : computedEnd
        e.tags = tagsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        store.upsertEntry(e)
        dismiss()
    }
}

import SwiftUI

struct TodayView: View {
    @EnvironmentObject var store: Store
    @State private var plan: DayPlan? = DayPlan.load()
    @State private var generating = false
    @State private var error: String?
    @State private var editing: TaskEditTarget?

    private var greeting: String {
        let h = Calendar.app.component(.hour, from: Date())
        return h < 12 ? "Bonjour" : h < 18 ? "Bon après-midi" : "Bonsoir"
    }

    var body: some View {
        let suggestions = store.suggestions()
        let todayStart = Calendar.app.startOfDay(for: Date())
        let todayEntries = store.entries.filter { $0.start >= todayStart && store.entryInFacets($0) }
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(greeting).font(.system(size: 30, weight: .bold, design: .rounded))
                    Text(Fmt.longDay(Date())).font(.title3).foregroundStyle(.secondary)
                }
                FacetBar(selected: $store.activeFacets).padding(.horizontal, -20)

                HStack(spacing: 14) {
                    StatTile(title: "Temps aujourd'hui", value: Fmt.hms(todayEntries.reduce(0) { $0 + $1.duration }), icon: "clock.fill", tint: .blue)
                    StatTile(title: "En cours", value: "\(store.tasks.filter { $0.status == .in_progress && store.taskInFacets($0) }.count)", icon: "circle.lefthalf.filled", tint: .orange)
                    StatTile(title: "En retard", value: "\(overdueCount)", icon: "exclamationmark.triangle.fill", tint: .red)
                    if Agenda.isAvailable {
                        StatTile(title: "Temps libre restant", value: Fmt.short(store.freeSlots(events: store.todayEvents).reduce(0) { $0 + $1.1.timeIntervalSince($1.0) }),
                                 icon: "calendar.badge.clock", tint: .green)
                    }
                }

                if Agenda.isAvailable { AgendaCard() }

                planCard

                VStack(alignment: .leading, spacing: 10) {
                    Label("Suggestions", systemImage: "lightbulb.fill").font(.headline).foregroundStyle(.primary)
                    if suggestions.isEmpty {
                        Card { EmptyState(icon: "checkmark.seal", title: "Rien d'urgent", message: "Charge des tâches depuis le backlog.") }
                    } else {
                        Card(padding: 0) {
                            VStack(spacing: 0) {
                                ForEach(Array(suggestions.enumerated()), id: \.element.id) { idx, s in
                                    if idx > 0 { Divider().padding(.leading, 52) }
                                    SuggestionRow(rank: idx + 1, suggestion: s, onEdit: { editing = TaskEditTarget(task: s.task, isNew: false) })
                                }
                            }
                        }
                    }
                }

                if !todayEntries.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Déjà fait aujourd'hui", systemImage: "checkmark.circle.fill").font(.headline)
                        Card(padding: 0) {
                            VStack(spacing: 0) {
                                ForEach(Array(todayEntries.enumerated()), id: \.element.id) { idx, e in
                                    if idx > 0 { Divider().padding(.leading, 16) }
                                    EntryRow(entry: e) {}
                                }
                            }
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 920)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Aujourd'hui")
        .sheet(item: $editing) { t in TaskEditor(task: t.task, isNew: t.isNew).environmentObject(store) }
    }

    private var overdueCount: Int {
        let today = Calendar.app.startOfDay(for: Date())
        return store.tasks.filter { $0.status != .done && store.taskInFacets($0) && ($0.dueDate.map { $0 < today } ?? false) }.count
    }

    // MARK: AI plan

    @ViewBuilder
    private var planCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(LinearGradient(colors: [Color(hex: "#9B5CFF"), Color(hex: "#4F7CFF")], startPoint: .topLeading, endPoint: .bottomTrailing)))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Plan du jour").font(.headline)
                    Text(plan.map { "Généré par \($0.model)" + ($0.facets.isEmpty ? "" : " · \($0.facets.joined(separator: ", "))") }
                         ?? "Ollama · \(Ollama.model) · en local")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let plan {
                    Button {
                        store.upsertNote(Note(title: "Plan du \(Fmt.date(Date()))", body: plan.markdown(store: store),
                                              labels: plan.facets))
                        store.showToast("✓ Plan enregistré dans les notes")
                    } label: { Label("En note", systemImage: "note.text.badge.plus") }
                    .buttonStyle(.bordered)
                }
                Button(action: generate) {
                    HStack(spacing: 6) {
                        if generating { ProgressView().controlSize(.small) }
                        Text(generating ? "Réflexion…" : plan == nil ? "Générer mon plan" : "Régénérer")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(generating)
            }

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange)
            }

            if let plan {
                if !plan.summary.isEmpty { Text(plan.summary).font(.body) }
                VStack(spacing: 8) {
                    ForEach(Array(plan.items.enumerated()), id: \.element.id) { idx, item in
                        if let t = store.task(item.taskId) {
                            PlanItemRow(index: idx + 1, task: t, item: item)
                        }
                    }
                }
                if let f = plan.followups, !f.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("À traiter dans tes mails", systemImage: "envelope.badge").font(.callout.weight(.semibold))
                        ForEach(f, id: \.self) { item in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: "arrowshape.turn.up.left").font(.caption).foregroundStyle(.blue)
                                Text(item).font(.callout)
                            }
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.blue.opacity(0.07)))
                }
                HStack {
                    Image(systemName: "hourglass").foregroundStyle(.secondary)
                    Text("Total prévu : \(Fmt.short(Double(plan.items.reduce(0) { $0 + $1.minutes } * 60)))")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if !plan.advice.isEmpty {
                    Text(plan.advice)
                        .font(.callout.italic())
                        .foregroundStyle(.secondary)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.purple.opacity(0.08)))
                }
            } else if !generating {
                Text("Demande à ton modèle local d'organiser ta journée à partir de tes tâches, échéances, MR et du temps déjà passé.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(LinearGradient(colors: [Color.purple.opacity(0.10), Color.blue.opacity(0.06)], startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.purple.opacity(0.2)))
    }

    private func generate() {
        generating = true
        error = nil
        Task {
            do { plan = try await store.generateDayPlan() }
            catch { self.error = (error as? APIError)?.message ?? error.localizedDescription }
            generating = false
        }
    }
}

struct PlanItemRow: View {
    @EnvironmentObject var store: Store
    @Environment(\.openWindow) private var openWindow
    let index: Int
    let task: TaskItem
    let item: DayPlan.Item
    @State private var hover = false

    private var tracking: Bool { store.runningEntry?.taskId == task.id }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(index)")
                .font(.system(.callout, design: .rounded).weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.purple.gradient))
            VStack(alignment: .leading, spacing: 6) {
                Button { openWindow(id: "task", value: task.id) } label: {
                    HStack(spacing: 6) {
                        if let k = task.jiraKey { Pill(text: k, color: .blue) }
                        Text(task.title).font(.body.weight(.medium)).lineLimit(1)
                        Image(systemName: "arrow.up.forward.square").font(.caption).foregroundStyle(hover ? Color.accentColor : .secondary)
                    }
                }
                .buttonStyle(.plain)
                .help("Ouvrir le ticket")
                Text(item.why).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let steps = item.steps, !steps.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                            HStack(alignment: .firstTextBaseline, spacing: 7) {
                                Image(systemName: "circle").font(.system(size: 8, weight: .semibold)).foregroundStyle(.purple)
                                Text(step).font(.callout).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(.top, 2)
                }
                if task.jiraKey != nil || store.mergeRequests[task.id]?.first != nil {
                    HStack(spacing: 10) {
                        if let k = task.jiraKey, let url = Jira.browseURL(k) {
                            Link(destination: url) { Label("Voir dans Jira", systemImage: "safari") }
                                .font(.caption)
                        }
                        if let mrs = store.mergeRequests[task.id], let first = mrs.first { MRBadge(mr: first, extra: mrs.count - 1) }
                    }
                    .padding(.top, 2)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if let start = item.start { Text(start).font(.callout.weight(.semibold).monospacedDigit()) }
                Text(Fmt.short(Double(item.minutes * 60))).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            PlayButton(task: task)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(tracking ? Color.red.opacity(0.5) : hover ? Color.purple.opacity(0.35) : Color.primary.opacity(0.06)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(count: 2) { openWindow(id: "task", value: task.id) }
        .contextMenu { TaskContextMenu(task: task, onEdit: { openWindow(id: "task", value: task.id) }) }
    }
}

struct SuggestionRow: View {
    @EnvironmentObject var store: Store
    @Environment(\.openWindow) private var openWindow
    let rank: Int
    let suggestion: Suggestion
    let onEdit: () -> Void
    @State private var hover = false

    var body: some View {
        let t = suggestion.task
        HStack(spacing: 12) {
            Text("\(rank)").font(.system(.callout, design: .rounded).weight(.semibold)).foregroundStyle(.tertiary).frame(width: 24)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    if let k = t.jiraKey { Pill(text: k, color: .blue) }
                    Text(t.title).font(.body.weight(.medium)).lineLimit(1)
                }
                HStack(spacing: 5) {
                    ProjectLabel(projectId: t.projectId, font: .caption)
                    ForEach(Array(suggestion.reasons.enumerated()), id: \.offset) { _, r in Pill(text: r.text, color: r.color) }
                }
            }
            Spacer()
            if let mrs = store.mergeRequests[t.id], let first = mrs.first { MRBadge(mr: first, extra: mrs.count - 1) }
            PlayButton(task: t)
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .background(hover ? Color.primary.opacity(0.035) : .clear)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(count: 2) { openWindow(id: "task", value: t.id) }
        .contextMenu { TaskContextMenu(task: t, onEdit: onEdit) }
    }
}

struct PlayButton: View {
    @EnvironmentObject var store: Store
    let task: TaskItem
    var body: some View {
        let tracking = store.runningEntry?.taskId == task.id
        Button {
            if tracking { store.stopTimer() } else { store.startTimer(description: task.title, projectId: task.projectId, taskId: task.id) }
        } label: {
            Image(systemName: tracking ? "stop.fill" : "play.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Circle().fill(tracking ? Color.red : Color.accentColor))
        }
        .buttonStyle(.plain)
        .help(tracking ? "Arrêter" : "Lancer le chrono")
    }
}

struct AgendaCard: View {
    @EnvironmentObject var store: Store

    var body: some View {
        let events = store.todayEvents
        let slots = store.freeSlots(events: events)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Agenda", systemImage: "calendar").font(.headline)
                Spacer()
                if let err = store.calendarError {
                    Label(err, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange).lineLimit(1)
                }
                Button { Task { await store.refreshCalendar() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Rafraîchir")
            }
            if events.isEmpty {
                Text("Aucun événement aujourd'hui.").font(.callout).foregroundStyle(.secondary)
            } else {
                Card(padding: 0) {
                    VStack(spacing: 0) {
                        ForEach(Array(events.enumerated()), id: \.element.id) { idx, e in
                            if idx > 0 { Divider().padding(.leading, 86) }
                            EventRow(event: e)
                        }
                    }
                }
            }
            if !slots.isEmpty {
                FlowLayout(spacing: 6) {
                    Text("Libre :").font(.caption).foregroundStyle(.secondary)
                    ForEach(Array(slots.enumerated()), id: \.offset) { _, s in
                        Pill(text: "\(Fmt.time(s.0))–\(Fmt.time(s.1))", color: .green)
                    }
                }
            }
        }
    }
}

struct EventRow: View {
    @EnvironmentObject var store: Store
    let event: CalendarEvent
    @State private var preparing = false

    private func openNote(_ id: String) {
        UserDefaults.standard.set(id, forKey: "notes.selected")
        UserDefaults.standard.set(SidebarItem.notes.rawValue, forKey: "sidebar")
    }

    var body: some View {
        let past = event.end < Date()
        let logged = store.isLogged(event)
        HStack(spacing: 12) {
            VStack(alignment: .trailing, spacing: 1) {
                if event.allDay {
                    Text("Journée").font(.caption.weight(.semibold))
                } else {
                    Text(Fmt.time(event.start)).font(.callout.weight(.semibold).monospacedDigit())
                    Text(Fmt.time(event.end)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .frame(width: 54, alignment: .trailing)
            RoundedRectangle(cornerRadius: 2).fill(Color(hex: event.color)).frame(width: 4, height: 34)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(event.title).font(.body.weight(.medium)).lineLimit(1)
                    if event.isNow { Pill(text: "Maintenant", color: .red) }
                }
                HStack(spacing: 8) {
                    if !event.allDay { Text(Fmt.short(event.duration)).font(.caption).foregroundStyle(.secondary) }
                    if let loc = event.location, !loc.isEmpty {
                        Label(loc, systemImage: "mappin").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            Spacer()
            if !past && !event.allDay {
                if let prep = store.prepNote(for: event) {
                    Button { openNote(prep.id) } label: { Label("Prépa", systemImage: "doc.text.magnifyingglass") }
                        .controlSize(.small)
                        .help("Ouvrir la note de préparation")
                } else {
                    Button {
                        preparing = true
                        Task {
                            do { let n = try await store.prepareMeeting(event); openNote(n.id) }
                            catch { store.showToast((error as? APIError)?.message ?? error.localizedDescription) }
                            preparing = false
                        }
                    } label: {
                        HStack(spacing: 4) {
                            if preparing { ProgressView().controlSize(.mini) } else { Image(systemName: "sparkles") }
                            Text(preparing ? "Préparation…" : "Préparer")
                        }
                    }
                    .controlSize(.small)
                    .disabled(preparing)
                    .help("Ollama prépare une note : contexte, ce que tu peux dire, questions à poser")
                }
            }
            if let meet = event.meetURL, let url = URL(string: meet), !past {
                Button { NSWorkspace.shared.open(url) } label: { Label("Rejoindre", systemImage: "video.fill") }
                    .buttonStyle(.borderedProminent).controlSize(.small)
            }
            if !event.allDay && event.start < Date() {
                if logged {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("Temps déjà enregistré")
                } else {
                    Menu {
                        Button("Sans projet") { store.logEvent(event, projectId: nil) }
                        Divider()
                        ForEach(store.activeProjects) { p in Button(p.name) { store.logEvent(event, projectId: p.id) } }
                    } label: { Label("Temps", systemImage: "clock.badge.checkmark") }
                    .menuStyle(.borderlessButton).fixedSize()
                    .help("Enregistrer cet événement comme entrée de temps")
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .opacity(past ? 0.55 : 1)
        .background(event.isNow ? Color.red.opacity(0.06) : .clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if let l = event.htmlLink, let u = URL(string: l) { NSWorkspace.shared.open(u) } }
    }
}

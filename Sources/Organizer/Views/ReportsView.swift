import SwiftUI
import Charts
import UniformTypeIdentifiers

enum ReportPreset: String, CaseIterable, Identifiable {
    case today, yesterday, thisWeek, lastWeek, thisMonth, lastMonth, thisYear, custom
    var id: Self { self }

    var label: String {
        switch self {
        case .today: "Aujourd'hui"
        case .yesterday: "Hier"
        case .thisWeek: "Cette semaine"
        case .lastWeek: "Semaine dernière"
        case .thisMonth: "Ce mois-ci"
        case .lastMonth: "Mois dernier"
        case .thisYear: "Cette année"
        case .custom: "Personnalisé"
        }
    }

    /// Inclusive first and last day.
    func range(now: Date = Date()) -> (Date, Date) {
        let cal = Calendar.app
        let today = cal.startOfDay(for: now)
        func interval(_ c: Calendar.Component, _ offset: Int) -> (Date, Date) {
            let base = cal.date(byAdding: c, value: offset, to: today)!
            let i = cal.dateInterval(of: c, for: base)!
            return (i.start, cal.date(byAdding: .day, value: -1, to: i.end)!)
        }
        switch self {
        case .today, .custom: return (today, today)
        case .yesterday: let y = cal.date(byAdding: .day, value: -1, to: today)!; return (y, y)
        case .thisWeek: return interval(.weekOfYear, 0)
        case .lastWeek: return interval(.weekOfYear, -1)
        case .thisMonth: return interval(.month, 0)
        case .lastMonth: return interval(.month, -1)
        case .thisYear: return interval(.year, 0)
        }
    }
}

struct ReportsView: View {
    @EnvironmentObject var store: Store
    @State private var preset: ReportPreset = .thisWeek
    @State private var from: Date = ReportPreset.thisWeek.range().0
    @State private var to: Date = ReportPreset.thisWeek.range().1
    @State private var context: WorkContext?
    @State private var projectFilter: String?
    @State private var expanded: Set<String> = []
    private var facets: Set<String> { store.activeFacets }

    private var rangeStart: Date { Calendar.app.startOfDay(for: from) }
    private var rangeEnd: Date { Calendar.app.date(byAdding: .day, value: 1, to: Calendar.app.startOfDay(for: to))! }

    private var filtered: [TimeEntry] {
        store.entries.filter { e in
            e.start >= rangeStart && e.start < rangeEnd
                && (projectFilter == nil || e.projectId == projectFilter)
                && (context == nil || store.context(of: e) == context)
                && store.entryInFacets(e)
        }
        .sorted { $0.start < $1.start }
    }

    var body: some View {
        let entries = filtered
        let total = entries.reduce(0) { $0 + $1.duration }
        let groups = projectGroups(entries)
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                periodBar
                FilterHeader(context: $context, projectId: $projectFilter, facets: $store.activeFacets)
                    .padding(.horizontal, -20).padding(.top, -14)

                HStack(spacing: 14) {
                    StatTile(title: "Total", value: Fmt.hms(total), icon: "clock.fill", tint: .blue)
                    StatTile(title: "Entrées", value: "\(entries.count)", icon: "list.bullet", tint: .purple)
                    StatTile(title: "Moyenne / jour travaillé", value: Fmt.short(average(entries)), icon: "chart.line.uptrend.xyaxis", tint: .teal)
                    StatTile(title: "Facturable", value: Fmt.short(entries.filter(\.billable).reduce(0) { $0 + $1.duration }), icon: "eurosign.circle.fill", tint: .green)
                }

                if entries.isEmpty {
                    Card { EmptyState(icon: "chart.bar", title: "Aucun temps sur cette période") }
                } else {
                    Card { chart(entries, groups: groups) }
                    breakdown(groups, total: total)
                    details(entries)
                }
            }
            .padding(24)
        }
        .navigationTitle("Rapports")
        .toolbar {
            ToolbarItemGroup {
                Button { exportCSV(entries) } label: { Label("Exporter CSV", systemImage: "square.and.arrow.up") }
                    .disabled(entries.isEmpty)
            }
        }
        .onChange(of: preset) { _, p in
            guard p != .custom else { return }
            (from, to) = p.range()
        }
    }

    // MARK: Period

    private var periodBar: some View {
        HStack(spacing: 12) {
            Button { shift(-1) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.bordered)
                .help("Période précédente")
            Button { shift(1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.bordered)
                .help("Période suivante")
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title2.weight(.semibold))
                Text(preset.label).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Période", selection: $preset) {
                ForEach(ReportPreset.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            DatePicker("Du", selection: Binding(get: { from }, set: { from = $0; preset = .custom; if to < from { to = from } }),
                       displayedComponents: .date)
                .fixedSize()
            DatePicker("au", selection: Binding(get: { to }, set: { to = $0; preset = .custom; if from > to { from = to } }),
                       displayedComponents: .date)
                .fixedSize()
        }
    }

    private var title: String {
        let cal = Calendar.app
        if cal.isDate(from, inSameDayAs: to) { return Fmt.longDay(from) }
        return "\(Fmt.date(from)) → \(Fmt.date(to))"
    }

    private func shift(_ direction: Int) {
        let cal = Calendar.app
        switch preset {
        case .thisMonth, .lastMonth:
            from = cal.date(byAdding: .month, value: direction, to: from)!
            to = cal.date(byAdding: .day, value: -1, to: cal.dateInterval(of: .month, for: from)!.end)!
        case .thisYear:
            from = cal.date(byAdding: .year, value: direction, to: from)!
            to = cal.date(byAdding: .year, value: direction, to: to)!
        default:
            let days = (cal.dateComponents([.day], from: rangeStart, to: rangeEnd).day ?? 1) * direction
            from = cal.date(byAdding: .day, value: days, to: from)!
            to = cal.date(byAdding: .day, value: days, to: to)!
        }
        // keep the dates but drop the named preset so onChange does not reset them
        if preset != .custom { preset = .custom }
    }

    private func average(_ entries: [TimeEntry]) -> TimeInterval {
        let days = Set(entries.map { Calendar.app.startOfDay(for: $0.start) }).count
        return days == 0 ? 0 : entries.reduce(0) { $0 + $1.duration } / Double(days)
    }

    // MARK: Grouping

    struct ItemGroup: Identifiable {
        let id: String
        let label: String
        let isTask: Bool
        let jiraKey: String?
        var seconds: TimeInterval
        var count: Int
    }

    struct ProjectGroup: Identifiable {
        let id: String
        let name: String
        let color: Color
        var seconds: TimeInterval
        var items: [ItemGroup]
    }

    private func projectGroups(_ entries: [TimeEntry]) -> [ProjectGroup] {
        var map: [String: ProjectGroup] = [:]
        for e in entries {
            let pid = e.projectId ?? "none"
            let project = store.project(e.projectId)
            var g = map[pid] ?? ProjectGroup(id: pid, name: project?.name ?? "Sans projet",
                                             color: project.map { Color(hex: $0.color) } ?? .gray, seconds: 0, items: [])
            g.seconds += e.duration
            let task = store.task(e.taskId)
            let key = task?.id ?? "d:" + e.description.lowercased()
            if let i = g.items.firstIndex(where: { $0.id == key }) {
                g.items[i].seconds += e.duration
                g.items[i].count += 1
            } else {
                g.items.append(ItemGroup(id: key, label: task?.title ?? (e.description.isEmpty ? "(sans description)" : e.description),
                                         isTask: task != nil, jiraKey: task?.jiraKey, seconds: e.duration, count: 1))
            }
            map[pid] = g
        }
        return map.values
            .map { var g = $0; g.items.sort { $0.seconds > $1.seconds }; return g }
            .sorted { $0.seconds > $1.seconds }
    }

    // MARK: Chart

    private struct Bar: Identifiable {
        let id = UUID()
        let bucket: Date
        let project: String
        let hours: Double
    }

    @ViewBuilder
    private func chart(_ entries: [TimeEntry], groups: [ProjectGroup]) -> some View {
        let cal = Calendar.app
        let days = cal.dateComponents([.day], from: rangeStart, to: rangeEnd).day ?? 1
        let unit: Calendar.Component = days > 92 ? .month : .day
        let bars: [Bar] = {
            var acc: [String: (Date, String, TimeInterval)] = [:]
            for e in entries {
                let bucket = unit == .month ? cal.dateInterval(of: .month, for: e.start)!.start : cal.startOfDay(for: e.start)
                let name = store.project(e.projectId)?.name ?? "Sans projet"
                let k = "\(bucket.timeIntervalSince1970)|\(name)"
                acc[k, default: (bucket, name, 0)].2 += e.duration
            }
            return acc.values.map { Bar(bucket: $0.0, project: $0.1, hours: $0.2 / 3600) }
        }()
        VStack(alignment: .leading, spacing: 12) {
            Text(unit == .month ? "Heures par mois" : "Heures par jour").font(.headline)
            Chart(bars) { bar in
                BarMark(x: .value("Date", bar.bucket, unit: unit), y: .value("Heures", bar.hours))
                    .foregroundStyle(by: .value("Projet", bar.project))
                    .cornerRadius(4)
            }
            .chartForegroundStyleScale(domain: groups.map(\.name), range: groups.map(\.color))
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3]))
                    AxisValueLabel { if let h = value.as(Double.self) { Text("\(Int(h)) h") } }
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: unit, count: unit == .day && days > 14 ? max(1, days / 10) : 1)) { _ in
                    AxisGridLine().foregroundStyle(.clear)
                    AxisValueLabel(format: unit == .month ? .dateTime.month(.abbreviated) : .dateTime.day().month(.abbreviated))
                }
            }
            .chartLegend(position: .bottom, alignment: .leading)
            .frame(height: 240)
        }
    }

    // MARK: Breakdown

    @ViewBuilder
    private func breakdown(_ groups: [ProjectGroup], total: TimeInterval) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Répartition par projet et tâche").font(.headline).padding(.leading, 4)
            Card(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(groups.enumerated()), id: \.element.id) { idx, g in
                        if idx > 0 { Divider() }
                        VStack(spacing: 0) {
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    if expanded.contains(g.id) { expanded.remove(g.id) } else { expanded.insert(g.id) }
                                }
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(.tertiary)
                                        .rotationEffect(.degrees(expanded.contains(g.id) ? 90 : 0))
                                    Circle().fill(g.color).frame(width: 10, height: 10)
                                    Text(g.name).font(.body.weight(.semibold))
                                    Spacer()
                                    ShareBar(fraction: total > 0 ? g.seconds / total : 0, color: g.color)
                                        .frame(width: 140)
                                    Text(percent(g.seconds, total)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                                        .frame(width: 48, alignment: .trailing)
                                    Text(Fmt.hms(g.seconds)).font(.body.weight(.semibold).monospacedDigit())
                                        .frame(width: 80, alignment: .trailing)
                                }
                                .padding(.horizontal, 16).padding(.vertical, 12)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            if expanded.contains(g.id) {
                                ForEach(g.items) { item in
                                    HStack(spacing: 10) {
                                        Image(systemName: item.isTask ? "checkmark.square" : "text.alignleft")
                                            .font(.caption).foregroundStyle(.tertiary)
                                        if let key = item.jiraKey { Pill(text: key, color: .blue) }
                                        Text(item.label).lineLimit(1)
                                        Text("× \(item.count)").font(.caption).foregroundStyle(.tertiary)
                                        Spacer()
                                        Text(percent(item.seconds, g.seconds)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                        Text(Fmt.hms(item.seconds)).font(.callout.monospacedDigit())
                                            .frame(width: 80, alignment: .trailing)
                                    }
                                    .padding(.leading, 56).padding(.trailing, 16).padding(.vertical, 7)
                                    .background(Color.primary.opacity(0.025))
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func percent(_ part: TimeInterval, _ whole: TimeInterval) -> String {
        whole > 0 ? "\(Int((part / whole * 100).rounded())) %" : "–"
    }

    // MARK: Details

    @ViewBuilder
    private func details(_ entries: [TimeEntry]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Détail des entrées").font(.headline).padding(.leading, 4)
            Card(padding: 0) {
                LazyVStack(spacing: 0) {
                    HStack {
                        Text("Date").frame(width: 110, alignment: .leading)
                        Text("Description").frame(maxWidth: .infinity, alignment: .leading)
                        Text("Projet › Tâche").frame(width: 240, alignment: .leading)
                        Text("Horaires").frame(width: 100, alignment: .leading)
                        Text("Durée").frame(width: 70, alignment: .trailing)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    Divider()
                    ForEach(entries.reversed()) { e in
                        HStack {
                            Text(Fmt.dayHeader(e.start)).frame(width: 110, alignment: .leading).foregroundStyle(.secondary)
                            Text(e.description.isEmpty ? "(sans description)" : e.description)
                                .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                            ProjectLabel(projectId: e.projectId, taskId: e.taskId, font: .callout, placeholder: "—")
                                .frame(width: 240, alignment: .leading)
                            Text("\(Fmt.time(e.start)) – \(e.end.map(Fmt.time) ?? "…")")
                                .monospacedDigit().foregroundStyle(.secondary).frame(width: 100, alignment: .leading)
                            Text(Fmt.hms(e.duration)).monospacedDigit().frame(width: 70, alignment: .trailing)
                        }
                        .font(.callout)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        Divider().padding(.leading, 16)
                    }
                }
            }
        }
    }

    // MARK: Export

    private func exportCSV(_ entries: [TimeEntry]) {
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var lines = ["Date;Début;Fin;Durée;Heures décimales;Description;Projet;Client;Tâche;Jira;Tags;Contexte;Facturable"]
        for e in entries {
            let p = store.project(e.projectId)
            let t = store.task(e.taskId)
            lines.append([
                Fmt.date(e.start), Fmt.time(e.start), e.end.map(Fmt.time) ?? "", Fmt.hms(e.duration), Fmt.hours(e.duration),
                q(e.description), q(p?.name ?? ""), q(p?.client ?? ""), q(t?.title ?? ""), t?.jiraKey ?? "",
                q(e.tags.joined(separator: ", ")), store.context(of: e).label, e.billable ? "oui" : "non",
            ].joined(separator: ";"))
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "temps_\(Fmt.isoDay(from))_\(Fmt.isoDay(to)).csv"
        if panel.runModal() == .OK, let url = panel.url {
            try? ("\u{FEFF}" + lines.joined(separator: "\n")).write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

struct ShareBar: View {
    let fraction: Double
    let color: Color
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.07))
                Capsule().fill(color.gradient).frame(width: max(4, geo.size.width * fraction))
            }
        }
        .frame(height: 6)
    }
}

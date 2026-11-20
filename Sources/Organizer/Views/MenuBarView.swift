import SwiftUI

struct MenuBarPanel: View {
    @EnvironmentObject var store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TimerBar(compact: true)

            let inProgress = store.tasks(status: .in_progress)
            if !inProgress.isEmpty {
                section("En cours")
                ForEach(inProgress.prefix(5)) { t in quickRow(title: t.title, projectId: t.projectId, taskId: t.id) }
            }

            let recent = recentEntries
            if !recent.isEmpty {
                section("Récents")
                ForEach(recent) { e in
                    quickRow(title: e.description.isEmpty ? "(sans description)" : e.description,
                             projectId: e.projectId, taskId: e.taskId, detail: Fmt.short(e.duration))
                }
            }

            Divider()
            HStack {
                Button("Ouvrir Organizer") { WindowOpener.showMain() }
                Spacer()
                Button("Quitter") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
            .font(.callout)
            .padding(.horizontal, 8)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(width: 400)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var recentEntries: [TimeEntry] {
        var seen = Set<String>()
        return store.entries.filter { e in
            guard !e.isRunning else { return false }
            let key = "\(e.description)|\(e.projectId ?? "")|\(e.taskId ?? "")"
            return seen.insert(key).inserted
        }
        .prefix(5).map { $0 }
    }

    private func section(_ title: String) -> some View {
        Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            .padding(.leading, 8).padding(.top, 2)
    }

    private func quickRow(title: String, projectId: String?, taskId: String?, detail: String? = nil) -> some View {
        Button {
            store.startTimer(description: title, projectId: projectId, taskId: taskId)
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).lineLimit(1)
                    ProjectLabel(projectId: projectId, taskId: taskId, font: .caption)
                }
                Spacer()
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                Image(systemName: "play.circle.fill").foregroundStyle(Color.accentColor).font(.title3)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(QuickRowStyle())
    }
}

private struct QuickRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        QuickRow(configuration: configuration)
    }

    private struct QuickRow: View {
        let configuration: ButtonStyle.Configuration
        @State private var hover = false
        var body: some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(configuration.isPressed ? 0.12 : hover ? 0.06 : 0))
                )
                .onHover { hover = $0 }
        }
    }
}

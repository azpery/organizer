import Foundation
import SwiftUI

@MainActor
final class Store: ObservableObject {
    static let shared = Store()

    @Published private(set) var projects: [Project] = []
    @Published private(set) var tasks: [TaskItem] = []
    /// Sorted by start, most recent first.
    @Published private(set) var entries: [TimeEntry] = []
    @Published private(set) var notes: [Note] = []
    @Published private(set) var artifacts: [ArtifactItem] = []
    @Published var clients: [Client] = []
    @Published var mindmaps: [MindMap] = []
    @Published var invoices: [Invoice] = []

    /// Global facet lens: when not empty, every view only shows what belongs to these facets.
    @Published var activeFacets: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "activeFacets") ?? []) {
        didSet { UserDefaults.standard.set(Array(activeFacets), forKey: "activeFacets") }
    }
    @Published var apiStatus: String = "Arrêtée"
    @Published var lastError: String?
    /// Recent mails from Apple Mail (local copy, used as context for Ollama).
    @Published var mails: [MailSnippet] = []
    @Published var mailStatus: String?
    @Published var mailSyncing = false
    /// A meeting preparation is running.
    @Published var preparing = false
    @Published var jiraLastCheck: Date?
    /// Today's Google Calendar events.
    @Published var todayEvents: [CalendarEvent] = []
    @Published var calendarError: String?
    /// GitLab merge requests per task id (in memory, refreshed periodically).
    @Published var mergeRequests: [String: [MergeRequest]] = [:]
    @Published var mergeRequestsUpdatedAt: Date?
    /// Short message shown as a toast (sync results, errors).
    @Published var toast: String?

    let supportDir: URL
    let db: Database
    private var apiServer: APIServer?

    init() {
        let dir = Demo.dir ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Organizer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        supportDir = dir
        do {
            db = try Database(path: dir.appendingPathComponent("organizer.sqlite").path)
        } catch {
            fatalError("Base de données inaccessible : \(error)")
        }
        reload()
    }

    func reload() {
        do {
            projects = try db.loadProjects()
            tasks = try db.loadTasks()
            entries = try db.loadEntries()
            notes = try db.loadNotes()
            artifacts = try db.loadArtifacts()
            mails = try db.loadMails()
            clients = try db.loadJSON("clients", as: Client.self).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            mindmaps = try db.loadJSON("mindmaps", as: MindMap.self).sorted { $0.updatedAt > $1.updatedAt }
            invoices = try db.loadJSON("invoices", as: Invoice.self).sorted { ($0.issueDate, $0.number) > ($1.issueDate, $1.number) }
        } catch {
            report(error)
        }
    }

    private func report(_ error: Error) {
        lastError = "\(error)"
        NSLog("Organizer error: \(error)")
    }

    // MARK: - Lookups

    func project(_ id: String?) -> Project? {
        guard let id else { return nil }
        return projects.first { $0.id == id }
    }

    func task(_ id: String?) -> TaskItem? {
        guard let id else { return nil }
        return tasks.first { $0.id == id }
    }

    func projectNamed(_ name: String) -> Project? {
        projects.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    var activeProjects: [Project] { projects.filter { !$0.archived } }

    var runningEntry: TimeEntry? { entries.first { $0.end == nil } }

    func openTasks(projectId: String?) -> [TaskItem] {
        tasks.filter { $0.projectId == projectId && $0.status != .done }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    func context(of entry: TimeEntry) -> WorkContext {
        project(entry.projectId)?.context ?? task(entry.taskId)?.context ?? .pro
    }

    func trackedTime(task id: String) -> TimeInterval {
        entries.filter { $0.taskId == id }.reduce(0) { $0 + $1.duration }
    }

    var timeByTask: [String: TimeInterval] {
        var map: [String: TimeInterval] = [:]
        for e in entries { if let t = e.taskId { map[t, default: 0] += e.duration } }
        return map
    }

    /// Facets declared explicitly (shown even when no task uses them yet).
    @Published var facetNames: [String] = UserDefaults.standard.stringArray(forKey: "facets") ?? [] {
        didSet { UserDefaults.standard.set(facetNames, forKey: "facets") }
    }

    func addFacet(_ name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, !facetNames.contains(where: { $0.caseInsensitiveCompare(n) == .orderedSame }) else { return }
        facetNames.append(n)
    }

    func removeFacet(_ name: String) {
        facetNames.removeAll { $0 == name }
        activeFacets.remove(name)
        for var t in tasks where t.labels.contains(name) {
            t.labels.removeAll { $0 == name }
            upsertTask(t, syncToJira: false)
        }
        for var p in projects where p.labels.contains(name) { p.labels.removeAll { $0 == name }; upsertProject(p) }
        for var n in notes where n.labels.contains(name) { n.labels.removeAll { $0 == name }; upsertNote(n, touch: false) }
        for var a in artifacts where a.labels.contains(name) { a.labels.removeAll { $0 == name }; upsertArtifact(a) }
    }

    // MARK: - Facet lens

    func inFacets(_ labels: [String]) -> Bool {
        activeFacets.isEmpty || !activeFacets.isDisjoint(with: labels)
    }

    func taskInFacets(_ t: TaskItem) -> Bool {
        inFacets(t.labels) || (!activeFacets.isEmpty && t.labels.isEmpty && inFacets(project(t.projectId)?.labels ?? []))
    }

    func entryInFacets(_ e: TimeEntry) -> Bool {
        guard !activeFacets.isEmpty else { return true }
        if let t = task(e.taskId) { return taskInFacets(t) }
        return inFacets(project(e.projectId)?.labels ?? [])
    }

    func projectInFacets(_ p: Project) -> Bool {
        guard !activeFacets.isEmpty else { return true }
        return inFacets(p.labels) || tasks.contains { $0.projectId == p.id && !activeFacets.isDisjoint(with: $0.labels) }
    }

    // MARK: - Notes

    func note(_ id: String?) -> Note? {
        guard let id else { return nil }
        return notes.first { $0.id == id }
    }

    @discardableResult
    func upsertNote(_ note: Note, touch: Bool = true) -> Note {
        var n = note
        if touch { n.updatedAt = Date() }
        do { try db.save(n) } catch { report(error) }
        if let i = notes.firstIndex(where: { $0.id == n.id }) { notes[i] = n } else { notes.append(n) }
        notes.sort { ($0.pinned ? 1 : 0, $0.updatedAt) > ($1.pinned ? 1 : 0, $1.updatedAt) }
        return n
    }

    func deleteNote(_ id: String) {
        do { try db.delete(table: "notes", id: id) } catch { report(error) }
        notes.removeAll { $0.id == id }
    }

    // MARK: - Artifacts

    func artifact(_ id: String?) -> ArtifactItem? {
        guard let id else { return nil }
        return artifacts.first { $0.id == id }
    }

    @discardableResult
    func upsertArtifact(_ a: ArtifactItem) -> ArtifactItem {
        do { try db.save(a) } catch { report(error) }
        if let i = artifacts.firstIndex(where: { $0.id == a.id }) { artifacts[i] = a } else { artifacts.append(a) }
        artifacts.sort { $0.createdAt > $1.createdAt }
        return a
    }

    func deleteArtifact(_ id: String) {
        do { try db.delete(table: "artifacts", id: id) } catch { report(error) }
        artifacts.removeAll { $0.id == id }
    }

    /// All facets (declared + in use), declared order first, then most used.
    var allLabels: [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        for t in tasks { for l in t.labels { counts[l, default: 0] += 1 } }
        for p in projects { for l in p.labels { counts[l, default: 0] += 1 } }
        for n in notes { for l in n.labels { counts[l, default: 0] += 1 } }
        for a in artifacts { for l in a.labels { counts[l, default: 0] += 1 } }
        let declared = facetNames.map { ($0, counts[$0] ?? 0) }
        let others = counts.filter { !facetNames.contains($0.key) }
        return declared + others.map { ($0.key, $0.value) }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }
    }

    func matches(_ t: TaskItem, labels: Set<String>) -> Bool {
        labels.isEmpty || !labels.isDisjoint(with: t.labels)
    }

    /// Renames (or merges into an existing) facet everywhere.
    func renameLabel(_ old: String, to new: String) {
        let new = new.trimmingCharacters(in: .whitespaces)
        guard !new.isEmpty, old != new else { return }
        func swap(_ labels: [String]) -> [String] {
            var out: [String] = []
            for l in labels.map({ $0 == old ? new : $0 }) where !out.contains(l) { out.append(l) }
            return out
        }
        for var t in tasks where t.labels.contains(old) { t.labels = swap(t.labels); upsertTask(t, syncToJira: false) }
        for var p in projects where p.labels.contains(old) { p.labels = swap(p.labels); upsertProject(p) }
        for var n in notes where n.labels.contains(old) { n.labels = swap(n.labels); upsertNote(n, touch: false) }
        for var a in artifacts where a.labels.contains(old) { a.labels = swap(a.labels); upsertArtifact(a) }
        if let i = facetNames.firstIndex(of: old) {
            if facetNames.contains(new) { facetNames.remove(at: i) } else { facetNames[i] = new }
        }
        if activeFacets.remove(old) != nil { activeFacets.insert(new) }
    }

    func tasks(status: TaskStatus, context: WorkContext? = nil, projectId: String? = nil, labels: Set<String> = [], search: String = "") -> [TaskItem] {
        tasks.filter { t in
            t.status == status
                && (labels.isEmpty || matches(t, labels: labels) || (t.labels.isEmpty && !labels.isDisjoint(with: project(t.projectId)?.labels ?? [])))
                && (context == nil || t.context == context)
                && (projectId == nil || t.projectId == projectId)
                && (search.isEmpty || t.title.localizedCaseInsensitiveContains(search)
                    || t.labels.contains { $0.localizedCaseInsensitiveContains(search) }
                    || (t.jiraKey ?? "").localizedCaseInsensitiveContains(search))
        }
        .sorted { a, b in
            if a.priority != b.priority { return a.priority > b.priority }
            return a.position < b.position
        }
    }

    // MARK: - Projects

    @discardableResult
    func upsertProject(_ p: Project) -> Project {
        do { try db.save(p) } catch { report(error) }
        if let i = projects.firstIndex(where: { $0.id == p.id }) { projects[i] = p } else { projects.append(p) }
        projects.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return p
    }

    func deleteProject(_ id: String) {
        do {
            try db.transaction {
                try db.delete(table: "projects", id: id)
                try db.run("UPDATE tasks SET project_id = NULL WHERE project_id = ?", [id])
                try db.run("UPDATE time_entries SET project_id = NULL WHERE project_id = ?", [id])
            }
        } catch { report(error) }
        reload()
    }

    // MARK: - Tasks

    @discardableResult
    func upsertTask(_ task: TaskItem, syncToJira: Bool = true) -> TaskItem {
        var t = task
        let previous = self.task(t.id)
        defer { if syncToJira { pushToJira(old: previous, new: t) } }
        t.updatedAt = Date()
        if t.status == .done, t.completedAt == nil { t.completedAt = Date() }
        if t.status != .done { t.completedAt = nil }
        if let previous, previous.status != t.status { t.position = Date().timeIntervalSince1970 }
        do { try db.save(t) } catch { report(error) }
        if let i = tasks.firstIndex(where: { $0.id == t.id }) { tasks[i] = t } else { tasks.append(t) }
        return t
    }

    func showToast(_ message: String) {
        toast = message
        let current = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            if self?.toast == current { self?.toast = nil }
        }
    }

    /// Mirrors status / title / due date changes of a Jira-linked task to Jira.
    private func pushToJira(old: TaskItem?, new: TaskItem) {
        guard let key = new.jiraKey, Jira.isConfigured, Jira.syncEnabled,
              key.uppercased().hasPrefix(Jira.projectKey + "-") else { return }
        let statusChanged = old != nil && old?.status != new.status
        let titleChanged = old != nil && old?.title != new.title && !new.title.isEmpty
        let dueChanged = old != nil && old?.dueDate != new.dueDate
        guard statusChanged || titleChanged || dueChanged else { return }
        Task {
            do {
                if titleChanged || dueChanged {
                    try await Jira.updateFields(key: key, summary: titleChanged ? new.title : nil,
                                                dueDate: dueChanged ? .some(new.dueDate) : nil)
                }
                if statusChanged { try await Jira.transition(key: key, to: new.status) }
                showToast("Jira : \(key) mis à jour" + (statusChanged ? " → \(new.status.label)" : ""))
            } catch {
                showToast((error as? APIError)?.message ?? error.localizedDescription)
            }
        }
    }

    /// Creates the Jira issue for a local task and links it.
    func createJiraIssue(for taskId: String) async throws -> String {
        guard let t = task(taskId) else { throw APIError(404, "Tâche introuvable") }
        if let key = t.jiraKey { return key }
        let key = try await Jira.createIssue(summary: t.title, dueDate: t.dueDate)
        guard var fresh = task(taskId) else { return key }
        fresh.jiraKey = key
        fresh.url = Jira.browseURL(key)?.absoluteString
        upsertTask(fresh, syncToJira: false)
        if fresh.status != .backlog && fresh.status != .todo {
            try? await Jira.transition(key: key, to: fresh.status)
        }
        showToast("Ticket \(key) créé dans Jira")
        return key
    }

    @discardableResult
    func moveTask(_ id: String, to status: TaskStatus) -> TaskItem? {
        guard var t = task(id), t.status != status else { return task(id) }
        t.status = status
        return upsertTask(t)
    }

    func deleteTask(_ id: String) {
        do {
            try db.transaction {
                try db.delete(table: "tasks", id: id)
                try db.run("UPDATE time_entries SET task_id = NULL WHERE task_id = ?", [id])
                try db.run("UPDATE notes SET task_id = NULL WHERE task_id = ?", [id])
                try db.run("UPDATE artifacts SET task_id = NULL WHERE task_id = ?", [id])
            }
        } catch { report(error) }
        tasks.removeAll { $0.id == id }
        for i in notes.indices where notes[i].taskId == id { notes[i].taskId = nil }
        for i in artifacts.indices where artifacts[i].taskId == id { artifacts[i].taskId = nil }
        for i in entries.indices where entries[i].taskId == id { entries[i].taskId = nil }
    }

    // MARK: - Time entries

    @discardableResult
    func upsertEntry(_ e: TimeEntry) -> TimeEntry {
        do { try db.save(e) } catch { report(error) }
        if let i = entries.firstIndex(where: { $0.id == e.id }) { entries[i] = e } else { entries.append(e) }
        entries.sort { $0.start > $1.start }
        return e
    }

    func deleteEntry(_ id: String) {
        do { try db.delete(table: "time_entries", id: id) } catch { report(error) }
        entries.removeAll { $0.id == id }
    }

    @discardableResult
    func startTimer(description: String, projectId: String?, taskId: String?) -> TimeEntry {
        stopTimer()
        var projectId = projectId
        if let t = task(taskId) {
            if projectId == nil { projectId = t.projectId }
            if t.status == .backlog || t.status == .todo { moveTask(t.id, to: .in_progress) }
        }
        let entry = TimeEntry(description: description, projectId: projectId, taskId: taskId, start: Date())
        return upsertEntry(entry)
    }

    @discardableResult
    func stopTimer() -> TimeEntry? {
        guard var running = runningEntry else { return nil }
        running.end = Date()
        return upsertEntry(running)
    }

    func entries(from: Date, to: Date) -> [TimeEntry] {
        entries.filter { $0.start >= from && $0.start < to }
    }

    // MARK: - Bulk import (Clockify)

    func performBatch(_ body: () throws -> Void) {
        do { try db.transaction(body) } catch { report(error) }
        reload()
    }

    // MARK: - API

    func startAPI() {
        apiServer?.stop()
        let server = APIServer(router: APIRouter(store: self))
        let port = Config.apiPort
        server.onStateChange = { [weak self] status in
            Task { @MainActor in self?.apiStatus = status }
        }
        do {
            try server.start(port: port)
            apiServer = server
            writeAPIInfo()
        } catch {
            apiStatus = "Erreur : \(error.localizedDescription)"
        }
    }

    /// Lets local tools (and Claude) discover the API URL and token.
    func writeAPIInfo() {
        let info: [String: Any] = [
            "base_url": "http://127.0.0.1:\(Config.apiPort)/api",
            "token": Config.apiToken,
            "auth_header": "Authorization: Bearer <token>",
        ]
        if let data = try? JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
            let url = supportDir.appendingPathComponent("api.json")
            try? data.write(to: url)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }
}

enum Config {
    static var apiPort: UInt16 {
        if Demo.active { return Demo.port }
        let v = UserDefaults.standard.integer(forKey: "apiPort")
        return v > 0 && v < 65536 ? UInt16(v) : 47821
    }

    static var apiToken: String {
        if let t = UserDefaults.standard.string(forKey: "apiToken"), !t.isEmpty { return t }
        return regenerateToken()
    }

    @discardableResult
    static func regenerateToken() -> String {
        let t = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
        UserDefaults.standard.set(t, forKey: "apiToken")
        return t
    }
}

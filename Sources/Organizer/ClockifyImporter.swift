import Foundation

struct CKUser: Decodable { let id: String; let name: String?; let activeWorkspace: String?; let defaultWorkspace: String? }
struct CKWorkspace: Decodable, Identifiable, Hashable { let id: String; let name: String }
struct CKProject: Decodable { let id: String; let name: String; let color: String?; let clientName: String?; let archived: Bool? }
struct CKTask: Decodable { let id: String; let name: String; let projectId: String?; let status: String? }
struct CKTag: Decodable { let id: String; let name: String }
struct CKInterval: Decodable { let start: String?; let end: String? }
struct CKTimeEntry: Decodable {
    let id: String
    let description: String?
    let projectId: String?
    let taskId: String?
    let tagIds: [String]?
    let billable: Bool?
    let timeInterval: CKInterval
}

struct ClockifyClient {
    let apiKey: String
    private let base = "https://api.clockify.me/api/v1"

    func get<T: Decodable>(_ path: String, _ query: [String: String] = [:]) async throws -> T {
        var comps = URLComponents(string: base + path)!
        if !query.isEmpty { comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var req = URLRequest(url: comps.url!)
        req.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw APIError(status == 401 ? 401 : 502, "Clockify HTTP \(status) : \(msg.prefix(300))")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    func getAll<T: Decodable>(_ path: String, _ query: [String: String] = [:], pageSize: Int = 200) async throws -> [T] {
        var all: [T] = []
        var page = 1
        while true {
            var q = query
            q["page"] = "\(page)"
            q["page-size"] = "\(pageSize)"
            let batch: [T] = try await get(path, q)
            all += batch
            if batch.count < pageSize || page > 200 { break }
            page += 1
        }
        return all
    }

    func user() async throws -> CKUser { try await get("/user") }
    func workspaces() async throws -> [CKWorkspace] { try await get("/workspaces") }
}

struct ImportResult: CustomStringConvertible {
    var projects = 0
    var tasks = 0
    var entries = 0
    var updated = 0
    var description: String {
        "\(projects) projets, \(tasks) tâches, \(entries) entrées de temps importés (\(updated) mis à jour)"
    }
}

enum ClockifyImporter {
    static var apiKey: String { UserDefaults.standard.string(forKey: "clockifyApiKey") ?? "" }
    static var workspaceId: String { UserDefaults.standard.string(forKey: "clockifyWorkspaceId") ?? "" }

    @MainActor
    static func run(store: Store, from: Date, to: Date) async throws -> ImportResult {
        guard !apiKey.isEmpty else { throw APIError(400, "Clé API Clockify non configurée (Réglages)") }
        let client = ClockifyClient(apiKey: apiKey)
        let user = try await client.user()
        let ws = workspaceId.isEmpty ? (user.activeWorkspace ?? user.defaultWorkspace ?? "") : workspaceId
        guard !ws.isEmpty else { throw APIError(400, "Aucun workspace Clockify") }

        let ckProjects: [CKProject] = try await client.getAll("/workspaces/\(ws)/projects", ["archived": "false"])
            + client.getAll("/workspaces/\(ws)/projects", ["archived": "true"])
        let ckTags: [CKTag] = try await client.getAll("/workspaces/\(ws)/tags")
        var ckTasks: [CKTask] = []
        for p in ckProjects where p.archived != true {
            let t: [CKTask] = try await client.getAll("/workspaces/\(ws)/projects/\(p.id)/tasks")
            ckTasks += t.map { CKTask(id: $0.id, name: $0.name, projectId: $0.projectId ?? p.id, status: $0.status) }
        }
        let iso = ISO8601DateFormatter()
        iso.timeZone = TimeZone(identifier: "UTC")
        let ckEntries: [CKTimeEntry] = try await client.getAll(
            "/workspaces/\(ws)/user/\(user.id)/time-entries",
            ["start": iso.string(from: from), "end": iso.string(from: to)],
            pageSize: 500)

        var result = ImportResult()
        let tagNames = Dictionary(ckTags.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        var projectMap: [String: String] = [:]
        var taskMap: [String: String] = [:]
        var lastWork: [String: Date] = [:]

        store.performBatch {
            var projects = store.projects
            for cp in ckProjects {
                var p = projects.first { $0.clockifyId == cp.id }
                    ?? projects.first { $0.name.caseInsensitiveCompare(cp.name) == .orderedSame && $0.clockifyId == nil }
                    ?? { result.projects += 1; return Project(name: cp.name) }()
                p.name = cp.name
                if let c = cp.color, c.hasPrefix("#") { p.color = c }
                p.client = cp.clientName?.isEmpty == false ? cp.clientName : p.client
                p.archived = cp.archived ?? false
                p.clockifyId = cp.id
                try store.db.save(p)
                projects.removeAll { $0.id == p.id }
                projects.append(p)
                projectMap[cp.id] = p.id
            }

            var tasks = store.tasks
            for ct in ckTasks {
                let localProject = ct.projectId.flatMap { projectMap[$0] }
                var t = tasks.first { $0.clockifyId == ct.id }
                    ?? { result.tasks += 1; return TaskItem(title: ct.name) }()
                t.title = ct.name
                t.projectId = localProject
                if t.jiraKey == nil, let key = Jira.detectKey(in: ct.name) {
                    t.jiraKey = key
                    t.url = Jira.browseURL(key)?.absoluteString
                }
                if t.clockifyId == nil {
                    // Clockify tasks are time categories already worked on: done, unless linked to a Jira ticket
                    t.status = t.jiraKey == nil || ct.status == "DONE" ? .done : .backlog
                    t.context = projects.first { $0.id == localProject }?.context ?? .pro
                    if t.status == .done { t.completedAt = Date() }
                }
                t.clockifyId = ct.id
                t.updatedAt = Date()
                try store.db.save(t)
                tasks.removeAll { $0.id == t.id }
                tasks.append(t)
                taskMap[ct.id] = t.id
            }

            let existing = Dictionary(store.entries.compactMap { e in e.clockifyId.map { ($0, e) } }, uniquingKeysWith: { a, _ in a })
            for ce in ckEntries {
                guard let s = ce.timeInterval.start, let start = parseDate(s),
                      let e = ce.timeInterval.end, let end = parseDate(e) else { continue }
                var entry = existing[ce.id] ?? TimeEntry(start: start)
                if existing[ce.id] != nil { result.updated += 1 } else { result.entries += 1 }
                entry.description = ce.description ?? ""
                entry.projectId = ce.projectId.flatMap { projectMap[$0] }
                entry.taskId = ce.taskId.flatMap { taskMap[$0] }
                entry.start = start
                entry.end = end
                entry.tags = (ce.tagIds ?? []).compactMap { tagNames[$0] }
                entry.billable = ce.billable ?? false
                entry.clockifyId = ce.id
                try store.db.save(entry)
                if let tid = entry.taskId { lastWork[tid] = max(lastWork[tid] ?? end, end) }
            }
            // Done Clockify categories are dated by their last time entry.
            for t in tasks where t.status == .done && t.jiraKey == nil && t.clockifyId != nil {
                guard let last = lastWork[t.id], t.completedAt.map({ abs($0.timeIntervalSince(last)) > 1 }) ?? true else { continue }
                var c = t
                c.completedAt = last
                try store.db.save(c)
            }
        }
        return result
    }
}

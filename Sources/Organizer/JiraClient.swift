import Foundation
import AppKit

/// Minimal Jira Cloud client (REST v3, basic auth email + API token).
enum Jira {
    static var baseURL: String {
        (UserDefaults.standard.string(forKey: "jiraBaseURL") ?? "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
    }
    static var email: String { UserDefaults.standard.string(forKey: "jiraEmail") ?? "" }
    static var token: String { UserDefaults.standard.string(forKey: "jiraToken") ?? "" }
    static var projectKey: String {
        let k = UserDefaults.standard.string(forKey: "jiraProjectKey") ?? ""
        return k.trimmingCharacters(in: .whitespaces).uppercased()
    }
    /// Organizer project that receives imported tickets (by name); none when empty.
    static var defaultProjectName: String { UserDefaults.standard.string(forKey: "jiraDefaultProject") ?? "" }
    /// Example shown in the UI, e.g. "ABC-123".
    static func sampleKey(_ n: Int = 123) -> String { "\(projectKey.isEmpty ? "ABC" : projectKey)-\(n)" }

    static var isConfigured: Bool { !baseURL.isEmpty && !email.isEmpty && !token.isEmpty }

    static func browseURL(_ key: String) -> URL? {
        guard !baseURL.isEmpty else { return nil }
        return URL(string: "\(baseURL)/browse/\(key)")
    }

    /// Finds a Jira key such as "ABC-9", "ABC 9" or "ABC22" in free text and normalizes it to "ABC-9".
    static func detectKey(in text: String) -> String? {
        guard !projectKey.isEmpty else { return nil }
        let key = NSRegularExpression.escapedPattern(for: projectKey)
        guard let re = try? NSRegularExpression(pattern: "\\b\(key)[- _]?(\\d+)\\b", options: [.caseInsensitive]),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return "\(projectKey)-\(text[r])"
    }

    struct Issue {
        let key: String
        let summary: String
        let statusCategory: String
        let status: String
        var resolved: Date? = nil
    }

    static func search(jql: String) async throws -> [Issue] {
        guard isConfigured else { throw APIError(400, "Jira non configuré (Réglages)") }
        var issues: [Issue] = []
        var nextToken: String?
        repeat {
            var comps = URLComponents(string: "\(baseURL)/rest/api/3/search/jql")!
            var items = [
                URLQueryItem(name: "jql", value: jql),
                URLQueryItem(name: "fields", value: "summary,status,resolutiondate"),
                URLQueryItem(name: "maxResults", value: "100"),
            ]
            if let nextToken { items.append(URLQueryItem(name: "nextPageToken", value: nextToken)) }
            comps.queryItems = items
            var req = URLRequest(url: comps.url!)
            let auth = Data("\(email):\(token)".utf8).base64EncodedString()
            req.setValue("Basic \(auth)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                throw APIError(502, "Jira HTTP \(status) : \(String(data: data, encoding: .utf8)?.prefix(300) ?? "")")
            }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            for raw in json["issues"] as? [[String: Any]] ?? [] {
                let fields = raw["fields"] as? [String: Any] ?? [:]
                let st = fields["status"] as? [String: Any] ?? [:]
                let cat = (st["statusCategory"] as? [String: Any])?["key"] as? String ?? "new"
                let resolved: Date? = (fields["resolutiondate"] as? String).flatMap { s in
                    let f = DateFormatter()
                    f.locale = Locale(identifier: "en_US_POSIX")
                    f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
                    return f.date(from: s)
                }
                issues.append(Issue(key: raw["key"] as? String ?? "", summary: fields["summary"] as? String ?? "",
                                    statusCategory: cat, status: st["name"] as? String ?? "", resolved: resolved))
            }
            nextToken = (json["isLast"] as? Bool) == true ? nil : json["nextPageToken"] as? String
        } while nextToken != nil && issues.count < 2000
        return issues
    }

    /// Imports the project's issues: creates tasks for open issues not yet linked,
    /// and aligns status/title of tasks already linked (Jira is the source of truth on import).
    @MainActor
    static func importIssues(store: Store, jql customJQL: String? = nil) async throws -> String {
        try await syncIssues(store: store, jql: customJQL).message
    }

    /// Imports issues and reports the newly created ones (for notifications).
    @MainActor
    static func syncIssues(store: Store, jql customJQL: String? = nil) async throws -> (message: String, new: [(TaskItem, Issue)]) {
        if customJQL == nil && projectKey.isEmpty { throw APIError(400, "Renseigne la clé du projet Jira dans Réglages › Jira.") }
        let jql = customJQL ?? "project = \(projectKey) ORDER BY key ASC"
        let issues = try await search(jql: jql)
        var created = 0, updated = 0
        var newOnes: [(TaskItem, Issue)] = []
        let defaultProject = store.projects.first { $0.name.caseInsensitiveCompare(defaultProjectName) == .orderedSame }
        /// Jira "À faire" = committed work → board "À faire"; waiting statuses stay in the backlog.
        func mapped(_ issue: Issue) -> TaskStatus {
            switch issue.statusCategory {
            case "done": return .done
            case "indeterminate":
                let name = issue.status.lowercased()
                return name.contains("revue") || name.contains("review") || name.contains("test") || name.contains("recette") ? .almost_done : .in_progress
            default:
                let name = issue.status.lowercased()
                return name.contains("attente") || name.contains("backlog") || name.contains("hold") ? .backlog : .todo
            }
        }
        for issue in issues where !issue.key.isEmpty {
            let target = mapped(issue)
            if var t = store.tasks.first(where: { $0.jiraKey == issue.key }) {
                let before = t
                if t.title.isEmpty || detectKey(in: t.title) == issue.key { t.title = issue.summary }
                // Jira "new" category: keep the local choice between backlog and todo, except promote "À faire" to the board
                if issue.statusCategory == "new" {
                    if target == .todo && t.status == .backlog { t.status = .todo }
                } else {
                    t.status = target
                }
                if target == .done, let r = issue.resolved { t.completedAt = r }
                t.url = browseURL(issue.key)?.absoluteString
                if t != before { store.upsertTask(t, syncToJira: false); updated += 1 }
            } else {
                var t = TaskItem(title: issue.summary)
                if target == .done { t.completedAt = issue.resolved ?? Date() }
                t.jiraKey = issue.key
                t.url = browseURL(issue.key)?.absoluteString
                t.projectId = defaultProject?.id
                t.context = .pro
                t.status = target
                let saved = store.upsertTask(t, syncToJira: false)
                created += 1
                if target != .done { newOnes.append((saved, issue)) }
            }
        }
        return ("\(created) tickets ajoutés, \(updated) mis à jour (\(issues.count) tickets \(projectKey))", newOnes)
    }
}

// MARK: - Push changes to Jira

extension Jira {
    static var syncEnabled: Bool {
        UserDefaults.standard.object(forKey: "jiraSync") as? Bool ?? true
    }

    private static func request(_ method: String, _ path: String, body: Any? = nil) async throws -> Any? {
        guard isConfigured else { throw APIError(400, "Jira non configuré") }
        var req = URLRequest(url: URL(string: baseURL + path)!)
        req.httpMethod = method
        let auth = Data("\(email):\(token)".utf8).base64EncodedString()
        req.setValue("Basic \(auth)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            var msg = String(data: data, encoding: .utf8) ?? ""
            if let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let errs = (j["errorMessages"] as? [String] ?? []) + ((j["errors"] as? [String: String])?.map { "\($0.key): \($0.value)" } ?? [])
                if !errs.isEmpty { msg = errs.joined(separator: " · ") }
            }
            throw APIError(502, "Jira \(status) : \(msg.prefix(240))")
        }
        return data.isEmpty ? nil : try? JSONSerialization.jsonObject(with: data)
    }

    /// Jira status category matching a local column.
    private static func category(for status: TaskStatus) -> String {
        switch status {
        case .backlog, .todo: "new"
        case .in_progress, .almost_done: "indeterminate"
        case .done: "done"
        }
    }

    /// Moves the issue to a status of the right category (À faire / En cours / Terminé).
    static func transition(key: String, to status: TaskStatus) async throws {
        let wanted = category(for: status)
        let json = try await request("GET", "/rest/api/3/issue/\(key)?fields=status") as? [String: Any]
        let statusObj = (json?["fields"] as? [String: Any])?["status"] as? [String: Any]
        let current = (statusObj?["statusCategory"] as? [String: Any])?["key"] as? String
        let currentName = (statusObj?["name"] as? String ?? "").lowercased()
        let isReview = currentName.contains("revue") || currentName.contains("review") || currentName.contains("test") || currentName.contains("recette")
        if current == wanted {
            // "En cours" and "Revue en cours" share the indeterminate category: compare names there
            if status == .almost_done ? isReview : status == .in_progress ? !isReview : true { return }
        }

        let tj = try await request("GET", "/rest/api/3/issue/\(key)/transitions") as? [String: Any]
        let transitions = tj?["transitions"] as? [[String: Any]] ?? []
        func cat(_ t: [String: Any]) -> String? {
            ((t["to"] as? [String: Any])?["statusCategory"] as? [String: Any])?["key"] as? String
        }
        func name(_ t: [String: Any]) -> String { ((t["to"] as? [String: Any])?["name"] as? String ?? "").lowercased() }
        let candidates = transitions.filter { cat($0) == wanted && name($0) != currentName }
        // Prefer the obvious names when a workflow offers several targets in the same category.
        let preferred: [String] = switch status {
        case .backlog: ["backlog", "à faire", "to do"]
        case .todo: ["à faire", "to do", "selected for development", "backlog"]
        case .in_progress: ["en cours", "in progress"]
        case .almost_done: ["revue en cours", "en revue", "in review", "review", "recette", "test"]
        case .done: ["terminé", "done", "fini", "closed", "résolu"]
        }
        let pick = candidates.first { preferred.contains(name($0)) } ?? candidates.first
        guard let id = pick?["id"] as? String else {
            let names = transitions.map(name).joined(separator: ", ")
            throw APIError(409, "\(key) : aucune transition vers « \(status.label) » (possibles : \(names))")
        }
        _ = try await request("POST", "/rest/api/3/issue/\(key)/transitions", body: ["transition": ["id": id]])
    }

    static func updateFields(key: String, summary: String?, dueDate: Date??) async throws {
        var fields: [String: Any] = [:]
        if let summary { fields["summary"] = summary }
        if let dueDate { fields["duedate"] = dueDate.map(Fmt.isoDay) ?? NSNull() }
        guard !fields.isEmpty else { return }
        _ = try await request("PUT", "/rest/api/3/issue/\(key)", body: ["fields": fields])
    }

    /// Creates an issue in the configured project, assigned to me. Returns the new key.
    static func createIssue(summary: String, dueDate: Date?) async throws -> String {
        let me = try await request("GET", "/rest/api/3/myself") as? [String: Any]
        let types = try await request("GET", "/rest/api/3/issue/createmeta/\(projectKey)/issuetypes") as? [String: Any]
        let list = (types?["issueTypes"] as? [[String: Any]] ?? types?["values"] as? [[String: Any]] ?? [])
            .filter { ($0["subtask"] as? Bool) != true }
        let typeId = (list.first { ["task", "tâche"].contains(($0["name"] as? String ?? "").lowercased()) } ?? list.first)?["id"] as? String
        var fields: [String: Any] = [
            "project": ["key": projectKey],
            "summary": summary,
            "issuetype": typeId.map { ["id": $0] } ?? ["name": "Task"],
        ]
        if let id = me?["accountId"] as? String { fields["assignee"] = ["accountId": id] }
        if let dueDate { fields["duedate"] = Fmt.isoDay(dueDate) }
        let res = try await request("POST", "/rest/api/3/issue", body: ["fields": fields]) as? [String: Any]
        guard let key = res?["key"] as? String else { throw APIError(502, "Jira n'a pas renvoyé de clé") }
        return key
    }
}

// MARK: - Watching for new tickets

import UserNotifications

extension Jira {
    /// Extra project keys watched for new tickets (notification only, no import). Ex. "RC".
    static var watchedProjects: [String] {
        (UserDefaults.standard.string(forKey: "jiraWatch") ?? "")
            .split(whereSeparator: { $0 == "," || $0 == " " }).map { $0.uppercased() }.filter { !$0.isEmpty && $0 != projectKey }
    }

    private static var seen: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "jira.seen") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "jira.seen") }
    }
}

final class NotificationHandler: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationHandler()

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        await MainActor.run {
            if let id = info["taskId"] as? String {
                NSApp.activate(ignoringOtherApps: true)
                WindowOpener.openTask?(id)
            } else if let url = (info["url"] as? String).flatMap(URL.init(string:)) {
                NSWorkspace.shared.open(url)
            }
        }
    }
}

extension Store {
    func notify(title: String, body: String, info: [String: String] = [:]) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        c.userInfo = info
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    /// Imports the project's changes and notifies about new tickets (also in watched projects).
    func checkJira() async {
        guard Jira.isConfigured else { return }
        do {
            let result = try await Jira.syncIssues(store: self)
            for (task, issue) in result.new {
                notify(title: "Nouveau ticket \(issue.key)", body: issue.summary, info: ["taskId": task.id])
                showToast("✓ Nouveau ticket \(issue.key) : \(issue.summary)")
            }
            let watched = Jira.watchedProjects
            if !watched.isEmpty {
                let issues = try await Jira.search(jql: "project in (\(watched.joined(separator: ","))) AND created >= -7d ORDER BY created DESC")
                let firstRun = UserDefaults.standard.stringArray(forKey: "jira.seen") == nil
                var seen = Set(UserDefaults.standard.stringArray(forKey: "jira.seen") ?? [])
                for i in issues where !seen.contains(i.key) {
                    seen.insert(i.key)
                    if !firstRun {
                        notify(title: "Nouveau ticket \(i.key)", body: i.summary, info: ["url": Jira.browseURL(i.key)?.absoluteString ?? ""])
                    }
                }
                UserDefaults.standard.set(Array(seen), forKey: "jira.seen")
            }
            jiraLastCheck = Date()
        } catch {
            NSLog("Jira check failed: \(error)")
        }
    }

    func startJiraPolling() {
        UNUserNotificationCenter.current().delegate = NotificationHandler.shared
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        Task { await checkJira() }
        Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.checkJira() }
        }
    }
}

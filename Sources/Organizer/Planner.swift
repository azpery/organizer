import Foundation
import SwiftUI

// MARK: - Deterministic suggestions

struct Suggestion: Identifiable {
    let task: TaskItem
    let score: Int
    let reasons: [(text: String, color: Color)]
    var id: String { task.id }
}

extension Store {
    /// Ranks open tasks for today. Respects the active facet lens.
    func suggestions(limit: Int = 8) -> [Suggestion] {
        let cal = Calendar.app
        let today = cal.startOfDay(for: Date())
        let recentCutoff = cal.date(byAdding: .day, value: -2, to: today)!
        let recentlyWorked = Set(entries.filter { $0.start >= recentCutoff }.compactMap(\.taskId))

        return tasks.filter { $0.status != .done && taskInFacets($0) }.map { t in
            var score = 0
            var reasons: [(String, Color)] = []
            switch t.status {
            case .in_progress: score += 30; reasons.append(("En cours", .orange))
            case .almost_done: score += 34; reasons.append(("Presque terminé", .purple))
            case .todo: score += 15; reasons.append(("À faire", .blue))
            default: break
            }
            switch t.priority {
            case 3: score += 25; reasons.append(("Priorité haute", .red))
            case 2: score += 12; reasons.append(("Priorité moyenne", .orange))
            case 1: score += 5
            default: break
            }
            if let due = t.dueDate {
                let days = cal.dateComponents([.day], from: today, to: cal.startOfDay(for: due)).day ?? 0
                if days < 0 { score += 40 + min(20, -days); reasons.append(("En retard de \(-days) j", .red)) }
                else if days == 0 { score += 35; reasons.append(("Échéance aujourd'hui", .red)) }
                else if days <= 2 { score += 25; reasons.append(("Échéance dans \(days) j", .orange)) }
                else if days <= 7 { score += 10; reasons.append(("Échéance cette semaine", .yellow)) }
            }
            if let mr = mergeRequests[t.id]?.first(where: { $0.state == "opened" }) {
                if mr.pipeline == "failed" { score += 20; reasons.append(("Pipeline en échec", .red)) }
                else if !mr.draft { score += 10; reasons.append(("MR ouverte !\(mr.iid)", .purple)) }
            }
            if recentlyWorked.contains(t.id) { score += 8; reasons.append(("Travaillée récemment", .teal)) }
            if t.labels.contains(Facets.waiting) { score -= 15; reasons.append(("En attente", .gray)) }
            return Suggestion(task: t, score: score, reasons: reasons)
        }
        .filter { $0.score > 0 }
        .sorted { $0.score > $1.score }
        .prefix(limit).map { $0 }
    }
}

// MARK: - Ollama

enum Ollama {
    static var baseURL: String {
        let v = (UserDefaults.standard.string(forKey: "ollamaURL") ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        return v.isEmpty ? "http://localhost:11434" : v
    }
    static var model: String {
        let m = UserDefaults.standard.string(forKey: "ollamaModel") ?? ""
        return m.isEmpty ? "qwen3:8b" : m
    }
    /// Context window (memory grows with it: ~150 KB per token for qwen3:8b).
    static var contextSize: Int {
        let v = UserDefaults.standard.integer(forKey: "ollamaContext")
        return v >= 2048 ? v : 8192
    }
    /// How long the model stays in memory after the last request.
    static var keepAlive: String {
        let v = UserDefaults.standard.string(forKey: "ollamaKeepAlive") ?? ""
        return v.isEmpty ? "1m" : v
    }

    static func models() async throws -> [String] {
        var req = URLRequest(url: URL(string: baseURL + "/api/tags")!)
        req.timeoutInterval = 4
        let (data, _) = try await URLSession.shared.data(for: req)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (json?["models"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }.sorted()
    }

    static func chat(system: String, user: String, schema: [String: Any]? = nil) async throws -> String {
        var req = URLRequest(url: URL(string: baseURL + "/api/chat")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 300
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "model": model,
            "stream": false,
            "think": false,
            "options": ["temperature": 0.3, "num_ctx": contextSize],
            "keep_alive": keepAlive,
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
        ]
        if let schema { body["format"] = schema }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch {
            throw APIError(503, "Ollama injoignable sur \(baseURL). Active-le (Réglages › Ollama ou interrupteur de l'Assistant).")
        }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw APIError(502, "Ollama \(status) : \(String(data: data, encoding: .utf8)?.prefix(200) ?? "")")
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        var content = (json?["message"] as? [String: Any])?["content"] as? String ?? ""
        if let r = content.range(of: "</think>") { content = String(content[r.upperBound...]) }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - AI day plan

struct DayPlan: Codable {
    struct Item: Codable, Identifiable {
        var taskId: String
        var minutes: Int
        var why: String
        var start: String? = nil
        /// Concrete next actions on this ticket, derived from Jira description/comments and linked notes.
        var steps: [String]? = nil
        var id: String { taskId }
    }
    var date: String
    var summary: String
    var items: [Item]
    var advice: String
    var model: String
    var facets: [String]
    var followups: [String]? = nil

    static var key: String { "dayPlan" }

    static func load() -> DayPlan? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let plan = try? JSONDecoder().decode(DayPlan.self, from: data),
              plan.date == Fmt.isoDay(Date()) else { return nil }
        return plan
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: DayPlan.key) }
    }

    @MainActor func markdown(store: Store) -> String {
        var lines = ["## Plan du \(Fmt.longDay(Date()))", "", summary, ""]
        for (i, item) in items.enumerated() {
            let t = store.task(item.taskId)
            let key = t?.jiraKey.map { "\($0) · " } ?? ""
            let at = item.start.map { "\($0) · " } ?? ""
            lines.append("\(i + 1). \(at)**\(key)\(t?.title ?? "?")** — \(Fmt.short(Double(item.minutes * 60)))")
            lines.append("   \(item.why)")
            for step in item.steps ?? [] { lines.append("   - [ ] \(step)") }
        }
        if let f = followups, !f.isEmpty { lines += ["", "**À traiter (mails)**"] + f.map { "- \($0)" } }
        if !advice.isEmpty { lines += ["", "> \(advice)"] }
        return lines.joined(separator: "\n")
    }
}

extension Store {
    func generateDayPlan() async throws -> DayPlan {
        let candidates = suggestions(limit: 20)
        guard !candidates.isEmpty else { throw APIError(400, "Aucune tâche ouverte à planifier dans ces facettes") }
        let cal = Calendar.app
        let todayStart = cal.startOfDay(for: Date())
        let doneToday = entries.filter { $0.start >= todayStart }.reduce(0) { $0 + $1.duration }
        let hourNow = cal.component(.hour, from: Date())
        let events = todayEvents.filter { !$0.allDay && $0.end > Date() }
        let slots = freeSlots(events: todayEvents)
        let freeTotal = slots.reduce(0) { $0 + $1.1.timeIntervalSince($1.0) }
        let agenda = events.isEmpty ? "aucun" : events.map { "\(Fmt.time($0.start))-\(Fmt.time($0.end)) \($0.title)" }.joined(separator: " ; ")
        let recentMails = recentMailsForPlan()
        let mailLines = recentMails.isEmpty ? "aucun" : recentMails.map {
            "\n- [\($0.read ? "lu" : "NON LU")] \(Fmt.dayHeader($0.date)) \(Fmt.time($0.date)) · \($0.from) · « \($0.subject) » : \($0.excerpt.prefix(220))"
        }.joined()
        let free = slots.isEmpty ? "aucun" : slots.map { "\(Fmt.time($0.0))-\(Fmt.time($0.1))" }.joined(separator: ", ")

        let lines = candidates.map { s -> String in
            let t = s.task
            var parts = ["id=\(t.id)", "titre=\(t.title)"]
            if let k = t.jiraKey { parts.append("jira=\(k)") }
            parts.append("statut=\(t.status.label)")
            if let p = project(t.projectId) { parts.append("projet=\(p.name)") }
            if !t.labels.isEmpty { parts.append("facettes=\(t.labels.joined(separator: "/"))") }
            if let d = t.dueDate { parts.append("échéance=\(Fmt.date(d))") }
            if t.priority > 0 { parts.append("priorité=\(t.priority)/3") }
            let tracked = trackedTime(task: t.id)
            if tracked > 0 { parts.append("temps_passé=\(Fmt.short(tracked))") }
            if let e = t.estimateMinutes { parts.append("estimation=\(e)min") }
            if !s.reasons.isEmpty { parts.append("signaux=\(s.reasons.map(\.text).joined(separator: ", "))") }
            let note = t.notes.replacingOccurrences(of: "\n", with: " ").prefix(280)
            if !note.isEmpty { parts.append("notes=\(note)") }
            return "- " + parts.joined(separator: " | ")
        }

        let system = """
        Tu es l'assistant d'organisation de \(Profile.who). Tu proposes un plan de journée réaliste, en français, concis.
        Règles : 3 à 6 tâches maximum, uniquement parmi la liste fournie (utilise exactement leurs id). Commence par ce qui est en retard \
        ou bloque d'autres personnes, regroupe les sujets proches, prévois des durées réalistes (15 à 180 min) dont le total tient \
        dans les créneaux libres indiqués (les réunions de l'agenda sont intouchables). Les tâches « En attente » ne demandent en général \
        qu'une relance courte.
        """
        _ = hourNow
        let user = """
        Nous sommes le \(Fmt.longDay(Date())), il est \(Fmt.time(Date())). Déjà travaillé aujourd'hui : \(Fmt.short(doneToday)).
        Agenda restant : \(agenda).
        Créneaux libres : \(free) (total \(Fmt.short(freeTotal))). Place les tâches dans ces créneaux uniquement, sans chevauchement.
        Mails reçus récemment : \(mailLines)
        Facettes actives : \(activeFacets.isEmpty ? "toutes" : activeFacets.sorted().joined(separator: ", ")).
        Tâches candidates (triées par score de priorité calculé) :
        \(lines.joined(separator: "\n"))

        Réponds en JSON : summary (1-2 phrases), items (task_id, start au format HH:mm dans un créneau libre, minutes, why en une phrase), \
        followups (0 à 4 actions courtes issues des mails : qui relancer ou à qui répondre, et pourquoi), advice (un conseil court).
        """
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "summary": ["type": "string"],
                "items": ["type": "array", "items": [
                    "type": "object",
                    "properties": ["task_id": ["type": "string"], "start": ["type": "string"], "minutes": ["type": "integer"], "why": ["type": "string"]],
                    "required": ["task_id", "start", "minutes", "why"],
                ]],
                "followups": ["type": "array", "items": ["type": "string"]],
                "advice": ["type": "string"],
            ],
            "required": ["summary", "items", "followups", "advice"],
        ]
        let raw = try await Ollama.chat(system: system, user: user, schema: schema)
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError(502, "Réponse Ollama illisible : \(raw.prefix(200))")
        }
        let validIds = Set(candidates.map(\.task.id))
        let items = (json["items"] as? [[String: Any]] ?? []).compactMap { i -> DayPlan.Item? in
            guard let id = i["task_id"] as? String, validIds.contains(id) else { return nil }
            let start = (i["start"] as? String).flatMap { WorkHours.parse($0) != nil ? $0 : nil }
            return DayPlan.Item(taskId: id, minutes: max(10, min(240, i["minutes"] as? Int ?? 60)), why: i["why"] as? String ?? "", start: start)
        }
        guard !items.isEmpty else { throw APIError(502, "Le modèle n'a proposé aucune tâche valide. Réessaie.") }
        var sortedItems = items.sorted { ($0.start ?? "99") < ($1.start ?? "99") }
        // Second pass: what exactly to do on each planned ticket
        if let steps = try? await planSteps(for: sortedItems) {
            for i in sortedItems.indices { sortedItems[i].steps = steps[sortedItems[i].taskId] }
        }
        let plan = DayPlan(date: Fmt.isoDay(Date()), summary: json["summary"] as? String ?? "", items: sortedItems,
                           advice: json["advice"] as? String ?? "", model: Ollama.model, facets: activeFacets.sorted(),
                           followups: json["followups"] as? [String])
        plan.save()
        return plan
    }
}

extension Store {
    /// Gathers the ticket context (Jira description, recent comments, linked notes, follow-up) for each planned task
    /// and asks the model for the concrete next actions.
    func planSteps(for items: [DayPlan.Item]) async throws -> [String: [String]] {
        var blocks: [String] = []
        let budget = max(1200, 9000 / max(1, items.count))
        for item in items {
            guard let t = task(item.taskId) else { continue }
            var s = "### task_id=\(t.id) · \(t.jiraKey.map { "\($0) " } ?? "")\(t.title) [\(t.status.label)]"
            s += "\nCréneau prévu : \(item.minutes) min"
            if !t.notes.isEmpty { s += "\nSuivi local :\n\(t.notes.prefix(600))" }
            if let mr = mergeRequests[t.id]?.first { s += "\nMR !\(mr.iid) \(mr.label)" }
            if let key = t.jiraKey, Jira.isConfigured, let j = try? await Jira.issueDetail(key: key) {
                s += "\nStatut Jira : \(j.status)"
                if !j.descriptionMarkdown.isEmpty { s += "\nDescription Jira :\n\(j.descriptionMarkdown.prefix(budget))" }
                for c in j.comments.suffix(2) { s += "\nCommentaire (\(c.author)) : \(c.markdown.prefix(400))" }
                let subs = j.links.filter { $0.relation.lowercased().contains("sous") || $0.relation.lowercased().contains("sub") }
                if !subs.isEmpty { s += "\nSous-tâches : " + subs.map { "\($0.key) \($0.summary) [\($0.status)]" }.joined(separator: " ; ") }
            }
            for n in notes where n.taskId == t.id { s += "\nNote liée « \(n.title) » :\n\(n.body.prefix(800))" }
            blocks.append(s)
        }
        guard !blocks.isEmpty else { return [:] }
        let system = """
        Tu aides \(Profile.who) à savoir exactement quoi faire sur chaque ticket aujourd'hui. En français, concret et actionnable.
        Pour chaque tâche, donne 2 à 5 étapes courtes (verbe à l'infinitif, 15 mots max) réalisables dans le créneau prévu, \
        en t'appuyant sur ce qui reste à faire d'après la description, les commentaires et les notes (ignore ce qui est déjà fait). \
        Si la tâche est bloquée ou en attente, l'étape est la relance précise (qui, quoi). \
        C'est \(Profile.name) qui fait les étapes, ne lui demande jamais de se relancer lui-même. N'invente rien qui ne soit pas dans le contexte.
        """
        let user = blocks.joined(separator: "\n\n") + "\n\nRéponds en JSON : tasks (task_id, steps)."
        let schema: [String: Any] = [
            "type": "object",
            "properties": ["tasks": ["type": "array", "items": [
                "type": "object",
                "properties": ["task_id": ["type": "string"], "steps": ["type": "array", "items": ["type": "string"]]],
                "required": ["task_id", "steps"],
            ]]],
            "required": ["tasks"],
        ]
        let raw = try await Ollama.chat(system: system, user: user, schema: schema)
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var result: [String: [String]] = [:]
        for entry in json["tasks"] as? [[String: Any]] ?? [] {
            guard let id = entry["task_id"] as? String else { continue }
            let steps = (entry["steps"] as? [String] ?? []).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if !steps.isEmpty { result[id] = Array(steps.prefix(5)) }
        }
        return result
    }
}

import Foundation
import SwiftUI

struct ChatMessage: Identifiable, Codable, Equatable {
    var id = UUID().uuidString
    var role: String            // user, assistant
    var content: String
    var actions: [String] = []  // actions performed by tools, shown as chips
    var sources: [String] = []  // context items used
    var date = Date()
}

/// Local chat with Ollama, grounded on the app's data, with a few tools to act on it.
@MainActor
final class ChatModel: ObservableObject {
    static let shared = ChatModel()

    @Published var messages: [ChatMessage] = []
    @Published var generating = false
    @Published var error: String?
    private var current: Task<Void, Never>?
    /// The UI conversation is persisted; API conversations are ephemeral and separate.
    private let persistent: Bool

    private var file: URL { Store.shared.supportDir.appendingPathComponent("chat.json") }

    init(persistent: Bool = true) {
        self.persistent = persistent
        if persistent, let d = try? Data(contentsOf: file), let m = try? JSONDecoder().decode([ChatMessage].self, from: d) { messages = m }
    }

    private func persist() {
        guard persistent else { return }
        if let d = try? JSONEncoder().encode(messages.suffix(200)) {
            try? d.write(to: file)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
    }

    func reset() {
        stop()
        messages = []
        error = nil
        persist()
    }

    func stop() {
        current?.cancel()
        current = nil
        generating = false
    }

    func send(_ text: String, store: Store) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !generating else { return }
        error = nil
        messages.append(ChatMessage(role: "user", content: text))
        messages.append(ChatMessage(role: "assistant", content: ""))
        let replyId = messages.last!.id
        let previous = Array(messages.dropLast().suffix(16))
        generating = true

        current = Task { [weak self] in
            guard let self else { return }
            let (context, sources) = await Assistant.context(for: text, store: store)
            if let i = self.messages.firstIndex(where: { $0.id == replyId }) { self.messages[i].sources = sources }
            // history sent to the model: system + last 16 exchanges
            var history: [[String: Any]] = [["role": "system", "content": Assistant.systemPrompt(store: store) + "\n\n" + context]]
            for m in previous { history.append(["role": m.role, "content": m.content]) }
            do {
                for _ in 0..<4 {
                    let result = try await Ollama.chatStream(messages: history, tools: Assistant.tools) { token in
                        Task { @MainActor in self.append(token, to: replyId) }
                    }
                    if result.toolCalls.isEmpty { break }
                    history.append(["role": "assistant", "content": result.content, "tool_calls": result.toolCalls])
                    for call in result.toolCalls {
                        let fn = call["function"] as? [String: Any] ?? [:]
                        let name = fn["name"] as? String ?? ""
                        let args = (fn["arguments"] as? [String: Any])
                            ?? ((fn["arguments"] as? String)?.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
                            ?? [:]
                        let (output, chip) = Assistant.run(name, args, store: store)
                        if let chip { self.addAction(chip, to: replyId) }
                        history.append(["role": "tool", "content": output])
                    }
                }
            } catch is CancellationError {
            } catch {
                self.error = (error as? APIError)?.message ?? error.localizedDescription
            }
            self.finish(replyId)
        }
    }

    private func append(_ token: String, to id: String) {
        guard let i = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[i].content += token
    }

    private func addAction(_ chip: String, to id: String) {
        guard let i = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[i].actions.append(chip)
    }

    private func finish(_ id: String) {
        if let i = messages.firstIndex(where: { $0.id == id }) {
            var c = messages[i].content
            while let r = c.range(of: "<think>"), let e = c.range(of: "</think>", range: r.upperBound..<c.endIndex) {
                c.removeSubrange(r.lowerBound..<e.upperBound)
            }
            messages[i].content = c.trimmingCharacters(in: .whitespacesAndNewlines)
            if messages[i].content.isEmpty && messages[i].actions.isEmpty && error == nil {
                messages[i].content = "_(pas de réponse)_"
            }
        }
        generating = false
        current = nil
        persist()
    }

    func transcriptMarkdown() -> String {
        messages.map { m in
            (m.role == "user" ? "**Moi** — " : "**Assistant** — ") + Fmt.time(m.date) + "\n\n" + m.content
                + (m.actions.isEmpty ? "" : "\n\n" + m.actions.map { "- ✓ \($0)" }.joined(separator: "\n"))
        }.joined(separator: "\n\n---\n\n")
    }
}

extension Ollama {
    /// Streams a chat completion; returns the full content and any tool calls.
    static func chatStream(messages: [[String: Any]], tools: [[String: Any]],
                           onToken: @escaping (String) -> Void) async throws -> (content: String, toolCalls: [[String: Any]]) {
        var req = URLRequest(url: URL(string: baseURL + "/api/chat")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 600
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model, "stream": true, "think": false, "messages": messages, "tools": tools,
            "options": ["temperature": 0.4, "num_ctx": contextSize], "keep_alive": keepAlive,
        ])
        let bytes: URLSession.AsyncBytes
        let resp: URLResponse
        do { (bytes, resp) = try await URLSession.shared.bytes(for: req) }
        catch { throw APIError(503, "Ollama injoignable sur \(baseURL). Active-le avec l'interrupteur Ollama (en haut de l'Assistant ou dans Réglages).") }
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            var body = ""
            for try await line in bytes.lines { body += line }
            throw APIError(502, "Ollama : \(body.prefix(200))")
        }
        var content = ""
        var calls: [[String: Any]] = []
        // Batch tokens (~12 UI updates per second) instead of one update per token.
        var pending = ""
        var lastFlush = Date()
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard let d = line.data(using: .utf8), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            if let msg = j["message"] as? [String: Any] {
                if let t = msg["content"] as? String, !t.isEmpty {
                    content += t
                    pending += t
                    if Date().timeIntervalSince(lastFlush) > 0.08 { onToken(pending); pending = ""; lastFlush = Date() }
                }
                if let tc = msg["tool_calls"] as? [[String: Any]] { calls += tc }
            }
            if j["done"] as? Bool == true { break }
        }
        if !pending.isEmpty { onToken(pending) }
        return (content, calls)
    }
}

@MainActor
enum Assistant {
    static func systemPrompt(store: Store) -> String {
        let facets = store.activeFacets.isEmpty ? "toutes" : store.activeFacets.sorted().joined(separator: ", ")
        return """
        Tu es l'assistant personnel de \(Profile.who). \
        Tu réponds en français, de façon concise, concrète et chaleureuse, en Markdown léger. \
        Tu t'appuies sur le contexte fourni (tâches, agenda, notes, mails) et tu dis clairement quand une information n'y figure pas. \
        Quand \(Profile.name) te demande d'agir (créer une tâche, changer un statut, lancer le chrono, noter quelque chose), utilise les outils ; \
        sinon, ne les utilise pas. Nous sommes le \(Fmt.longDay(Date())), il est \(Fmt.time(Date())). Facettes actives : \(facets).
        Calendrier (pour convertir « vendredi », « lundi prochain »… en date AAAA-MM-JJ) : \(upcomingDays())
        """
    }

    static func upcomingDays() -> String {
        let cal = Calendar.app
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "EEEE"
        return (0..<14).compactMap { i -> String? in
            guard let d = cal.date(byAdding: .day, value: i, to: cal.startOfDay(for: Date())) else { return nil }
            return "\(f.string(from: d)) = \(Fmt.isoDay(d))" + (i == 0 ? " (aujourd'hui)" : "")
        }.joined(separator: ", ")
    }

    /// Always-on summary + retrieved items relevant to the question.
    static func context(for query: String, store: Store) async -> (String, [String]) {
        var parts: [String] = []
        var sources: [String] = []
        let cal = Calendar.app
        let today = cal.startOfDay(for: Date())

        let open = store.tasks.filter { ($0.status == .in_progress || $0.status == .almost_done || $0.status == .todo) && store.taskInFacets($0) }
            .sorted { ($0.status == .in_progress ? 0 : 1, $0.dueDate ?? .distantFuture) < ($1.status == .in_progress ? 0 : 1, $1.dueDate ?? .distantFuture) }
        if !open.isEmpty {
            parts.append("## Tâches ouvertes\n" + open.prefix(25).map { t in
                var s = "- \(t.jiraKey.map { "\($0) " } ?? "")\(t.title) [\(t.status.label)]"
                if let d = t.dueDate { s += " échéance \(Fmt.date(d))\(d < today ? " (EN RETARD)" : "")" }
                if !t.labels.isEmpty { s += " {\(t.labels.joined(separator: ", "))}" }
                return s
            }.joined(separator: "\n"))
        }
        if let r = store.runningEntry { parts.append("Chrono en cours : « \(r.description) » depuis \(Fmt.time(r.start)).") }
        let worked = store.entries(from: today, to: today.addingTimeInterval(86400)).reduce(0) { $0 + $1.duration }
        parts.append("Temps travaillé aujourd'hui : \(Fmt.short(worked)).")
        if !store.todayEvents.isEmpty {
            parts.append("## Agenda du jour\n" + store.todayEvents.map { e in
                e.allDay ? "- (journée) \(e.title)" : "- \(Fmt.time(e.start))–\(Fmt.time(e.end)) \(e.title)"
            }.joined(separator: "\n"))
            let free = store.freeSlots(events: store.todayEvents)
            if !free.isEmpty { parts.append("Créneaux libres : " + free.map { "\(Fmt.time($0.0))–\(Fmt.time($0.1))" }.joined(separator: ", ")) }
        }
        if let plan = DayPlan.load() {
            parts.append("## Plan du jour déjà proposé\n" + plan.items.compactMap { i in
                store.task(i.taskId).map { "- \(i.start ?? "") \($0.jiraKey ?? "") \($0.title) (\(i.minutes) min)" }
            }.joined(separator: "\n"))
        }

        // Retrieval
        let kw = Store.keywords(query)
        let keys = Set(Jira.detectKey(in: query).map { [$0] } ?? [])
        if !kw.isEmpty || !keys.isEmpty {
            func score(_ text: String) -> Int { Store.keywords(text).intersection(kw).count }

            var taskHits: [(TaskItem, Int)] = []
            for t in store.tasks {
                var sc = score(t.title) * 3 + score(t.notes)
                if let k = t.jiraKey, keys.contains(k) { sc += 20 }
                if sc >= 2 { taskHits.append((t, sc)) }
            }
            taskHits.sort { $0.1 > $1.1 }
            var linkedNoteIds = Set<String>()
            for (t, _) in taskHits.prefix(3) {
                var s = "### Tâche \(t.jiraKey ?? "") \(t.title) [\(t.status.label)]"
                if !t.notes.isEmpty { s += "\nSuivi :\n\(t.notes.prefix(900))" }
                if let mr = store.mergeRequests[t.id]?.first { s += "\nMR !\(mr.iid) \(mr.label)" }
                // Jira description (where scope, progress and blockers usually live) for explicitly cited tickets
                if let key = t.jiraKey, keys.contains(key), Jira.isConfigured,
                   let j = try? await Jira.issueDetail(key: key) {
                    s += "\nStatut Jira : \(j.status)" + (j.assignee.map { ", assigné à \($0)" } ?? "")
                    if !j.descriptionMarkdown.isEmpty { s += "\nDescription Jira :\n\(j.descriptionMarkdown.prefix(3500))" }
                    if let c = j.comments.last { s += "\nDernier commentaire (\(c.author)) : \(c.markdown.prefix(600))" }
                    sources.append("Jira · \(key)")
                }
                parts.append(s)
                sources.append("Tâche · \(t.jiraKey ?? t.title)")
                for n in store.notes where n.taskId == t.id && !linkedNoteIds.contains(n.id) {
                    linkedNoteIds.insert(n.id)
                    parts.append("### Note liée à \(t.jiraKey ?? t.title) : « \(n.title) »\n\(n.body.prefix(1500))")
                    sources.append("Note · \(n.title)")
                }
            }

            var noteHits: [(Note, Int)] = []
            for n in store.notes {
                let sc = score(n.title) * 3 + score(n.body) + (keys.contains { n.body.uppercased().contains($0) } ? 6 : 0)
                if sc >= 2 { noteHits.append((n, sc)) }
            }
            noteHits.sort { $0.1 > $1.1 }
            for (n, _) in noteHits.filter({ !linkedNoteIds.contains($0.0.id) }).prefix(3) {
                parts.append("### Note « \(n.title) » (\(Fmt.date(n.updatedAt)))\n\(n.body.prefix(1200))")
                sources.append("Note · \(n.title)")
            }

            var mailHits: [(MailSnippet, Int)] = []
            for m in store.mails where !Store.isAutomated(m) {
                let sc = score(m.subject) * 3 + score(m.excerpt) + score(m.from)
                if sc >= 3 { mailHits.append((m, sc)) }
            }
            mailHits.sort { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.date > $1.0.date }
            for (m, _) in mailHits.prefix(4) {
                parts.append("### Mail de \(m.from) — « \(m.subject) » (\(Fmt.date(m.date)), \(m.read ? "lu" : "non lu"))\n\(m.excerpt.prefix(700))")
                sources.append("Mail · \(m.subject)")
            }
        }
        // Mails questions without keywords: give the latest unread ones.
        let lower = query.lowercased()
        if lower.contains("mail") && sources.allSatisfy({ !$0.hasPrefix("Mail") }) {
            for m in store.recentMailsForPlan(limit: 8) {
                parts.append("### Mail de \(m.from) — « \(m.subject) » (\(Fmt.date(m.date)), \(m.read ? "lu" : "non lu"))\n\(m.excerpt.prefix(400))")
                sources.append("Mail · \(m.subject)")
            }
        }
        return ("# Contexte\n" + parts.joined(separator: "\n\n"), sources)
    }

    static let tools: [[String: Any]] = [
        fn("create_task", "Crée une tâche dans Organizer.", [
            "title": ["type": "string", "description": "Titre de la tâche"],
            "status": ["type": "string", "enum": ["backlog", "todo", "in_progress"], "description": "Colonne (défaut : backlog)"],
            "due_date": ["type": "string", "description": "Échéance AAAA-MM-JJ (optionnel)"],
            "labels": ["type": "array", "items": ["type": "string"], "description": "Facettes (optionnel)"],
            "priority": ["type": "integer", "description": "0 à 3 (optionnel)"],
        ], required: ["title"]),
        fn("move_task", "Change le statut d'une tâche existante (identifiée par sa clé de ticket ou un extrait de son titre).", [
            "task": ["type": "string"], "status": ["type": "string", "enum": ["backlog", "todo", "in_progress", "almost_done", "done"]],
        ], required: ["task", "status"]),
        fn("start_timer", "Lance le chrono sur une tâche (clé de ticket ou extrait du titre) ou sur une description libre.", [
            "task": ["type": "string"],
        ], required: ["task"]),
        fn("create_mindmap", "Crée une carte mentale (mind map) dans Organizer pour structurer un sujet, un projet, une réunion ou une journée. Donne 3 à 8 branches principales, chacune avec ses sous-idées courtes. Cite la clé du ticket quand une idée correspond à un ticket.", [
            "title": ["type": "string", "description": "Sujet central de la carte"],
            "branches": ["type": "array", "description": "Branches principales", "items": [
                "type": "object",
                "properties": [
                    "text": ["type": "string", "description": "Idée principale (2 à 6 mots)"],
                    "children": ["type": "array", "items": ["type": "string"], "description": "Sous-idées courtes"],
                ],
                "required": ["text"],
            ]],
            "labels": ["type": "array", "items": ["type": "string"], "description": "Facettes (optionnel)"],
        ], required: ["title", "branches"]),
        fn("add_to_mindmap", "Ajoute des idées à une carte mentale existante (sous une branche donnée, ou à la racine).", [
            "map": ["type": "string", "description": "Titre (ou extrait) de la carte"],
            "under": ["type": "string", "description": "Texte de la branche parente (optionnel, défaut : racine)"],
            "ideas": ["type": "array", "items": ["type": "string"]],
        ], required: ["map", "ideas"]),
        fn("create_note", "Crée une note Markdown dans Organizer.", [
            "title": ["type": "string"], "body": ["type": "string"],
            "labels": ["type": "array", "items": ["type": "string"]],
        ], required: ["title", "body"]),
    ]

    private static func fn(_ name: String, _ desc: String, _ props: [String: Any], required: [String]) -> [String: Any] {
        ["type": "function", "function": ["name": name, "description": desc,
                                          "parameters": ["type": "object", "properties": props, "required": required]]]
    }

    private static func findTask(_ ref: String, store: Store) -> TaskItem? {
        let r = ref.trimmingCharacters(in: .whitespaces)
        if let k = Jira.detectKey(in: r) {
            if let t = store.tasks.first(where: { $0.jiraKey == k }) { return t }
        }
        return store.tasks.filter { $0.status != .done }.first { $0.title.localizedCaseInsensitiveContains(r) }
            ?? store.tasks.first { $0.title.localizedCaseInsensitiveContains(r) }
    }

    /// Ticket cited in a mind map idea (ABC-n) → linked task.
    @MainActor
    private static func findLinkedTask(_ text: String, store: Store) -> String? {
        guard let key = Jira.detectKey(in: text) else { return nil }
        return store.tasks.first { $0.jiraKey == key }?.id
    }

    /// Executes a tool call; returns the tool output and an optional chip for the UI.
    @MainActor
    static func run(_ name: String, _ a: [String: Any], store: Store) -> (String, String?) {
        switch name {
        case "create_task":
            guard let title = a["title"] as? String, !title.isEmpty else { return ("Erreur : titre manquant", nil) }
            var t = TaskItem(title: title)
            t.status = TaskStatus.parse(a["status"] as? String ?? "") ?? .backlog
            t.dueDate = parseDate(a["due_date"])
            t.labels = (a["labels"] as? [String]) ?? Array(store.activeFacets)
            t.priority = min(3, max(0, a["priority"] as? Int ?? 0))
            if let key = Jira.detectKey(in: title) { t.jiraKey = key; t.url = Jira.browseURL(key)?.absoluteString }
            store.upsertTask(t)
            return ("Tâche créée (\(t.status.label)) : \(title)", "Tâche créée : \(title)")
        case "move_task":
            guard let ref = a["task"] as? String, let t = findTask(ref, store: store),
                  let st = TaskStatus.parse(a["status"] as? String ?? "") else { return ("Erreur : tâche ou statut introuvable", nil) }
            store.moveTask(t.id, to: st)
            return ("\(t.title) → \(st.label)", "\(t.jiraKey ?? t.title) → \(st.label)")
        case "start_timer":
            let ref = a["task"] as? String ?? ""
            if let t = findTask(ref, store: store) {
                store.startTimer(description: t.title, projectId: t.projectId, taskId: t.id)
                return ("Chrono lancé sur \(t.title)", "Chrono lancé : \(t.jiraKey ?? t.title)")
            }
            store.startTimer(description: ref, projectId: nil, taskId: nil)
            return ("Chrono lancé : \(ref)", "Chrono lancé : \(ref)")
        case "create_mindmap":
            guard let title = (a["title"] as? String)?.trimmingCharacters(in: .whitespaces), !title.isEmpty else { return ("Erreur : titre manquant", nil) }
            var m = MindMap(title: title, labels: (a["labels"] as? [String]) ?? store.activeFacets.sorted())
            guard let root = m.root?.id else { return ("Erreur", nil) }
            var count = 0
            for b in a["branches"] as? [Any] ?? [] {
                // tolerate plain strings and {text, children} objects (children may be strings or objects)
                let obj = b as? [String: Any]
                guard let text = obj?["text"] as? String ?? b as? String, !text.isEmpty else { continue }
                let bid = m.addChild(to: root, text: text, taskId: findLinkedTask(text, store: store))
                count += 1
                for c in obj?["children"] as? [Any] ?? [] {
                    guard let ct = c as? String ?? (c as? [String: Any])?["text"] as? String, !ct.isEmpty else { continue }
                    m.addChild(to: bid, text: ct, taskId: findLinkedTask(ct, store: store))
                    count += 1
                }
            }
            guard count > 0 else { return ("Erreur : aucune branche fournie", nil) }
            let saved = store.upsertMindMap(m)
            UserDefaults.standard.set(saved.id, forKey: "mindmap.selected")
            return ("Carte mentale créée : « \(title) » (\(count) idées). Elle est dans l'onglet Mind mapping.", "Carte créée : \(title)")
        case "add_to_mindmap":
            let ref = (a["map"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            guard var m = store.mindmaps.first(where: { $0.title.localizedCaseInsensitiveCompare(ref) == .orderedSame })
                    ?? store.mindmaps.first(where: { !ref.isEmpty && $0.title.localizedCaseInsensitiveContains(ref) }) else {
                return ("Erreur : carte introuvable. Cartes : \(store.mindmaps.map(\.title).joined(separator: ", "))", nil)
            }
            let under = (a["under"] as? String).flatMap { u in m.nodes.first { $0.text.localizedCaseInsensitiveContains(u) } }?.id ?? m.root!.id
            let ideas = (a["ideas"] as? [String] ?? []).filter { !$0.isEmpty }
            for idea in ideas { m.addChild(to: under, text: idea, taskId: findLinkedTask(idea, store: store)) }
            store.upsertMindMap(m)
            UserDefaults.standard.set(m.id, forKey: "mindmap.selected")
            return ("\(ideas.count) idées ajoutées à « \(m.title) »", "Carte « \(m.title) » : +\(ideas.count)")
        case "create_note":
            let title = a["title"] as? String ?? "Note"
            store.upsertNote(Note(title: title, body: a["body"] as? String ?? "", labels: (a["labels"] as? [String]) ?? Array(store.activeFacets)))
            return ("Note créée : \(title)", "Note créée : \(title)")
        default:
            return ("Outil inconnu : \(name)", nil)
        }
    }
}

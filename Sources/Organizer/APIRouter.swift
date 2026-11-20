import Foundation
import AppKit

struct APIError: Error {
    let status: Int
    let message: String
    init(_ status: Int, _ message: String) { self.status = status; self.message = message }
}

@MainActor
final class APIRouter {
    unowned let store: Store

    init(store: Store) { self.store = store }

    static let endpoints: [String] = [
        "GET    /api/health",
        "GET    /api/projects",
        "POST   /api/projects                {name, color?, client?, context?}",
        "PATCH  /api/projects/{id}",
        "DELETE /api/projects/{id}",
        "GET    /api/tasks?status=&context=&project_id=&project=&label=&q=",
        "GET    /api/labels",
        "POST   /api/labels                  {name} déclarer une facette",
        "PATCH  /api/labels/{name}           {name, position?} renommer / fusionner / réordonner",
        "DELETE /api/labels/{name}           retirer une facette (de toutes les tâches)",
        "POST   /api/tasks                   {title, notes?, project_id?|project?, status?, context?, priority?, labels?, jira_key?, url?, due_date?, estimate_minutes?}",
        "POST   /api/tasks/batch             {tasks: [...]}",
        "POST   /api/tasks/{id}/jira         crée le ticket Jira et le relie",
        "POST   /api/ui/open/{id|CLÉ-n}      ouvrir la fiche d'une tâche dans l'app",
        "GET    /api/tasks/{id}/context      fiche complète : description Jira (Markdown), commentaires, notes, artifacts, MR, temps",
        "GET    /api/tasks/{id}",
        "PATCH  /api/tasks/{id}              (+ sync_jira: false pour ne pas répercuter dans Jira)",
        "POST   /api/tasks/{id}/move         {status}",
        "DELETE /api/tasks/{id}",
        "GET    /api/notes?label=&q=&task_id=",
        "POST   /api/notes                   {title, body?, labels?, task_id?|jira_key?, pinned?}",
        "GET/PATCH/DELETE /api/notes/{id}",
        "GET    /api/artifacts?label=&kind=&q=&task_id=",
        "POST   /api/artifacts               {title, url, kind? (artifact|document|design|code|link|file), summary?, labels?, task_id?|jira_key?}",
        "GET/PATCH/DELETE /api/artifacts/{id}",
        "GET    /api/overview?label=         tout ce qui appartient à une facette",
        "POST   /api/assistant/ask           {message} poser une question à l'assistant Ollama (réponse complète)",
        "GET    /api/mindmaps                cartes mentales (?label=&q=)",
        "POST   /api/mindmaps                créer {title, labels, children:[{text, task_id?, children}]}",
        "GET    /api/mindmaps/{id}           carte complète (tree + markdown)",
        "PATCH  /api/mindmaps/{id}           title, labels, children (remplace l'arbre)",
        "POST   /api/mindmaps/{id}/nodes     ajouter {parent_id?, text | children}",
        "DELETE /api/mindmaps/{id}           supprimer",
        "GET    /api/today                   suggestions du jour (+ plan IA s'il existe)",
        "GET    /api/calendar?date=YYYY-MM-DD événements Google Agenda + créneaux libres",
        "POST   /api/calendar/prepare        {title?|index?} préparer une réunion du jour (Ollama)",
        "GET    /api/mails?q=&unread=        mails récents synchronisés depuis Apple Mail",
        "POST   /api/mails/sync              resynchroniser",
        "POST   /api/today/plan              générer le plan du jour avec Ollama",
        "GET    /api/clients                 / POST {name, address?, email?, vat_number?, siret?, rate?, currency?, vat_mode?, projects?[]}",
        "PATCH  /api/clients/{id}",
        "GET    /api/invoices?status=&client=",
        "POST   /api/invoices/generate       {client|client_id, from, to, grouping? (task|project|day)} brouillon depuis le temps",
        "PATCH  /api/invoices/{id}           {status?, number?, notes?, lines?[{description, quantity, unit, unit_price}]}",
        "POST   /api/invoices/{id}/pdf       {path?} → chemin du PDF",
        "DELETE /api/invoices/{id}",
        "GET    /api/time-entries?from=&to=&project_id=&task_id=",
        "POST   /api/time-entries            {start, end?|duration_minutes?, description?, project_id?|project?, task_id?, tags?}",
        "PATCH  /api/time-entries/{id}",
        "DELETE /api/time-entries/{id}",
        "GET    /api/timer",
        "POST   /api/timer/start             {description?, project_id?|project?, task_id?}",
        "POST   /api/timer/stop",
        "GET    /api/reports/summary?from=&to=&context=",
        "POST   /api/import/clockify         {from?, to?}",
        "POST   /api/import/jira             {jql?}",
        "POST   /api/gitlab/refresh          rafraîchir les MR liées",
    ]

    func handle(_ req: HTTPRequest) async -> HTTPResponse {
        let parts = req.path.split(separator: "/").map(String.init)
        guard parts.first == "api" else { return .error(404, "Route inconnue. Voir GET /api/health") }
        let p = Array(parts.dropFirst())
        let resource = p.first ?? "health"
        let id = p.count > 1 ? p[1] : nil
        let action = p.count > 2 ? p[2] : nil

        if resource == "health" {
            return .json(["ok": true, "app": "Organizer", "version": 1, "endpoints": Self.endpoints])
        }
        guard authorized(req) else {
            return .error(401, "Token manquant ou invalide (header Authorization: Bearer <token>)")
        }

        var body: [String: Any] = [:]
        if !req.body.isEmpty {
            guard let obj = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any] else {
                return .error(400, "Corps JSON invalide (objet attendu)")
            }
            body = obj
        }

        do {
            switch (req.method, resource, id, action) {
            // Projects
            case ("GET", "projects", nil, nil):
                return .json(store.projects.map(encode))
            case ("POST", "projects", nil, nil):
                guard let name = body["name"] as? String, !name.isEmpty else { throw APIError(400, "name requis") }
                var proj = Project(name: name)
                try apply(body, to: &proj)
                return .json(encode(store.upsertProject(proj)), status: 201)
            case ("PATCH", "projects", let id?, nil):
                guard var proj = store.project(id) else { throw APIError(404, "Projet introuvable") }
                try apply(body, to: &proj)
                return .json(encode(store.upsertProject(proj)))
            case ("DELETE", "projects", let id?, nil):
                guard store.project(id) != nil else { throw APIError(404, "Projet introuvable") }
                store.deleteProject(id)
                return .json(["deleted": id])

            // Tasks
            case ("GET", "tasks", nil, nil):
                return .json(try listTasks(req.query).map(encode))
            case ("POST", "tasks", "batch", nil):
                guard let items = body["tasks"] as? [[String: Any]] else { throw APIError(400, "tasks (tableau) requis") }
                let created = try items.map { try createTask($0) }
                return .json(created.map(encode), status: 201)
            case ("POST", "tasks", nil, nil):
                return .json(encode(try createTask(body)), status: 201)
            case ("GET", "tasks", let id?, nil):
                guard let t = store.task(id) else { throw APIError(404, "Tâche introuvable") }
                var out = encode(t)
                out["time_entries"] = store.entries.filter { $0.taskId == id }.map(encode)
                return .json(out)
            case ("PATCH", "tasks", let id?, nil):
                guard var t = store.task(id) else { throw APIError(404, "Tâche introuvable") }
                try apply(body, to: &t, isNew: false)
                return .json(encode(store.upsertTask(t, syncToJira: body["sync_jira"] as? Bool ?? true)))
            case ("POST", "tasks", let id?, "move"):
                guard store.task(id) != nil else { throw APIError(404, "Tâche introuvable") }
                guard let s = body["status"] as? String, let status = TaskStatus.parse(s) else {
                    throw APIError(400, "status invalide (backlog, todo, in_progress, almost_done, done)")
                }
                return .json(encode(store.moveTask(id, to: status)!))
            case ("POST", "ui", "open", let ref?):
                guard let t = store.task(ref) ?? store.tasks.first(where: { $0.jiraKey?.caseInsensitiveCompare(ref) == .orderedSame }) else {
                    throw APIError(404, "Tâche introuvable")
                }
                NSApp.activate(ignoringOtherApps: true)
                WindowOpener.openTask?(t.id)
                return .json(["opened": t.id])
            case ("GET", "tasks", let id?, "context"):
                guard let t = store.task(id) else { throw APIError(404, "Tâche introuvable") }
                var out = encode(t)
                if let key = t.jiraKey, Jira.isConfigured, let j = try? await Jira.issueDetail(key: key) {
                    out["jira"] = [
                        "type": j.type, "status": j.status, "priority": n(j.priority), "assignee": n(j.assignee), "reporter": n(j.reporter),
                        "labels": j.labels, "description": j.descriptionMarkdown,
                        "comments": j.comments.map { ["author": $0.author, "date": n($0.date.map(Fmt.iso)), "body": $0.markdown] as [String: Any] },
                        "links": j.links.map { ["relation": $0.relation, "key": $0.key, "summary": $0.summary, "status": $0.status] },
                    ] as [String: Any]
                }
                out["notes_linked"] = store.notes.filter { $0.taskId == id }.map(encode)
                out["artifacts"] = store.artifacts.filter { $0.taskId == id }.map(encode)
                out["time_entries"] = store.entries.filter { $0.taskId == id }.map(encode)
                return .json(out)
            case ("POST", "tasks", let id?, "jira"):
                let key = try await store.createJiraIssue(for: id)
                return .json(encode(store.task(id)!).merging(["jira_key": key]) { $1 }, status: 201)
            case ("DELETE", "tasks", let id?, nil):
                guard store.task(id) != nil else { throw APIError(404, "Tâche introuvable") }
                store.deleteTask(id)
                return .json(["deleted": id])

            case ("GET", "labels", nil, nil):
                return .json(store.allLabels.map { ["name": $0.name, "count": $0.count] as [String: Any] })
            case ("POST", "labels", nil, nil):
                guard let name = body["name"] as? String, !name.isEmpty else { throw APIError(400, "name requis") }
                store.addFacet(name)
                return .json(store.allLabels.map { ["name": $0.name, "count": $0.count] as [String: Any] }, status: 201)
            case ("PATCH", "labels", let name?, nil):
                if let new = body["name"] as? String { store.renameLabel(name, to: new) }
                let current = (body["name"] as? String) ?? name
                if let pos = body["position"] as? Int {
                    store.addFacet(current)
                    var names = store.facetNames.filter { $0 != current }
                    names.insert(current, at: max(0, min(pos, names.count)))
                    store.facetNames = names
                }
                return .json(store.allLabels.map { ["name": $0.name, "count": $0.count] as [String: Any] })
            case ("DELETE", "labels", let name?, nil):
                store.removeFacet(name)
                return .json(["deleted": name])

            // Notes
            case ("GET", "notes", nil, nil):
                return .json(filterByCommon(store.notes, req.query, labels: \.labels, taskId: \.taskId,
                                            text: { $0.title + " " + $0.body }).map(encode))
            case ("POST", "notes", nil, nil):
                guard let title = body["title"] as? String, !title.isEmpty else { throw APIError(400, "title requis") }
                if let ext = body["external_id"] as? String, var existing = store.notes.first(where: { $0.externalId == ext }) {
                    try apply(body, to: &existing)
                    return .json(encode(store.upsertNote(existing, touch: body["updated_at"] == nil)))
                }
                var n = Note(title: title)
                try apply(body, to: &n)
                return .json(encode(store.upsertNote(n, touch: body["updated_at"] == nil)), status: 201)
            case ("GET", "notes", let id?, nil):
                guard let n = store.note(id) else { throw APIError(404, "Note introuvable") }
                return .json(encode(n))
            case ("PATCH", "notes", let id?, nil):
                guard var n = store.note(id) else { throw APIError(404, "Note introuvable") }
                try apply(body, to: &n)
                return .json(encode(store.upsertNote(n, touch: body["updated_at"] == nil)))
            case ("DELETE", "notes", let id?, nil):
                guard store.note(id) != nil else { throw APIError(404, "Note introuvable") }
                store.deleteNote(id)
                return .json(["deleted": id])

            // Artifacts
            case ("GET", "artifacts", nil, nil):
                var list = filterByCommon(store.artifacts, req.query, labels: \.labels, taskId: \.taskId,
                                          text: { $0.title + " " + $0.summary + " " + $0.url })
                if let k = req.query["kind"] { list = list.filter { $0.kind.rawValue == k } }
                return .json(list.map(encode))
            case ("POST", "artifacts", nil, nil):
                guard let title = body["title"] as? String, !title.isEmpty, let url = body["url"] as? String, !url.isEmpty else {
                    throw APIError(400, "title et url requis")
                }
                if let existing = store.artifacts.first(where: { $0.url == url }) {
                    var a = existing
                    try apply(body, to: &a)
                    return .json(encode(store.upsertArtifact(a)))
                }
                var a = ArtifactItem(title: title, url: url)
                try apply(body, to: &a)
                return .json(encode(store.upsertArtifact(a)), status: 201)
            case ("GET", "artifacts", let id?, nil):
                guard let a = store.artifact(id) else { throw APIError(404, "Artifact introuvable") }
                return .json(encode(a))
            case ("PATCH", "artifacts", let id?, nil):
                guard var a = store.artifact(id) else { throw APIError(404, "Artifact introuvable") }
                try apply(body, to: &a)
                return .json(encode(store.upsertArtifact(a)))
            case ("DELETE", "artifacts", let id?, nil):
                guard store.artifact(id) != nil else { throw APIError(404, "Artifact introuvable") }
                store.deleteArtifact(id)
                return .json(["deleted": id])

            case ("GET", "mindmaps", nil, nil):
                return .json(store.mindmaps.filter { m in
                    (req.query["label"].map { m.labels.contains($0) } ?? true)
                        && (req.query["q"].map { q in m.title.localizedCaseInsensitiveContains(q) || m.nodes.contains { $0.text.localizedCaseInsensitiveContains(q) } } ?? true)
                }.map(encodeMap))
            case ("POST", "mindmaps", nil, nil):
                guard let title = body["title"] as? String, !title.isEmpty else { throw APIError(400, "title requis") }
                var m = MindMap(title: title, labels: body["labels"] as? [String] ?? [])
                if let kids = body["children"] as? [[String: Any]], let root = m.root { m.addTree(kids, under: root.id) }
                return .json(encodeMap(store.upsertMindMap(m), full: true), status: 201)
            case ("GET", "mindmaps", let id?, nil):
                guard let m = store.mindmap(id) else { throw APIError(404, "Carte introuvable") }
                return .json(encodeMap(m, full: true))
            case ("PATCH", "mindmaps", let id?, nil):
                guard var m = store.mindmap(id) else { throw APIError(404, "Carte introuvable") }
                if let t = body["title"] as? String, !t.isEmpty, let r = m.root, let i = m.index(r.id) { m.title = t; m.nodes[i].text = t }
                if let l = body["labels"] as? [String] { m.labels = l }
                if let kids = body["children"] as? [[String: Any]], let root = m.root {
                    // full replacement of the tree
                    m.nodes.removeAll { $0.parentId != nil }
                    m.addTree(kids, under: root.id)
                }
                return .json(encodeMap(store.upsertMindMap(m), full: true))
            case ("POST", "mindmaps", let id?, "nodes"):
                guard var m = store.mindmap(id) else { throw APIError(404, "Carte introuvable") }
                let parent = (body["parent_id"] as? String).flatMap { m.node($0)?.id } ?? m.root!.id
                if let kids = body["children"] as? [[String: Any]], body["text"] == nil {
                    m.addTree(kids, under: parent)
                } else {
                    guard let text = body["text"] as? String, !text.isEmpty else { throw APIError(400, "text ou children requis") }
                    m.addTree([body], under: parent)
                    _ = text
                }
                return .json(encodeMap(store.upsertMindMap(m), full: true), status: 201)
            case ("DELETE", "mindmaps", let id?, nil):
                guard store.mindmap(id) != nil else { throw APIError(404, "Carte introuvable") }
                store.deleteMindMap(id)
                return .json(["deleted": id])

            case ("GET", "calendar", nil, nil):
                let cal = Calendar.app
                let day = cal.startOfDay(for: parseDate(req.query["date"]) ?? Date())
                guard Agenda.isAvailable else { throw APIError(503, "Aucun agenda : autorise le Calendrier Apple ou connecte Google dans Réglages") }
                let days = max(1, min(31, Int(req.query["days"] ?? "1") ?? 1))
                let events = try await Agenda.events(from: day, to: cal.date(byAdding: .day, value: days, to: day)!)
                return .json([
                    "date": Fmt.isoDay(day),
                    "events": events.map { e in
                        ["title": e.title, "start": Fmt.iso(e.start), "end": Fmt.iso(e.end), "all_day": e.allDay,
                         "location": n(e.location), "meet_url": n(e.meetURL), "busy": e.busy, "logged": store.isLogged(e)] as [String: Any]
                    },
                    "free_slots": store.freeSlots(events: events, on: day).map { ["start": Fmt.time($0.0), "end": Fmt.time($0.1)] },
                ])

            case ("POST", "calendar", "prepare", nil):
                let upcoming = store.todayEvents.filter { !$0.allDay }
                let target: CalendarEvent?
                if let t = body["title"] as? String { target = upcoming.first { $0.title.localizedCaseInsensitiveContains(t) } }
                else if let i = body["index"] as? Int, upcoming.indices.contains(i) { target = upcoming[i] }
                else { target = upcoming.first { $0.end > Date() } }
                guard let e = target else { throw APIError(404, "Aucune réunion correspondante aujourd'hui") }
                return .json(encode(try await store.prepareMeeting(e)), status: 201)
            case ("GET", "mails", nil, nil):
                var list = store.mails
                if let q = req.query["q"], !q.isEmpty {
                    list = list.filter { $0.subject.localizedCaseInsensitiveContains(q) || $0.from.localizedCaseInsensitiveContains(q) || $0.excerpt.localizedCaseInsensitiveContains(q) }
                }
                if req.query["unread"] == "1" { list = list.filter { !$0.read } }
                return .json(list.prefix(100).map { m in
                    ["subject": m.subject, "from": m.from, "date": Fmt.iso(m.date), "account": m.account, "read": m.read,
                     "excerpt": String(m.excerpt.prefix(400))] as [String: Any]
                })
            case ("POST", "mails", "sync", nil):
                await store.syncMails()
                return .json(["status": n(store.mailStatus), "count": store.mails.count])

            case ("POST", "assistant", "ask", nil):
                guard let msg = body["message"] as? String, !msg.isEmpty else { throw APIError(400, "message requis") }
                let chat = ChatModel(persistent: false)  // separate from the user's conversation
                chat.send(msg, store: store)
                while chat.generating { try await Task.sleep(nanoseconds: 200_000_000) }
                let last = chat.messages.last
                return .json(["reply": n(last?.content), "actions": last?.actions ?? [], "sources": last?.sources ?? [], "error": n(chat.error)])

            // Today
            case ("GET", "today", nil, nil):
                let sugg: [[String: Any]] = store.suggestions(limit: 15).map { sg in
                    var d = encode(sg.task)
                    d["score"] = sg.score
                    d["reasons"] = sg.reasons.map(\.text)
                    return d
                }
                var out: [String: Any] = ["suggestions": sugg]
                if let plan = DayPlan.load() { out["plan"] = encodePlan(plan) }
                return .json(out)
            case ("POST", "today", "plan", nil):
                return .json(encodePlan(try await store.generateDayPlan()), status: 201)

            // Clients & invoices
            case ("GET", "clients", nil, nil):
                return .json(store.clients.map(encode))
            case ("POST", "clients", nil, nil):
                guard let name = body["name"] as? String, !name.isEmpty else { throw APIError(400, "name requis") }
                var c = store.clients.first { $0.name.caseInsensitiveCompare(name) == .orderedSame } ?? Client(name: name)
                try apply(body, to: &c)
                return .json(encode(store.upsertClient(c)), status: 201)
            case ("PATCH", "clients", let id?, nil):
                guard var c = store.client(id) else { throw APIError(404, "Client introuvable") }
                try apply(body, to: &c)
                return .json(encode(store.upsertClient(c)))
            case ("GET", "invoices", nil, nil):
                var list = store.invoices
                if let s = req.query["status"] { list = list.filter { $0.status.rawValue == s } }
                if let c = req.query["client"] { list = list.filter { store.client($0.clientId)?.name.localizedCaseInsensitiveContains(c) == true } }
                return .json(list.map(encode))
            case ("POST", "invoices", "generate", nil):
                let cid = try resolveClient(body)
                guard let from = parseDate(body["from"]), let to = parseDate(body["to"], endOfDay: true) else { throw APIError(400, "from et to requis") }
                let grouping = InvoiceGrouping(rawValue: body["grouping"] as? String ?? "task") ?? .task
                let inv = store.upsertInvoice(try store.buildInvoice(clientId: cid, from: from, to: to, grouping: grouping))
                return .json(encode(inv), status: 201)
            case ("PATCH", "invoices", let id?, nil):
                guard var inv = store.invoice(id) else { throw APIError(404, "Facture introuvable") }
                if let s = body["status"] as? String { guard let st = InvoiceStatus(rawValue: s) else { throw APIError(400, "status : draft, sent, paid") }; inv.status = st }
                if let v = body["number"] as? String { inv.number = v }
                if let v = body["notes"] as? String { inv.notes = v }
                if let d = parseDate(body["issue_date"]) { inv.issueDate = d }
                if let d = parseDate(body["due_date"]) { inv.dueDate = d }
                if let lines = body["lines"] as? [[String: Any]] {
                    inv.lines = lines.map { InvoiceLine(description: $0["description"] as? String ?? "", quantity: $0["quantity"] as? Double ?? 1,
                                                        unit: $0["unit"] as? String ?? "h", unitPrice: $0["unit_price"] as? Double ?? 0) }
                }
                return .json(encode(store.upsertInvoice(inv)))
            case ("POST", "invoices", let id?, "pdf"):
                guard let inv = store.invoice(id) else { throw APIError(404, "Facture introuvable") }
                let url = try store.exportInvoicePDF(inv, to: (body["path"] as? String).map { URL(fileURLWithPath: $0) })
                return .json(["path": url.path])
            case ("DELETE", "invoices", let id?, nil):
                guard store.invoice(id) != nil else { throw APIError(404, "Facture introuvable") }
                store.deleteInvoice(id)
                return .json(["deleted": id])

            // Everything for a facet
            case ("GET", "overview", nil, nil):
                guard let label = req.query["label"], !label.isEmpty else { throw APIError(400, "label requis") }
                let has: ([String]) -> Bool = { $0.contains { $0.caseInsensitiveCompare(label) == .orderedSame } }
                let projs = store.projects.filter { p in has(p.labels) || store.tasks.contains { $0.projectId == p.id && has($0.labels) } }
                return .json([
                    "label": label,
                    "projects": projs.map(encode),
                    "tasks": store.tasks.filter { has($0.labels) }.map(encode),
                    "notes": store.notes.filter { has($0.labels) }.map(encode),
                    "artifacts": store.artifacts.filter { has($0.labels) }.map(encode),
                ])

            // Time entries
            case ("GET", "time-entries", nil, nil):
                var list = store.entries
                if let from = parseDate(req.query["from"]) { list = list.filter { $0.start >= from } }
                if let to = parseDate(req.query["to"], endOfDay: true) { list = list.filter { $0.start < to } }
                if let pid = req.query["project_id"] { list = list.filter { $0.projectId == pid } }
                if let tid = req.query["task_id"] { list = list.filter { $0.taskId == tid } }
                return .json(list.map(encode))
            case ("POST", "time-entries", nil, nil):
                guard let start = parseDate(body["start"]) else { throw APIError(400, "start requis (ISO 8601)") }
                var e = TimeEntry(start: start)
                try apply(body, to: &e)
                if e.end == nil {
                    guard let minutes = body["duration_minutes"] as? Double else {
                        throw APIError(400, "end ou duration_minutes requis (utilise /api/timer/start pour un chrono)")
                    }
                    e.end = start.addingTimeInterval(minutes * 60)
                }
                return .json(encode(store.upsertEntry(e)), status: 201)
            case ("PATCH", "time-entries", let id?, nil):
                guard var e = store.entries.first(where: { $0.id == id }) else { throw APIError(404, "Entrée introuvable") }
                try apply(body, to: &e)
                return .json(encode(store.upsertEntry(e)))
            case ("DELETE", "time-entries", let id?, nil):
                guard store.entries.contains(where: { $0.id == id }) else { throw APIError(404, "Entrée introuvable") }
                store.deleteEntry(id)
                return .json(["deleted": id])

            // Timer
            case ("GET", "timer", nil, nil):
                return .json(["running": n(store.runningEntry.map(encode))])
            case ("POST", "timer", "start", nil):
                let taskId = body["task_id"] as? String
                if let taskId, store.task(taskId) == nil { throw APIError(404, "Tâche introuvable") }
                let projectId = try resolveProject(body)
                let desc = (body["description"] as? String) ?? store.task(taskId)?.title ?? ""
                return .json(encode(store.startTimer(description: desc, projectId: projectId ?? nil, taskId: taskId)), status: 201)
            case ("POST", "timer", "stop", nil):
                return .json(["stopped": n(store.stopTimer().map(encode))])

            // Reports
            case ("GET", "reports", "summary", nil):
                return .json(summary(req.query))

            // Import
            case ("POST", "import", "clockify", nil):
                let from = parseDate(body["from"]) ?? Calendar.app.date(byAdding: .day, value: -30, to: Date())!
                let to = parseDate(body["to"], endOfDay: true) ?? Date()
                let result = try await ClockifyImporter.run(store: store, from: from, to: to)
                return .json(["imported": result.description])

            case ("POST", "gitlab", "refresh", nil):
                await store.refreshMergeRequests()
                return .json(["tasks_with_mr": store.mergeRequests.filter { !$0.value.isEmpty }.count])
            case ("POST", "import", "jira", nil):
                return .json(["imported": try await Jira.importIssues(store: store, jql: body["jql"] as? String)])

            default:
                return .error(404, "Route inconnue : \(req.method) \(req.path). Voir GET /api/health")
            }
        } catch let e as APIError {
            return .error(e.status, e.message)
        } catch {
            return .error(500, "\(error)")
        }
    }

    private func authorized(_ req: HTTPRequest) -> Bool {
        let token = Config.apiToken
        if let auth = req.headers["authorization"], auth == "Bearer \(token)" { return true }
        if let key = req.headers["x-api-key"], key == token { return true }
        return false
    }

    // MARK: - Tasks helpers

    private func listTasks(_ q: [String: String]) throws -> [TaskItem] {
        var list = store.tasks
        if let s = q["status"] {
            let statuses = try s.split(separator: ",").map { raw -> TaskStatus in
                guard let st = TaskStatus.parse(String(raw)) else { throw APIError(400, "status inconnu : \(raw)") }
                return st
            }
            list = list.filter { statuses.contains($0.status) }
        }
        if let c = q["context"], let ctx = WorkContext(rawValue: c.lowercased()) { list = list.filter { $0.context == ctx } }
        if let pid = q["project_id"] { list = list.filter { $0.projectId == pid } }
        if let name = q["project"] {
            guard let proj = store.projectNamed(name) else { throw APIError(404, "Projet introuvable : \(name)") }
            list = list.filter { $0.projectId == proj.id }
        }
        if let label = q["label"], !label.isEmpty {
            let wanted = Set(label.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
            list = list.filter { t in t.labels.contains { wanted.contains($0.lowercased()) } }
        }
        if let search = q["q"], !search.isEmpty {
            list = list.filter {
                $0.title.localizedCaseInsensitiveContains(search) || $0.notes.localizedCaseInsensitiveContains(search)
                    || ($0.jiraKey ?? "").localizedCaseInsensitiveContains(search)
            }
        }
        return list.sorted { ($0.status.sortIndex, -$0.priority, $0.position) < ($1.status.sortIndex, -$1.priority, $1.position) }
    }

    private func createTask(_ body: [String: Any]) throws -> TaskItem {
        guard let title = body["title"] as? String, !title.isEmpty else { throw APIError(400, "title requis") }
        var t = TaskItem(title: title)
        try apply(body, to: &t, isNew: true)
        if t.jiraKey == nil, let key = Jira.detectKey(in: title) { t.jiraKey = key }
        if let key = t.jiraKey, t.url == nil { t.url = Jira.browseURL(key)?.absoluteString }
        return store.upsertTask(t)
    }

    /// Returns `.some(nil)` when the body explicitly clears the project, `nil` when absent.
    private func resolveProject(_ body: [String: Any]) throws -> String?? {
        if let name = body["project"] as? String {
            guard let p = store.projectNamed(name) else {
                let names = store.projects.map(\.name).joined(separator: ", ")
                throw APIError(404, "Projet introuvable : \(name). Projets existants : \(names)")
            }
            return .some(p.id)
        }
        if body.keys.contains("project_id") {
            guard let pid = body["project_id"] as? String else { return .some(nil) }
            guard store.project(pid) != nil else { throw APIError(404, "project_id introuvable") }
            return .some(pid)
        }
        return nil
    }

    private func apply(_ b: [String: Any], to t: inout TaskItem, isNew: Bool) throws {
        if let v = b["title"] as? String { t.title = v }
        if let v = b["notes"] as? String { t.notes = v }
        var contextSet = false
        if let pid = try resolveProject(b) { t.projectId = pid }
        if let s = b["status"] as? String {
            guard let st = TaskStatus.parse(s) else { throw APIError(400, "status inconnu : \(s)") }
            t.status = st
        }
        if let s = b["context"] as? String {
            guard let c = WorkContext(rawValue: s.lowercased()) else { throw APIError(400, "context doit être pro ou perso") }
            t.context = c
            contextSet = true
        }
        if isNew, !contextSet, let p = store.project(t.projectId) { t.context = p.context }
        if let v = b["priority"] as? Int { t.priority = min(3, max(0, v)) }
        if let v = b["labels"] as? [String] {
            let known = store.allLabels.map(\.name)
            var out: [String] = []
            for raw in v {
                let name = raw.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { continue }
                let canonical = known.first { $0.caseInsensitiveCompare(name) == .orderedSame } ?? name
                if !out.contains(canonical) { out.append(canonical) }
            }
            t.labels = out
        }
        if b.keys.contains("jira_key") { t.jiraKey = (b["jira_key"] as? String).flatMap { $0.isEmpty ? nil : $0.uppercased() } }
        if b.keys.contains("url") { t.url = (b["url"] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        if b.keys.contains("due_date") { t.dueDate = parseDate(b["due_date"]) }
        if b.keys.contains("estimate_minutes") { t.estimateMinutes = b["estimate_minutes"] as? Int }
        if let d = parseDate(b["completed_at"]) { t.completedAt = d }
    }

    private func canonicalLabels(_ v: [String]) -> [String] {
        let known = store.allLabels.map(\.name)
        var out: [String] = []
        for raw in v {
            let name = raw.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            let c = known.first { $0.caseInsensitiveCompare(name) == .orderedSame } ?? name
            if !out.contains(c) { out.append(c) }
        }
        return out
    }

    /// task_id, or jira_key resolved to the linked task.
    private func resolveTask(_ b: [String: Any]) throws -> String?? {
        if let key = b["jira_key"] as? String {
            guard let t = store.tasks.first(where: { $0.jiraKey?.caseInsensitiveCompare(key) == .orderedSame }) else {
                throw APIError(404, "Aucune tâche liée à \(key)")
            }
            return .some(t.id)
        }
        if b.keys.contains("task_id") {
            guard let id = b["task_id"] as? String else { return .some(nil) }
            guard store.task(id) != nil else { throw APIError(404, "task_id introuvable") }
            return .some(id)
        }
        return nil
    }

    private func filterByCommon<T>(_ items: [T], _ q: [String: String], labels: KeyPath<T, [String]>,
                                   taskId: KeyPath<T, String?>, text: (T) -> String) -> [T] {
        var list = items
        if let label = q["label"], !label.isEmpty {
            let wanted = Set(label.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
            list = list.filter { $0[keyPath: labels].contains { wanted.contains($0.lowercased()) } }
        }
        if let tid = q["task_id"] { list = list.filter { $0[keyPath: taskId] == tid } }
        if let search = q["q"], !search.isEmpty { list = list.filter { text($0).localizedCaseInsensitiveContains(search) } }
        return list
    }

    private func apply(_ b: [String: Any], to n: inout Note) throws {
        if let v = b["title"] as? String, !v.isEmpty { n.title = v }
        if let v = b["body"] as? String { n.body = v }
        if let v = b["append"] as? String { n.body = n.body.isEmpty ? v : n.body + "\n\n" + v }
        if let v = b["labels"] as? [String] { n.labels = canonicalLabels(v) }
        if let v = b["pinned"] as? Bool { n.pinned = v }
        if let v = b["external_id"] as? String { n.externalId = v }
        if let d = parseDate(b["updated_at"]) { n.updatedAt = d }
        if let d = parseDate(b["created_at"]) { n.createdAt = d }
        if let tid = try resolveTask(b) { n.taskId = tid }
    }

    private func apply(_ b: [String: Any], to a: inout ArtifactItem) throws {
        if let v = b["title"] as? String, !v.isEmpty { a.title = v }
        if let v = b["url"] as? String, !v.isEmpty { a.url = v }
        if let v = b["kind"] as? String {
            guard let k = ArtifactKind(rawValue: v.lowercased()) else { throw APIError(400, "kind inconnu : \(v)") }
            a.kind = k
        }
        if let v = b["summary"] as? String { a.summary = v }
        if let v = b["labels"] as? [String] { a.labels = canonicalLabels(v) }
        if let tid = try resolveTask(b) { a.taskId = tid }
    }

    private func encodeMap(_ m: MindMap) -> [String: Any] { encodeMap(m, full: false) }

    private func encodeMap(_ m: MindMap, full: Bool) -> [String: Any] {
        var out: [String: Any] = ["id": m.id, "title": m.title, "labels": m.labels, "nodes": m.nodes.count - 1,
                                  "created_at": Fmt.iso(m.createdAt), "updated_at": Fmt.iso(m.updatedAt)]
        if full { out["tree"] = m.tree(); out["markdown"] = m.markdown(store: store) }
        return out
    }

    private func encodePlan(_ p: DayPlan) -> [String: Any] {
        ["date": p.date, "model": p.model, "summary": p.summary, "advice": p.advice, "facets": p.facets,
         "followups": p.followups ?? [],
         "items": p.items.map { i in
             ["task_id": i.taskId, "task": n(store.task(i.taskId)?.title), "jira_key": n(store.task(i.taskId)?.jiraKey),
              "minutes": i.minutes, "why": i.why, "start": n(i.start), "steps": i.steps ?? []] as [String: Any]
         }]
    }

    private func resolveClient(_ b: [String: Any]) throws -> String {
        if let id = b["client_id"] as? String, store.client(id) != nil { return id }
        if let name = b["client"] as? String, let c = store.clients.first(where: { $0.name.localizedCaseInsensitiveContains(name) }) { return c.id }
        throw APIError(404, "Client introuvable. Clients : \(store.clients.map(\.name).joined(separator: ", "))")
    }

    private func apply(_ b: [String: Any], to c: inout Client) throws {
        if let v = b["name"] as? String, !v.isEmpty { c.name = v }
        if let v = b["address"] as? String { c.address = v }
        if let v = b["email"] as? String { c.email = v }
        if let v = b["vat_number"] as? String { c.vatNumber = v }
        if let v = b["siret"] as? String { c.siret = v }
        if let v = b["rate"] as? Double { c.rate = v }
        if let v = b["currency"] as? String { c.currency = v.uppercased() }
        if let v = b["vat_mode"] as? String {
            guard let m = VatMode(rawValue: v) else { throw APIError(400, "vat_mode : standard, outsideEU, reverseChargeEU, franchise") }
            c.vatMode = m
        }
        if let names = b["projects"] as? [String] {
            for name in names {
                guard var p = store.projectNamed(name) else { throw APIError(404, "Projet introuvable : \(name)") }
                p.clientId = c.id
                store.upsertProject(p)
            }
        }
    }

    private func encode(_ c: Client) -> [String: Any] {
        ["id": c.id, "name": c.name, "address": c.address, "email": c.email, "vat_number": c.vatNumber, "siret": c.siret,
         "rate": c.rate, "currency": c.currency, "vat_mode": c.vatMode.rawValue,
         "projects": store.projects(of: c.id).map(\.name)]
    }

    private func encode(_ i: Invoice) -> [String: Any] {
        ["id": i.id, "number": i.number, "client": n(store.client(i.clientId)?.name), "client_id": i.clientId,
         "status": i.status.rawValue, "issue_date": Fmt.isoDay(i.issueDate), "due_date": Fmt.isoDay(i.dueDate),
         "period": [n(i.periodStart.map(Fmt.isoDay)), n(i.periodEnd.map(Fmt.isoDay))], "currency": i.currency,
         "vat_mode": i.vatMode.rawValue, "subtotal": i.subtotal, "vat": i.vat, "total": i.total, "hours": i.hours,
         "lines": i.lines.map { ["description": $0.description, "quantity": $0.quantity, "unit": $0.unit, "unit_price": $0.unitPrice, "total": $0.total] as [String: Any] },
         "entries": i.entryIds.count]
    }

    private func encode(_ x: Note) -> [String: Any] {
        ["id": x.id, "title": x.title, "body": x.body, "labels": x.labels, "task_id": n(x.taskId),
         "task": n(store.task(x.taskId)?.title), "jira_key": n(store.task(x.taskId)?.jiraKey), "pinned": x.pinned,
         "created_at": Fmt.iso(x.createdAt), "updated_at": Fmt.iso(x.updatedAt), "external_id": n(x.externalId)]
    }

    private func encode(_ a: ArtifactItem) -> [String: Any] {
        ["id": a.id, "title": a.title, "url": a.url, "kind": a.kind.rawValue, "summary": a.summary, "labels": a.labels,
         "task_id": n(a.taskId), "task": n(store.task(a.taskId)?.title), "jira_key": n(store.task(a.taskId)?.jiraKey),
         "created_at": Fmt.iso(a.createdAt)]
    }

    private func apply(_ b: [String: Any], to p: inout Project) throws {
        if let v = b["labels"] as? [String] { p.labels = canonicalLabels(v) }
        if let v = b["name"] as? String, !v.isEmpty { p.name = v }
        if let v = b["color"] as? String { p.color = v }
        if b.keys.contains("client") { p.client = b["client"] as? String }
        if let s = b["context"] as? String {
            guard let c = WorkContext(rawValue: s.lowercased()) else { throw APIError(400, "context doit être pro ou perso") }
            p.context = c
        }
        if let v = b["archived"] as? Bool { p.archived = v }
    }

    private func apply(_ b: [String: Any], to e: inout TimeEntry) throws {
        if let v = b["description"] as? String { e.description = v }
        if let pid = try resolveProject(b) { e.projectId = pid }
        if b.keys.contains("task_id") {
            let tid = b["task_id"] as? String
            if let tid {
                guard let t = store.task(tid) else { throw APIError(404, "task_id introuvable") }
                if e.projectId == nil { e.projectId = t.projectId }
            }
            e.taskId = tid
        }
        if b.keys.contains("start") {
            guard let d = parseDate(b["start"]) else { throw APIError(400, "start invalide") }
            e.start = d
        }
        if b.keys.contains("end") { e.end = parseDate(b["end"]) }
        if let m = b["duration_minutes"] as? Double, b["end"] == nil { e.end = e.start.addingTimeInterval(m * 60) }
        if let tags = b["tags"] as? [String] { e.tags = tags }
        if let v = b["billable"] as? Bool { e.billable = v }
        if let end = e.end, end < e.start { throw APIError(400, "end doit être après start") }
    }

    // MARK: - Reports

    private func summary(_ q: [String: String]) -> [String: Any] {
        let cal = Calendar.app
        let from = parseDate(q["from"]) ?? cal.dateInterval(of: .weekOfYear, for: Date())!.start
        let to = parseDate(q["to"], endOfDay: true) ?? cal.date(byAdding: .day, value: 7, to: from)!
        var list = store.entries(from: from, to: to)
        if let c = q["context"], let ctx = WorkContext(rawValue: c) { list = list.filter { store.context(of: $0) == ctx } }

        var byProject: [String: [TimeEntry]] = [:]
        for e in list { byProject[e.projectId ?? "", default: []].append(e) }
        let projects: [[String: Any]] = byProject.map { pid, items in
            var byTask: [String: (String, TimeInterval)] = [:]
            for e in items {
                let key = e.taskId ?? "desc:" + e.description
                let label = store.task(e.taskId)?.title ?? (e.description.isEmpty ? "(sans description)" : e.description)
                byTask[key, default: (label, 0)].1 += e.duration
            }
            return [
                "project_id": pid.isEmpty ? NSNull() : pid,
                "project": store.project(pid)?.name ?? "Sans projet",
                "seconds": Int(items.reduce(0) { $0 + $1.duration }),
                "items": byTask.sorted { $0.value.1 > $1.value.1 }.map { key, v in
                    ["key": key, "label": v.0, "seconds": Int(v.1), "duration": Fmt.hms(v.1)] as [String: Any]
                },
            ]
        }.sorted { ($0["seconds"] as! Int) > ($1["seconds"] as! Int) }

        var byDay: [Date: TimeInterval] = [:]
        for e in list { byDay[cal.startOfDay(for: e.start), default: 0] += e.duration }
        let total = list.reduce(0) { $0 + $1.duration }
        return [
            "from": Fmt.iso(from), "to": Fmt.iso(to),
            "total_seconds": Int(total), "total": Fmt.hms(total),
            "entries": list.count,
            "by_project": projects,
            "by_day": byDay.sorted { $0.key < $1.key }.map { ["date": Fmt.isoDay($0.key), "seconds": Int($0.value), "duration": Fmt.hms($0.value)] },
        ]
    }

    // MARK: - Encoding

    private func n(_ v: Any?) -> Any { v ?? NSNull() }

    private func encode(_ p: Project) -> [String: Any] {
        ["id": p.id, "name": p.name, "color": p.color, "client": n(p.client), "context": p.context.rawValue,
         "archived": p.archived, "clockify_id": n(p.clockifyId), "labels": p.labels]
    }

    private func encode(_ t: TaskItem) -> [String: Any] {
        ["id": t.id, "title": t.title, "notes": t.notes, "project_id": n(t.projectId),
         "project": n(store.project(t.projectId)?.name), "status": t.status.rawValue, "context": t.context.rawValue,
         "priority": t.priority, "labels": t.labels, "jira_key": n(t.jiraKey), "url": n(t.url), "due_date": n(t.dueDate.map(Fmt.iso)),
         "estimate_minutes": n(t.estimateMinutes), "created_at": Fmt.iso(t.createdAt), "updated_at": Fmt.iso(t.updatedAt),
         "completed_at": n(t.completedAt.map(Fmt.iso)), "tracked_seconds": Int(store.trackedTime(task: t.id)),
         "tracked": Fmt.hms(store.trackedTime(task: t.id)),
         "merge_requests": (store.mergeRequests[t.id] ?? []).map { mr in
             ["reference": mr.reference, "title": mr.title, "state": mr.state, "draft": mr.draft, "url": mr.webURL,
              "source_branch": mr.sourceBranch, "target_branch": mr.targetBranch,
              "pipeline": n(mr.pipeline), "merge_status": n(mr.mergeStatus)] as [String: Any]
         }]
    }

    private func encode(_ e: TimeEntry) -> [String: Any] {
        ["id": e.id, "description": e.description, "project_id": n(e.projectId), "project": n(store.project(e.projectId)?.name),
         "task_id": n(e.taskId), "task": n(store.task(e.taskId)?.title), "start": Fmt.iso(e.start), "end": n(e.end.map(Fmt.iso)),
         "running": e.isRunning, "duration_seconds": Int(e.duration), "duration": Fmt.hms(e.duration), "tags": e.tags,
         "billable": e.billable, "clockify_id": n(e.clockifyId)]
    }
}

extension TaskStatus {
    var sortIndex: Int { TaskStatus.allCases.firstIndex(of: self)! }
}

/// Accepts ISO 8601 (with/without offset or fractional seconds), "yyyy-MM-dd HH:mm", "yyyy-MM-dd" (local time) or epoch seconds.
func parseDate(_ value: Any?, endOfDay: Bool = false) -> Date? {
    if let n = value as? Double { return Date(timeIntervalSince1970: n) }
    guard let s = (value as? String)?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
    let iso = ISO8601DateFormatter()
    if let d = iso.date(from: s) { return d }
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = iso.date(from: s) { return d }
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = .current
    for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm"] {
        f.dateFormat = format
        if let d = f.date(from: s) { return d }
    }
    f.dateFormat = "yyyy-MM-dd"
    if let d = f.date(from: s) {
        return endOfDay ? Calendar.app.date(byAdding: .day, value: 1, to: d) : d
    }
    return nil
}

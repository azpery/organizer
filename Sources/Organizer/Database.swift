import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct DBError: Error, CustomStringConvertible { let description: String }

struct Row {
    let values: [String: Any]
    func string(_ k: String) -> String? { values[k] as? String }
    func double(_ k: String) -> Double? {
        if let d = values[k] as? Double { return d }
        if let i = values[k] as? Int64 { return Double(i) }
        return nil
    }
    func int(_ k: String) -> Int? {
        if let i = values[k] as? Int64 { return Int(i) }
        if let d = values[k] as? Double { return Int(d) }
        return nil
    }
    func bool(_ k: String) -> Bool { (int(k) ?? 0) != 0 }
    func date(_ k: String) -> Date? { double(k).map { Date(timeIntervalSince1970: $0) } }
}

final class Database {
    private var db: OpaquePointer?

    init(path: String) throws {
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            throw DBError(description: "Impossible d'ouvrir la base \(path)")
        }
        try exec("PRAGMA journal_mode=WAL;")
        try migrate()
    }

    deinit { sqlite3_close(db) }

    private var lastError: String { String(cString: sqlite3_errmsg(db)) }

    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? lastError
            sqlite3_free(err)
            throw DBError(description: msg)
        }
    }

    private func prepare(_ sql: String, _ params: [Any?]) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            throw DBError(description: lastError)
        }
        for (i, param) in params.enumerated() {
            let idx = Int32(i + 1)
            guard let p = param else { sqlite3_bind_null(s, idx); continue }
            switch p {
            case let v as Bool: sqlite3_bind_int64(s, idx, v ? 1 : 0)
            case let v as Int: sqlite3_bind_int64(s, idx, Int64(v))
            case let v as Double: sqlite3_bind_double(s, idx, v)
            case let v as Date: sqlite3_bind_double(s, idx, v.timeIntervalSince1970)
            case let v as String: sqlite3_bind_text(s, idx, v, -1, SQLITE_TRANSIENT)
            default: sqlite3_bind_null(s, idx)
            }
        }
        return s
    }

    func run(_ sql: String, _ params: [Any?] = []) throws {
        let s = try prepare(sql, params)
        defer { sqlite3_finalize(s) }
        let rc = sqlite3_step(s)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw DBError(description: lastError) }
    }

    func query(_ sql: String, _ params: [Any?] = []) throws -> [Row] {
        let s = try prepare(sql, params)
        defer { sqlite3_finalize(s) }
        var rows: [Row] = []
        while sqlite3_step(s) == SQLITE_ROW {
            var values: [String: Any] = [:]
            for i in 0..<sqlite3_column_count(s) {
                let name = String(cString: sqlite3_column_name(s, i))
                switch sqlite3_column_type(s, i) {
                case SQLITE_INTEGER: values[name] = sqlite3_column_int64(s, i)
                case SQLITE_FLOAT: values[name] = sqlite3_column_double(s, i)
                case SQLITE_TEXT: values[name] = String(cString: sqlite3_column_text(s, i))
                default: break
                }
            }
            rows.append(Row(values: values))
        }
        return rows
    }

    func transaction(_ body: () throws -> Void) throws {
        try exec("BEGIN")
        do {
            try body()
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    private func migrate() throws {
        let version = try query("PRAGMA user_version").first?.int("user_version") ?? 0
        if version < 1 {
            try exec("""
            CREATE TABLE IF NOT EXISTS projects (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                color TEXT NOT NULL,
                client TEXT,
                context TEXT NOT NULL DEFAULT 'pro',
                archived INTEGER NOT NULL DEFAULT 0,
                clockify_id TEXT UNIQUE
            );
            CREATE TABLE IF NOT EXISTS tasks (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                notes TEXT NOT NULL DEFAULT '',
                project_id TEXT,
                status TEXT NOT NULL,
                context TEXT NOT NULL DEFAULT 'pro',
                priority INTEGER NOT NULL DEFAULT 0,
                position REAL NOT NULL DEFAULT 0,
                jira_key TEXT,
                url TEXT,
                due_date REAL,
                estimate_minutes INTEGER,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                completed_at REAL,
                clockify_id TEXT UNIQUE
            );
            CREATE TABLE IF NOT EXISTS time_entries (
                id TEXT PRIMARY KEY,
                description TEXT NOT NULL DEFAULT '',
                project_id TEXT,
                task_id TEXT,
                start_at REAL NOT NULL,
                end_at REAL,
                tags TEXT NOT NULL DEFAULT '[]',
                billable INTEGER NOT NULL DEFAULT 0,
                clockify_id TEXT UNIQUE
            );
            CREATE INDEX IF NOT EXISTS idx_entries_start ON time_entries(start_at);
            CREATE INDEX IF NOT EXISTS idx_entries_task ON time_entries(task_id);
            PRAGMA user_version = 1;
            """)
        }
        if version < 2 {
            try exec("""
            ALTER TABLE tasks ADD COLUMN labels TEXT NOT NULL DEFAULT '[]';
            PRAGMA user_version = 2;
            """)
        }
        if version < 3 {
            try exec("""
            ALTER TABLE projects ADD COLUMN labels TEXT NOT NULL DEFAULT '[]';
            CREATE TABLE IF NOT EXISTS notes (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                body TEXT NOT NULL DEFAULT '',
                labels TEXT NOT NULL DEFAULT '[]',
                task_id TEXT,
                pinned INTEGER NOT NULL DEFAULT 0,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS artifacts (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                url TEXT NOT NULL,
                kind TEXT NOT NULL DEFAULT 'artifact',
                summary TEXT NOT NULL DEFAULT '',
                labels TEXT NOT NULL DEFAULT '[]',
                task_id TEXT,
                created_at REAL NOT NULL
            );
            PRAGMA user_version = 3;
            """)
        }
        if version < 4 {
            try exec("""
            ALTER TABLE notes ADD COLUMN external_id TEXT;
            PRAGMA user_version = 4;
            """)
        }
        if version < 5 {
            try exec("""
            CREATE TABLE IF NOT EXISTS mails (
                id TEXT PRIMARY KEY,
                account TEXT NOT NULL DEFAULT '',
                subject TEXT NOT NULL DEFAULT '',
                sender TEXT NOT NULL DEFAULT '',
                date REAL NOT NULL,
                excerpt TEXT NOT NULL DEFAULT '',
                read INTEGER NOT NULL DEFAULT 1
            );
            CREATE INDEX IF NOT EXISTS idx_mails_date ON mails(date);
            PRAGMA user_version = 5;
            """)
        }
        if version < 6 {
            try exec("""
            CREATE TABLE IF NOT EXISTS clients (id TEXT PRIMARY KEY, data TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS invoices (id TEXT PRIMARY KEY, number TEXT NOT NULL, data TEXT NOT NULL);
            ALTER TABLE projects ADD COLUMN client_id TEXT;
            ALTER TABLE time_entries ADD COLUMN invoice_id TEXT;
            PRAGMA user_version = 6;
            """)
        }
        if version < 7 {
            try exec("""
            CREATE TABLE IF NOT EXISTS mindmaps (id TEXT PRIMARY KEY, data TEXT NOT NULL);
            PRAGMA user_version = 7;
            """)
        }
    }
}

// MARK: - Model persistence

extension Database {
    func loadProjects() throws -> [Project] {
        try query("SELECT * FROM projects ORDER BY name COLLATE NOCASE").map { r in
            Project(
                id: r.string("id")!, name: r.string("name") ?? "", color: r.string("color") ?? "#7A8CA3",
                client: r.string("client"), context: WorkContext(rawValue: r.string("context") ?? "") ?? .pro,
                archived: r.bool("archived"), clockifyId: r.string("clockify_id"),
                labels: Self.decodeList(r.string("labels")), clientId: r.string("client_id"))
        }
    }

    func save(_ p: Project) throws {
        try run("""
        INSERT OR REPLACE INTO projects (id, name, color, client, context, archived, clockify_id, labels, client_id)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, [p.id, p.name, p.color, p.client, p.context.rawValue, p.archived, p.clockifyId, Self.encodeList(p.labels), p.clientId])
    }

    func loadNotes() throws -> [Note] {
        try query("SELECT * FROM notes ORDER BY pinned DESC, updated_at DESC").map { r in
            Note(id: r.string("id")!, title: r.string("title") ?? "", body: r.string("body") ?? "",
                 labels: Self.decodeList(r.string("labels")), taskId: r.string("task_id"), pinned: r.bool("pinned"),
                 createdAt: r.date("created_at") ?? Date(), updatedAt: r.date("updated_at") ?? Date(),
                 externalId: r.string("external_id"))
        }
    }

    func save(_ n: Note) throws {
        try run("""
        INSERT OR REPLACE INTO notes (id, title, body, labels, task_id, pinned, created_at, updated_at, external_id)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, [n.id, n.title, n.body, Self.encodeList(n.labels), n.taskId, n.pinned, n.createdAt, n.updatedAt, n.externalId])
    }

    func loadArtifacts() throws -> [ArtifactItem] {
        try query("SELECT * FROM artifacts ORDER BY created_at DESC").map { r in
            ArtifactItem(id: r.string("id")!, title: r.string("title") ?? "", url: r.string("url") ?? "",
                         kind: ArtifactKind(rawValue: r.string("kind") ?? "") ?? .link, summary: r.string("summary") ?? "",
                         labels: Self.decodeList(r.string("labels")), taskId: r.string("task_id"),
                         createdAt: r.date("created_at") ?? Date())
        }
    }

    func save(_ a: ArtifactItem) throws {
        try run("""
        INSERT OR REPLACE INTO artifacts (id, title, url, kind, summary, labels, task_id, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """, [a.id, a.title, a.url, a.kind.rawValue, a.summary, Self.encodeList(a.labels), a.taskId, a.createdAt])
    }

    func loadTasks() throws -> [TaskItem] {
        try query("SELECT * FROM tasks").map { r in
            TaskItem(
                id: r.string("id")!, title: r.string("title") ?? "", notes: r.string("notes") ?? "",
                projectId: r.string("project_id"),
                status: TaskStatus(rawValue: r.string("status") ?? "") ?? .backlog,
                context: WorkContext(rawValue: r.string("context") ?? "") ?? .pro,
                priority: r.int("priority") ?? 0, labels: Self.decodeList(r.string("labels")), position: r.double("position") ?? 0,
                jiraKey: r.string("jira_key"), url: r.string("url"), dueDate: r.date("due_date"),
                estimateMinutes: r.int("estimate_minutes"),
                createdAt: r.date("created_at") ?? Date(), updatedAt: r.date("updated_at") ?? Date(),
                completedAt: r.date("completed_at"), clockifyId: r.string("clockify_id"))
        }
    }

    func save(_ t: TaskItem) throws {
        try run("""
        INSERT OR REPLACE INTO tasks (id, title, notes, project_id, status, context, priority, labels, position,
            jira_key, url, due_date, estimate_minutes, created_at, updated_at, completed_at, clockify_id)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, [t.id, t.title, t.notes, t.projectId, t.status.rawValue, t.context.rawValue, t.priority, Self.encodeList(t.labels), t.position,
              t.jiraKey, t.url, t.dueDate, t.estimateMinutes, t.createdAt, t.updatedAt, t.completedAt, t.clockifyId])
    }

    func loadEntries() throws -> [TimeEntry] {
        try query("SELECT * FROM time_entries ORDER BY start_at DESC").map { r in
            let tags = Self.decodeList(r.string("tags"))
            return TimeEntry(
                id: r.string("id")!, description: r.string("description") ?? "",
                projectId: r.string("project_id"), taskId: r.string("task_id"),
                start: r.date("start_at") ?? Date(), end: r.date("end_at"), tags: tags,
                billable: r.bool("billable"), clockifyId: r.string("clockify_id"), invoiceId: r.string("invoice_id"))
        }
    }

    func save(_ e: TimeEntry) throws {
        let tags = Self.encodeList(e.tags)
        try run("""
        INSERT OR REPLACE INTO time_entries (id, description, project_id, task_id, start_at, end_at, tags, billable, clockify_id, invoice_id)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, [e.id, e.description, e.projectId, e.taskId, e.start, e.end, tags, e.billable, e.clockifyId, e.invoiceId])
    }

    func loadMails() throws -> [MailSnippet] {
        try query("SELECT * FROM mails ORDER BY date DESC").map { r in
            MailSnippet(id: r.string("id")!, subject: r.string("subject") ?? "", from: r.string("sender") ?? "",
                        date: r.date("date") ?? Date(), excerpt: r.string("excerpt") ?? "",
                        account: r.string("account") ?? "", read: r.bool("read"))
        }
    }

    func save(_ m: MailSnippet) throws {
        try run("""
        INSERT OR REPLACE INTO mails (id, account, subject, sender, date, excerpt, read) VALUES (?, ?, ?, ?, ?, ?, ?)
        """, [m.id, m.account, m.subject, m.from, m.date, m.excerpt, m.read])
    }

    func loadJSON<T: Decodable>(_ table: String, as: T.Type) throws -> [T] {
        try query("SELECT data FROM \(table)").compactMap { r in
            r.string("data")?.data(using: .utf8).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
        }
    }

    func saveJSON<T: Encodable & Identifiable>(_ table: String, _ item: T, extra: [String: Any?] = [:]) throws where T.ID == String {
        let json = String(data: try JSONEncoder().encode(item), encoding: .utf8) ?? "{}"
        let cols = ["id", "data"] + extra.keys.sorted()
        let vals: [Any?] = [item.id, json] + extra.keys.sorted().map { extra[$0]! }
        try run("INSERT OR REPLACE INTO \(table) (\(cols.joined(separator: ", "))) VALUES (\(cols.map { _ in "?" }.joined(separator: ", ")))", vals)
    }

    static func decodeList(_ s: String?) -> [String] {
        (s?.data(using: .utf8)).flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
    }

    static func encodeList(_ list: [String]) -> String {
        String(data: (try? JSONEncoder().encode(list)) ?? Data("[]".utf8), encoding: .utf8) ?? "[]"
    }

    func delete(table: String, id: String) throws {
        try run("DELETE FROM \(table) WHERE id = ?", [id])
    }
}

import Foundation

/// Full Jira issue, for the task detail page.
struct JiraIssueDetail {
    struct Comment: Identifiable { let id: String; let author: String; let date: Date?; let markdown: String }
    struct Linked: Identifiable { let id: String; let key: String; let summary: String; let status: String; let relation: String }
    struct Attachment: Identifiable { let id: String; let filename: String; let url: String }

    let key: String
    let summary: String
    let type: String
    let status: String
    let statusCategory: String
    let priority: String?
    let assignee: String?
    let reporter: String?
    let created: Date?
    let updated: Date?
    let due: Date?
    let labels: [String]
    let descriptionMarkdown: String
    let comments: [Comment]
    let links: [Linked]
    let attachments: [Attachment]
    let parent: Linked?
}

extension Jira {
    private static let jiraDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        return f
    }()

    static func issueDetail(key: String) async throws -> JiraIssueDetail {
        guard isConfigured else { throw APIError(400, "Jira non configuré") }
        var comps = URLComponents(string: "\(baseURL)/rest/api/3/issue/\(key)")!
        comps.queryItems = [URLQueryItem(name: "fields", value:
            "summary,description,status,assignee,reporter,priority,created,updated,duedate,labels,comment,issuelinks,subtasks,attachment,issuetype,parent")]
        var req = URLRequest(url: comps.url!)
        req.setValue("Basic \(Data("\(email):\(token)".utf8).base64EncodedString())", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let f = json["fields"] as? [String: Any] else {
            throw APIError(502, "Jira : impossible de charger \(key)")
        }
        func name(_ v: Any?) -> String? { (v as? [String: Any])?["displayName"] as? String ?? (v as? [String: Any])?["name"] as? String }
        func date(_ v: Any?) -> Date? { (v as? String).flatMap { jiraDate.date(from: $0) ?? parseDate($0) } }
        let status = f["status"] as? [String: Any] ?? [:]

        let comments = ((f["comment"] as? [String: Any])?["comments"] as? [[String: Any]] ?? []).map {
            JiraIssueDetail.Comment(id: $0["id"] as? String ?? UUID().uuidString, author: name($0["author"]) ?? "?",
                                    date: date($0["created"]), markdown: ADF.markdown($0["body"]))
        }
        var links: [JiraIssueDetail.Linked] = []
        for l in f["issuelinks"] as? [[String: Any]] ?? [] {
            let type = l["type"] as? [String: Any] ?? [:]
            for (side, rel) in [("outwardIssue", type["outward"]), ("inwardIssue", type["inward"])] {
                guard let i = l[side] as? [String: Any] else { continue }
                let fi = i["fields"] as? [String: Any] ?? [:]
                links.append(.init(id: (i["key"] as? String ?? "") + side, key: i["key"] as? String ?? "",
                                   summary: fi["summary"] as? String ?? "",
                                   status: (fi["status"] as? [String: Any])?["name"] as? String ?? "",
                                   relation: rel as? String ?? ""))
            }
        }
        for s in f["subtasks"] as? [[String: Any]] ?? [] {
            let fi = s["fields"] as? [String: Any] ?? [:]
            links.append(.init(id: (s["key"] as? String ?? "") + "sub", key: s["key"] as? String ?? "",
                               summary: fi["summary"] as? String ?? "",
                               status: (fi["status"] as? [String: Any])?["name"] as? String ?? "", relation: "sous-tâche"))
        }
        let parent = (f["parent"] as? [String: Any]).map { p -> JiraIssueDetail.Linked in
            let fi = p["fields"] as? [String: Any] ?? [:]
            return .init(id: "parent", key: p["key"] as? String ?? "", summary: fi["summary"] as? String ?? "",
                         status: (fi["status"] as? [String: Any])?["name"] as? String ?? "", relation: "parent")
        }
        let attachments = (f["attachment"] as? [[String: Any]] ?? []).map {
            JiraIssueDetail.Attachment(id: $0["id"] as? String ?? UUID().uuidString, filename: $0["filename"] as? String ?? "fichier",
                                       url: $0["content"] as? String ?? "")
        }
        return JiraIssueDetail(
            key: key, summary: f["summary"] as? String ?? "",
            type: (f["issuetype"] as? [String: Any])?["name"] as? String ?? "",
            status: status["name"] as? String ?? "",
            statusCategory: (status["statusCategory"] as? [String: Any])?["key"] as? String ?? "",
            priority: (f["priority"] as? [String: Any])?["name"] as? String,
            assignee: name(f["assignee"]), reporter: name(f["reporter"]),
            created: date(f["created"]), updated: date(f["updated"]),
            due: (f["duedate"] as? String).flatMap { parseDate($0) },
            labels: f["labels"] as? [String] ?? [],
            descriptionMarkdown: ADF.markdown(f["description"]),
            comments: comments, links: links, attachments: attachments, parent: parent)
    }
}

/// Atlassian Document Format → Markdown (rendered by MarkdownPreview).
enum ADF {
    static func markdown(_ node: Any?) -> String {
        guard let n = node as? [String: Any] else { return "" }
        return block(n, indent: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func children(_ n: [String: Any]) -> [[String: Any]] { n["content"] as? [[String: Any]] ?? [] }
    private static func attrs(_ n: [String: Any]) -> [String: Any] { n["attrs"] as? [String: Any] ?? [:] }

    private static func block(_ n: [String: Any], indent: String) -> String {
        let kids = children(n)
        switch n["type"] as? String ?? "" {
        case "doc":
            return kids.map { block($0, indent: indent) }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        case "paragraph":
            return indent + inline(kids)
        case "heading":
            let level = attrs(n)["level"] as? Int ?? 2
            return (level <= 1 ? "# " : level == 2 ? "## " : "### ") + inline(kids)
        case "bulletList":
            return kids.map { item($0, prefix: "- ", indent: indent) }.joined(separator: "\n")
        case "orderedList":
            let start = attrs(n)["order"] as? Int ?? 1
            return kids.enumerated().map { item($0.element, prefix: "\(start + $0.offset). ", indent: indent) }.joined(separator: "\n")
        case "taskList":
            return kids.map { k -> String in
                if k["type"] as? String == "taskList" { return block(k, indent: indent + "  ") }
                let done = attrs(k)["state"] as? String == "DONE"
                return indent + (done ? "- [x] " : "- [ ] ") + inline(children(k))
            }.joined(separator: "\n")
        case "decisionList":
            return kids.map { indent + "- ✅ " + inline(children($0)) }.joined(separator: "\n")
        case "codeBlock":
            return "```\n" + kids.compactMap { $0["text"] as? String }.joined() + "\n```"
        case "blockquote":
            return kids.map { block($0, indent: "") }.joined(separator: "\n").split(separator: "\n").map { "> " + $0 }.joined(separator: "\n")
        case "panel":
            let icon = ["info": "ℹ️", "note": "📝", "warning": "⚠️", "error": "⛔", "success": "✅", "tip": "💡"][attrs(n)["panelType"] as? String ?? "info"] ?? "ℹ️"
            let body = kids.map { block($0, indent: "") }.joined(separator: "\n")
            return body.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
                .map { "> " + ($0.offset == 0 ? icon + " " : "") + $0.element }.joined(separator: "\n")
        case "expand", "nestedExpand":
            let title = attrs(n)["title"] as? String ?? ""
            return (title.isEmpty ? "" : "**\(title)**\n") + kids.map { block($0, indent: indent) }.joined(separator: "\n\n")
        case "rule":
            return "---"
        case "mediaSingle", "mediaGroup", "media":
            return indent + "📎 _pièce jointe_"
        case "table":
            return kids.map { row in
                "| " + children(row).map { cell in children(cell).map { block($0, indent: "") }.joined(separator: " ") }.joined(separator: " | ") + " |"
            }.joined(separator: "\n")
        default:
            return indent + inline(kids)
        }
    }

    private static func item(_ li: [String: Any], prefix: String, indent: String) -> String {
        var first = true
        return children(li).map { c -> String in
            let type = c["type"] as? String ?? ""
            if type == "bulletList" || type == "orderedList" || type == "taskList" {
                return block(c, indent: indent + "  ")
            }
            defer { first = false }
            return (first ? indent + prefix : indent + "  ") + block(c, indent: "")
        }.joined(separator: "\n")
    }

    private static func inline(_ nodes: [[String: Any]]) -> String {
        nodes.map { n -> String in
            let a = attrs(n)
            switch n["type"] as? String ?? "" {
            case "text":
                var t = n["text"] as? String ?? ""
                for m in n["marks"] as? [[String: Any]] ?? [] {
                    switch m["type"] as? String {
                    case "strong": t = "**\(t)**"
                    case "em": t = "*\(t)*"
                    case "code": t = "`\(t)`"
                    case "strike": t = "~~\(t)~~"
                    case "link": if let href = (m["attrs"] as? [String: Any])?["href"] as? String { t = "[\(t)](\(href))" }
                    default: break
                    }
                }
                return t
            case "hardBreak": return "\n"
            case "mention": return "**\(a["text"] as? String ?? "@")**"
            case "emoji": return a["text"] as? String ?? a["shortName"] as? String ?? ""
            case "inlineCard", "blockCard": return (a["url"] as? String).map { "[\($0)](\($0))" } ?? ""
            case "status": return "`\((a["text"] as? String ?? "").uppercased())`"
            case "date":
                if let ts = Double(a["timestamp"] as? String ?? "") { return Fmt.date(Date(timeIntervalSince1970: ts / 1000)) }
                return ""
            default: return inline(children(n))
            }
        }.joined()
    }
}

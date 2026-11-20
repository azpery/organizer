import Foundation
import SwiftUI

struct MergeRequest: Identifiable, Hashable {
    let id: Int
    let iid: Int
    let projectId: Int
    let title: String
    let webURL: String
    let state: String          // opened, merged, closed, locked
    let draft: Bool
    let sourceBranch: String
    let targetBranch: String
    let reference: String      // group/project!123
    let updatedAt: Date?
    var pipeline: String?      // success, failed, running, pending, canceled...
    var mergeStatus: String?   // detailed_merge_status

    var label: String {
        switch state {
        case "merged": "Mergée"
        case "closed": "Fermée"
        default: draft ? "Brouillon" : "Ouverte"
        }
    }

    var color: Color {
        switch state {
        case "merged": .purple
        case "closed": .red
        default: draft ? .gray : .blue
        }
    }

    var pipelineColor: Color? {
        switch pipeline {
        case "success": .green
        case "failed": .red
        case "running", "pending", "created", "preparing", "waiting_for_resource": .orange
        case nil: nil
        default: .gray
        }
    }

    var pipelineLabel: String? {
        switch pipeline {
        case "success": "Pipeline OK"
        case "failed": "Pipeline en échec"
        case "running": "Pipeline en cours"
        case "pending", "created", "preparing", "waiting_for_resource": "Pipeline en attente"
        case "canceled": "Pipeline annulé"
        case nil: nil
        default: "Pipeline \(pipeline!)"
        }
    }

    /// Most relevant first: open, then recently merged.
    var rank: Int { state == "opened" ? 0 : state == "merged" ? 1 : 2 }
}

enum GitLab {
    static var baseURL: String {
        let v = (UserDefaults.standard.string(forKey: "gitlabURL") ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        return v.isEmpty ? "https://gitlab.com" : v
    }
    static var token: String { UserDefaults.standard.string(forKey: "gitlabToken") ?? "" }
    static var isConfigured: Bool { !token.isEmpty }

    /// Project paths (group/project). Needed with fine-grained tokens that only have project permissions.
    static var projects: [String] {
        (UserDefaults.standard.string(forKey: "gitlabProjects") ?? "")
            .split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == " " })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")) }
            .map { $0.replacingOccurrences(of: "https://gitlab.com/", with: "") }
            .filter { !$0.isEmpty }
    }

    private static func get(_ path: String, _ query: [String: String] = [:]) async throws -> Any {
        var comps = URLComponents(string: baseURL + "/api/v4" + path)!
        if !query.isEmpty { comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var req = URLRequest(url: comps.url!)
        req.setValue(token, forHTTPHeaderField: "PRIVATE-TOKEN")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            if json["error"] as? String == "insufficient_granular_scope" {
                let desc = json["error_description"] as? String ?? ""
                let perm = desc.range(of: "[").map { String(desc[$0.lowerBound...]) } ?? ""
                if projects.isEmpty {
                    throw APIError(403, "Ton token fine-grained ne peut pas lister tes projets : renseigne le champ Projets (ex. groupe/front, groupe/api), ou crée un token classique avec le scope read_api.")
                }
                throw APIError(403, "Token GitLab sans la permission requise \(perm). Crée un token classique avec le scope read_api, ou ajoute Merge Request: Read, Project: Read et Pipeline: Read à ton token fine-grained.")
            }
            throw APIError(502, "GitLab \(status) : \(String(data: data, encoding: .utf8)?.prefix(200) ?? "")")
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    static func currentUser() async throws -> String {
        let u = try await get("/user") as? [String: Any]
        return u?["username"] as? String ?? "?"
    }

    /// MRs whose title, description or source branch mention the Jira key.
    static func mergeRequests(for key: String) async throws -> [MergeRequest] {
        if !projects.isEmpty { return try await mergeRequests(forKeys: [key])[key] ?? [] }
        let raw = try await get("/merge_requests", ["scope": "all", "state": "all", "search": key, "per_page": "20"]) as? [[String: Any]] ?? []
        return await parse(raw, matching: [key])[key] ?? []
    }

    /// Bulk mode: recent MRs fetched once per project, matched locally against all keys (avoids GitLab rate limits).
    static func mergeRequests(forKeys keys: [String]) async throws -> [String: [MergeRequest]] {
        var raw: [[String: Any]] = []
        for path in projects {
            let enc = path.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? path
            for page in 1...2 {
                let batch = try await get("/projects/\(enc)/merge_requests",
                                          ["state": "all", "per_page": "100", "page": "\(page)", "order_by": "updated_at"]) as? [[String: Any]] ?? []
                raw += batch
                if batch.count < 100 { break }
            }
        }
        return await parse(raw, matching: keys)
    }

    /// Keeps MRs whose title, description or branch mention a key (exact match); adds pipeline status to open ones.
    private static func parse(_ raw: [[String: Any]], matching keys: [String]) async -> [String: [MergeRequest]] {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let patterns: [(String, NSRegularExpression)] = keys.compactMap { k in
            (try? NSRegularExpression(pattern: "\\b" + k.replacingOccurrences(of: "-", with: "[-_ ]?") + "\\b", options: .caseInsensitive)).map { (k, $0) }
        }
        func mentions(_ p: NSRegularExpression, _ s: String) -> Bool { p.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }
        var out: [String: [MergeRequest]] = [:]
        var seen = Set<Int>()
        var details = 0
        for m in raw {
            let id = m["id"] as? Int ?? 0
            guard seen.insert(id).inserted else { continue }
            let title = m["title"] as? String ?? ""
            let desc = m["description"] as? String ?? ""
            let branch = m["source_branch"] as? String ?? ""
            var hits: [String] = []
            for (k, p) in patterns where mentions(p, title) || mentions(p, branch) || mentions(p, desc) { hits.append(k) }
            guard !hits.isEmpty else { continue }
            var mr = MergeRequest(
                id: id, iid: m["iid"] as? Int ?? 0, projectId: m["project_id"] as? Int ?? 0,
                title: title, webURL: m["web_url"] as? String ?? "", state: m["state"] as? String ?? "",
                draft: (m["draft"] as? Bool) ?? (m["work_in_progress"] as? Bool) ?? false,
                sourceBranch: branch, targetBranch: m["target_branch"] as? String ?? "",
                reference: (m["references"] as? [String: Any])?["full"] as? String ?? "!\(m["iid"] ?? "")",
                updatedAt: (m["updated_at"] as? String).flatMap { iso.date(from: $0) },
                pipeline: nil, mergeStatus: m["detailed_merge_status"] as? String)
            if mr.state == "opened", details < 15,
               let detail = try? await get("/projects/\(mr.projectId)/merge_requests/\(mr.iid)") as? [String: Any] {
                details += 1
                mr.pipeline = (detail["head_pipeline"] as? [String: Any])?["status"] as? String
                mr.mergeStatus = detail["detailed_merge_status"] as? String ?? mr.mergeStatus
            }
            for k in hits { out[k, default: []].append(mr) }
        }
        for k in out.keys {
            out[k]?.sort { ($0.rank, -($0.updatedAt?.timeIntervalSince1970 ?? 0)) < ($1.rank, -($1.updatedAt?.timeIntervalSince1970 ?? 0)) }
        }
        return out
    }
}

extension Store {
    /// Refreshes MRs for every task linked to a Jira key (done tasks only if recently completed).
    func refreshMergeRequests() async {
        guard GitLab.isConfigured else { return }
        let recent = Calendar.app.date(byAdding: .day, value: -30, to: Date())!
        let targets = tasks.filter { $0.jiraKey != nil && ($0.status != .done || ($0.completedAt ?? .distantPast) > recent) }
        var map: [String: [MergeRequest]] = [:]
        var failure: String?
        if !GitLab.projects.isEmpty {
            do {
                let byKey = try await GitLab.mergeRequests(forKeys: Array(Set(targets.compactMap(\.jiraKey))))
                for t in targets { if let k = t.jiraKey, let mrs = byKey[k] { map[t.id] = mrs } }
            } catch { showToast((error as? APIError)?.message ?? error.localizedDescription); return }
            mergeRequests = map
            mergeRequestsUpdatedAt = Date()
            return
        }
        for t in targets {
            do { map[t.id] = try await GitLab.mergeRequests(for: t.jiraKey!) }
            catch let e as APIError where e.status == 403 { failure = e.message; break }
            catch { failure = (error as? APIError)?.message ?? error.localizedDescription; break }
        }
        if let failure { showToast(failure); return }
        mergeRequests = map
        mergeRequestsUpdatedAt = Date()
    }

    func startGitLabPolling() {
        Task { await refreshMergeRequests() }
        Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshMergeRequests() }
        }
    }
}

/// Compact MR badge for task cards.
struct MRBadge: View {
    let mr: MergeRequest
    var extra = 0

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: mr.state == "merged" ? "arrow.triangle.merge" : "arrow.triangle.pull")
            Text("!\(mr.iid) \(mr.label)")
            if let c = mr.pipelineColor { Circle().fill(c).frame(width: 6, height: 6) }
            if extra > 0 { Text("+\(extra)").foregroundStyle(.secondary) }
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 7).padding(.vertical, 3)
        .foregroundStyle(mr.color)
        .background(Capsule().fill(mr.color.opacity(0.14)))
        .help([mr.title, mr.pipelineLabel].compactMap { $0 }.joined(separator: "\n"))
        .onTapGesture { if let u = URL(string: mr.webURL) { NSWorkspace.shared.open(u) } }
    }
}

/// Detailed MR row for the task editor.
struct MRRow: View {
    let mr: MergeRequest
    var body: some View {
        Button {
            if let u = URL(string: mr.webURL) { NSWorkspace.shared.open(u) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: mr.state == "merged" ? "arrow.triangle.merge" : "arrow.triangle.pull")
                    .foregroundStyle(mr.color)
                VStack(alignment: .leading, spacing: 3) {
                    Text(mr.title).lineLimit(1)
                    HStack(spacing: 6) {
                        Text(mr.reference).foregroundStyle(.secondary)
                        Text("\(mr.sourceBranch) → \(mr.targetBranch)").foregroundStyle(.tertiary).lineLimit(1)
                    }
                    .font(.caption)
                }
                Spacer()
                if let p = mr.pipelineLabel, let c = mr.pipelineColor {
                    Label(p, systemImage: "circle.fill").font(.caption).foregroundStyle(c).labelStyle(.titleAndIcon)
                }
                Pill(text: mr.label, color: mr.color)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

import AppKit
import SwiftUI

// MARK: - Model

struct MindNode: Codable, Identifiable, Hashable {
    var id: String = UUID().uuidString
    var text: String
    var parentId: String? = nil
    var order: Int = 0
    /// Root children only: -1 left, 1 right (nil = automatic balance).
    var side: Int? = nil
    var colorHex: String? = nil
    var collapsed: Bool = false
    var taskId: String? = nil
    var noteId: String? = nil
}

struct MindMap: Codable, Identifiable, Hashable {
    var id: String = UUID().uuidString
    var title: String
    var labels: [String] = []
    var nodes: [MindNode] = []
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init(title: String, labels: [String] = []) {
        self.title = title
        self.labels = labels
        nodes = [MindNode(text: title)]
    }

    var root: MindNode? { nodes.first { $0.parentId == nil } }
    func node(_ id: String?) -> MindNode? { id.flatMap { i in nodes.first { $0.id == i } } }
    func index(_ id: String) -> Int? { nodes.firstIndex { $0.id == id } }
    func children(of id: String) -> [MindNode] { nodes.filter { $0.parentId == id }.sorted { $0.order < $1.order } }

    func descendants(of id: String) -> [String] {
        var out: [String] = []
        var stack = [id]
        while let cur = stack.popLast() {
            for c in nodes where c.parentId == cur { out.append(c.id); stack.append(c.id) }
        }
        return out
    }

    func path(to id: String) -> [MindNode] {
        var out: [MindNode] = []
        var cur = node(id)
        while let n = cur { out.insert(n, at: 0); cur = node(n.parentId) }
        return out
    }

    @discardableResult
    mutating func addChild(to parentId: String, text: String = "", taskId: String? = nil) -> String {
        let siblings = children(of: parentId)
        var n = MindNode(text: text, parentId: parentId, order: (siblings.map(\.order).max() ?? -1) + 1)
        n.taskId = taskId
        if node(parentId)?.parentId == nil {
            // balance root branches: put the new one on the lighter side
            let right = siblings.filter { effectiveSide($0, among: siblings) == 1 }.count
            n.side = right <= siblings.count - right ? 1 : -1
        }
        if let i = index(parentId) { nodes[i].collapsed = false }
        nodes.append(n)
        return n.id
    }

    @discardableResult
    mutating func addSibling(after id: String, text: String = "") -> String? {
        guard let n = node(id), let parent = n.parentId else { return nil }
        for i in nodes.indices where nodes[i].parentId == parent && nodes[i].order > n.order { nodes[i].order += 1 }
        var s = MindNode(text: text, parentId: parent, order: n.order + 1)
        s.side = n.side
        nodes.append(s)
        return s.id
    }

    mutating func remove(_ id: String) {
        guard node(id)?.parentId != nil else { return }
        let gone = Set(descendants(of: id) + [id])
        nodes.removeAll { gone.contains($0.id) }
    }

    mutating func move(_ id: String, by delta: Int) {
        guard let n = node(id), let parent = n.parentId else { return }
        let sibs = children(of: parent)
        guard let pos = sibs.firstIndex(where: { $0.id == id }) else { return }
        let target = pos + delta
        guard sibs.indices.contains(target) else { return }
        let other = sibs[target]
        if let a = index(id), let b = index(other.id) { (nodes[a].order, nodes[b].order) = (nodes[b].order, nodes[a].order) }
    }

    mutating func reparent(_ id: String, to newParent: String) {
        guard id != newParent, !descendants(of: id).contains(newParent), let i = index(id), nodes[i].parentId != nil else { return }
        nodes[i].parentId = newParent
        nodes[i].order = (children(of: newParent).map(\.order).max() ?? -1) + 1
        nodes[i].side = node(newParent)?.parentId == nil ? (nodes[i].side ?? 1) : nil
        if let p = index(newParent) { nodes[p].collapsed = false }
    }

    func effectiveSide(_ n: MindNode, among siblings: [MindNode]) -> Int {
        if let s = n.side { return s }
        let idx = siblings.firstIndex { $0.id == n.id } ?? 0
        return idx % 2 == 0 ? 1 : -1
    }

    /// Indented Markdown outline (for notes and the API).
    @MainActor func markdown(store: Store? = nil) -> String {
        guard let root else { return "" }
        var lines = ["# \(root.text)", ""]
        func walk(_ id: String, depth: Int) {
            for c in children(of: id) {
                var line = String(repeating: "  ", count: depth) + "- " + c.text
                if let t = c.taskId, let task = store?.task(t) {
                    let key = task.jiraKey.flatMap { c.text.contains($0) ? nil : "\($0) " } ?? ""
                    line += " — \(key)[\(task.status.label)]"
                }
                lines.append(line)
                walk(c.id, depth: depth + 1)
            }
        }
        walk(root.id, depth: 0)
        return lines.joined(separator: "\n")
    }

    /// Builds nodes from nested {"text", "children"} JSON (API input).
    mutating func addTree(_ items: [[String: Any]], under parent: String) {
        for item in items {
            guard let text = item["text"] as? String ?? item["title"] as? String else { continue }
            let id = addChild(to: parent, text: text, taskId: item["task_id"] as? String)
            if let i = index(id) {
                nodes[i].noteId = item["note_id"] as? String
                nodes[i].colorHex = item["color"] as? String
                nodes[i].collapsed = item["collapsed"] as? Bool ?? false
            }
            if let c = item["children"] as? [[String: Any]] { addTree(c, under: id) }
        }
    }

    func tree(_ id: String? = nil) -> [String: Any] {
        guard let n = node(id ?? root?.id) else { return [:] }
        var out: [String: Any] = ["id": n.id, "text": n.text]
        if let t = n.taskId { out["task_id"] = t }
        if let nid = n.noteId { out["note_id"] = nid }
        if n.collapsed { out["collapsed"] = true }
        let kids = children(of: n.id)
        if !kids.isEmpty { out["children"] = kids.map { tree($0.id) } }
        return out
    }
}

// MARK: - Store

extension Store {
    func mindmap(_ id: String) -> MindMap? { mindmaps.first { $0.id == id } }

    @discardableResult
    func upsertMindMap(_ m: MindMap, touch: Bool = true) -> MindMap {
        var m = m
        if touch { m.updatedAt = Date() }
        if let root = m.root, let i = m.index(root.id), m.nodes[i].text != m.title {
            // the root node *is* the title
            m.title = m.nodes[i].text.isEmpty ? m.title : m.nodes[i].text
        }
        do { try db.saveJSON("mindmaps", m) } catch { lastError = "\(error)" }
        if let i = mindmaps.firstIndex(where: { $0.id == m.id }) { mindmaps[i] = m } else { mindmaps.insert(m, at: 0) }
        return m
    }

    func deleteMindMap(_ id: String) {
        try? db.delete(table: "mindmaps", id: id)
        mindmaps.removeAll { $0.id == id }
    }

    /// Asks Ollama for sub-ideas of a node.
    func expandIdeas(map: MindMap, nodeId: String) async throws -> [String] {
        let path = map.path(to: nodeId).map(\.text).joined(separator: " › ")
        let existing = map.children(of: nodeId).map(\.text)
        let system = "Tu aides \(Profile.who) à structurer ses idées dans une carte mentale. En français, idées courtes (2 à 8 mots), concrètes et actionnables, sans numérotation."
        let user = """
        Carte : « \(map.title) ». Branche à développer : \(path).
        \(existing.isEmpty ? "" : "Sous-branches existantes (ne pas répéter) : \(existing.joined(separator: " ; ")).")
        Propose 4 à 6 sous-idées pertinentes. Réponds en JSON : ideas (liste de textes).
        """
        let schema: [String: Any] = ["type": "object", "properties": ["ideas": ["type": "array", "items": ["type": "string"]]], "required": ["ideas"]]
        let raw = try await Ollama.chat(system: system, user: user, schema: schema)
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return (json["ideas"] as? [String] ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.prefix(6).map { $0 }
    }
}

// MARK: - Layout

struct MindLayout {
    var frames: [String: CGRect] = [:]
    var side: [String: Int] = [:]
    var depth: [String: Int] = [:]
    var color: [String: String] = [:]
    var hiddenCount: [String: Int] = [:]
    var size: CGSize = .zero

    static let palette = ["#7C5CFF", "#FF6B6B", "#22B07D", "#FF9F1C", "#2E9BFF", "#E84393", "#00B8A9", "#A0785A"]
    static let hGap: CGFloat = 54
    static let margin: CGFloat = 80

    static func font(depth: Int) -> NSFont {
        switch depth {
        case 0: .systemFont(ofSize: 18, weight: .bold)
        case 1: .systemFont(ofSize: 15, weight: .semibold)
        default: .systemFont(ofSize: 13, weight: .regular)
        }
    }

    static func padding(depth: Int) -> CGSize { depth == 0 ? CGSize(width: 22, height: 14) : depth == 1 ? CGSize(width: 15, height: 9) : CGSize(width: 11, height: 6) }

    static func measure(_ text: String, depth: Int, extra: CGFloat) -> CGSize {
        let maxW: CGFloat = depth == 0 ? 280 : 230
        let str = text.isEmpty ? "Idée" : text
        let r = (str as NSString).boundingRect(with: CGSize(width: maxW, height: 1000), options: [.usesLineFragmentOrigin, .usesFontLeading],
                                               attributes: [.font: font(depth: depth)])
        let pad = padding(depth: depth)
        return CGSize(width: max(depth == 0 ? 120 : 60, ceil(r.width) + extra) + pad.width * 2, height: ceil(r.height) + pad.height * 2)
    }

    init() {}

    init(map: MindMap, editingId: String?, draft: String) {
        guard let root = map.root else { return }
        var sizes: [String: CGSize] = [:]
        var subtree: [String: CGFloat] = [:]
        var kidsCache: [String: [MindNode]] = [:]

        func kids(_ n: MindNode) -> [MindNode] {
            if let k = kidsCache[n.id] { return k }
            let k = n.collapsed ? [] : map.children(of: n.id)
            kidsCache[n.id] = k
            return k
        }
        func vGap(_ d: Int) -> CGFloat { d <= 1 ? 26 : 10 }
        func measureTree(_ n: MindNode, d: Int) {
            depth[n.id] = d
            let text = n.id == editingId ? draft : n.text
            sizes[n.id] = MindLayout.measure(text, depth: d, extra: (n.taskId != nil ? 22 : 0) + (n.noteId != nil ? 20 : 0))
            if n.collapsed { hiddenCount[n.id] = map.descendants(of: n.id).count }
            let k = kids(n)
            k.forEach { measureTree($0, d: d + 1) }
            let childH = k.reduce(0) { $0 + subtree[$1.id]! } + vGap(d + 1) * CGFloat(max(0, k.count - 1))
            subtree[n.id] = max(sizes[n.id]!.height, childH)
        }
        measureTree(root, d: 0)

        func place(_ n: MindNode, centerY: CGFloat, edgeX: CGFloat, side s: Int, colorHex: String) {
            let sz = sizes[n.id]!
            let x = s == 1 ? edgeX : edgeX - sz.width
            frames[n.id] = CGRect(x: x, y: centerY - sz.height / 2, width: sz.width, height: sz.height)
            side[n.id] = s
            color[n.id] = n.colorHex ?? colorHex
            layoutChildren(kids(n), parentFrame: frames[n.id]!, side: s, colorFor: { _, _ in n.colorHex ?? colorHex }, depth: depth[n.id]! + 1)
        }
        func layoutChildren(_ k: [MindNode], parentFrame: CGRect, side s: Int, colorFor: (MindNode, Int) -> String, depth d: Int) {
            guard !k.isEmpty else { return }
            let total = k.reduce(0) { $0 + subtree[$1.id]! } + vGap(d) * CGFloat(k.count - 1)
            var y = parentFrame.midY - total / 2
            let edge = s == 1 ? parentFrame.maxX + MindLayout.hGap : parentFrame.minX - MindLayout.hGap
            for (i, c) in k.enumerated() {
                let h = subtree[c.id]!
                place(c, centerY: y + h / 2, edgeX: edge, side: s, colorHex: colorFor(c, i))
                y += h + vGap(d)
            }
        }

        let rs = sizes[root.id]!
        let rootFrame = CGRect(x: -rs.width / 2, y: -rs.height / 2, width: rs.width, height: rs.height)
        frames[root.id] = rootFrame
        side[root.id] = 0
        color[root.id] = root.colorHex ?? "#5B5BD6"
        let all = kids(root)
        let rightKids = all.filter { map.effectiveSide($0, among: all) == 1 }
        let leftKids = all.filter { map.effectiveSide($0, among: all) == -1 }
        let paletteIndex = Dictionary(uniqueKeysWithValues: all.enumerated().map { ($1.id, $0) })
        let pick: (MindNode, Int) -> String = { c, _ in MindLayout.palette[(paletteIndex[c.id] ?? 0) % MindLayout.palette.count] }
        layoutChildren(rightKids, parentFrame: rootFrame, side: 1, colorFor: pick, depth: 1)
        layoutChildren(leftKids, parentFrame: rootFrame, side: -1, colorFor: pick, depth: 1)

        // normalise to positive coordinates
        let union = frames.values.reduce(rootFrame) { $0.union($1) }
        let dx = MindLayout.margin - union.minX, dy = MindLayout.margin - union.minY
        for (k, f) in frames { frames[k] = f.offsetBy(dx: dx, dy: dy) }
        size = CGSize(width: union.width + MindLayout.margin * 2, height: union.height + MindLayout.margin * 2)
    }
}

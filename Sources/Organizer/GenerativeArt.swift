import SwiftUI
import AppKit

// MARK: - Deterministic randomness

/// SplitMix64: same seed, same picture.
struct SeededRNG {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func range(_ a: Double, _ b: Double) -> Double { a + (b - a) * unit() }
    mutating func int(_ n: Int) -> Int { n <= 1 ? 0 : Int(next() % UInt64(n)) }
    mutating func chance(_ p: Double) -> Bool { unit() < p }
}

/// Smooth 2D value noise in 0…1.
struct ValueNoise {
    let seed: UInt64

    private func hash(_ x: Int, _ y: Int) -> Double {
        var h = (UInt64(bitPattern: Int64(x)) &* 0x9E3779B97F4A7C15) ^ (UInt64(bitPattern: Int64(y)) &* 0xC2B2AE3D27D4EB4F) ^ seed
        h ^= h >> 33; h &*= 0xFF51AFD7ED558CCD
        h ^= h >> 33; h &*= 0xC4CEB9FE1A85EC53
        h ^= h >> 33
        return Double(h >> 11) / Double(1 << 53)
    }

    func value(_ x: Double, _ y: Double) -> Double {
        let x0 = Int(floor(x)), y0 = Int(floor(y))
        let fx = x - Double(x0), fy = y - Double(y0)
        let sx = fx * fx * (3 - 2 * fx), sy = fy * fy * (3 - 2 * fy)
        let a = hash(x0, y0), b = hash(x0 + 1, y0), c = hash(x0, y0 + 1), d = hash(x0 + 1, y0 + 1)
        return (a + (b - a) * sx) * (1 - sy) + (c + (d - c) * sx) * sy
    }

    func fbm(_ x: Double, _ y: Double) -> Double {
        value(x, y) * 0.65 + value(x * 2 + 17.3, y * 2 + 31.7) * 0.35
    }
}

// MARK: - Configuration

enum ArtStyle: String, CaseIterable, Identifiable {
    case flow, moire, circles, phyllo, truchet, halftone, ridges, constellation, blocks, orbits
    var id: Self { self }

    var title: String {
        switch self {
        case .flow: "Champ de flux"
        case .circles: "Bulles"
        case .truchet: "Entrelacs"
        case .ridges: "Crêtes"
        case .blocks: "Blocs"
        case .orbits: "Orbites"
        case .moire: "Moiré"
        case .phyllo: "Tournesol"
        case .halftone: "Trame"
        case .constellation: "Constellation"
        }
    }

    var icon: String {
        switch self {
        case .flow: "wind"
        case .circles: "circle.hexagongrid"
        case .truchet: "square.grid.3x3.square"
        case .ridges: "waveform.path"
        case .blocks: "rectangle.3.group"
        case .orbits: "atom"
        case .moire: "circle.circle"
        case .phyllo: "camera.macro"
        case .halftone: "circle.grid.3x3.fill"
        case .constellation: "point.3.filled.connected.trianglepath.dotted"
        }
    }
}

struct ArtPalette: Identifiable, Equatable {
    let name: String
    let background: String
    let colors: [String]
    var id: String { name }

    static let all: [ArtPalette] = [
        ArtPalette(name: "Aurore", background: "#0B1026", colors: ["#4F7CFF", "#7B5CFF", "#FF5CA8", "#FFC857", "#5CE1E6"]),
        ArtPalette(name: "Terre cuite", background: "#F4EBDD", colors: ["#C8553D", "#F28F3B", "#588B8B", "#2D3047", "#E8B4A0"]),
        ArtPalette(name: "Encre", background: "#F7F5F0", colors: ["#111111", "#3A3A3A", "#7A7A7A", "#C0392B"]),
        ArtPalette(name: "Forêt", background: "#0F1F17", colors: ["#2D6A4F", "#52B788", "#95D5B2", "#D8F3DC", "#F4A261"]),
        ArtPalette(name: "Bonbon", background: "#FFF4F8", colors: ["#FF6B9D", "#C44DFF", "#4DC9FF", "#FFC93D", "#3DDC97"]),
        ArtPalette(name: "Néon", background: "#050505", colors: ["#00F5D4", "#F15BB5", "#FEE440", "#9B5DE5", "#00BBF9"]),
        ArtPalette(name: "Océan", background: "#03111F", colors: ["#0077B6", "#00B4D8", "#90E0EF", "#CAF0F8", "#FFB703"]),
        ArtPalette(name: "Sable", background: "#EFE6D5", colors: ["#3D405B", "#E07A5F", "#81B29A", "#F2CC8F"]),
    ]
}

enum ArtFormat: String, CaseIterable, Identifiable {
    case square, landscape, portrait
    var id: Self { self }
    var title: String {
        switch self {
        case .square: "Carré"
        case .landscape: "Paysage"
        case .portrait: "Portrait"
        }
    }
    /// width / height
    var ratio: Double {
        switch self {
        case .square: 1
        case .landscape: 16.0 / 10.0
        case .portrait: 4.0 / 5.0
        }
    }
}

struct ArtConfig: Equatable {
    var style: ArtStyle = .flow
    var palette: ArtPalette = ArtPalette.all[0]
    var seed: UInt64 = 1
    /// 0…1
    var density: Double = 0.5
    /// Animation clock in seconds; 0 is the still picture.
    var time: Double = 0
}

// MARK: - Drawing

enum ArtRenderer {
    static func draw(_ context: GraphicsContext, size: CGSize, config c: ArtConfig) {
        var ctx = context
        ctx.clip(to: Path(CGRect(origin: .zero, size: size)))
        let bg = Color(hex: c.palette.background)
        ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(bg))
        let colors = c.palette.colors.map { Color(hex: $0) }
        guard !colors.isEmpty, size.width > 1, size.height > 1 else { return }
        var rng = SeededRNG(state: c.seed &* 0x2545F4914F6CDD1D &+ 1)
        let noise = ValueNoise(seed: c.seed)
        switch c.style {
        case .flow: flow(ctx, size, c, colors, &rng, noise)
        case .circles: circles(ctx, size, c, colors, &rng)
        case .truchet: truchet(ctx, size, c, colors, bg, &rng, noise)
        case .ridges: ridges(ctx, size, c, colors, bg, &rng, noise)
        case .blocks: blocks(ctx, size, c, colors, bg, &rng)
        case .orbits: orbits(ctx, size, c, colors, &rng)
        case .moire: moire(ctx, size, c, colors, &rng)
        case .phyllo: phyllo(ctx, size, c, colors, &rng)
        case .halftone: halftone(ctx, size, c, colors, &rng, noise)
        case .constellation: constellation(ctx, size, c, colors, &rng)
        }
    }

    private static func flow(_ ctx: GraphicsContext, _ size: CGSize, _ c: ArtConfig, _ colors: [Color], _ rng: inout SeededRNG, _ noise: ValueNoise) {
        let w = size.width, h = size.height, u = min(w, h)
        let scale = rng.range(1.4, 3.6), turns = rng.range(1.0, 2.4), step = u * 0.006
        // A couple of colors dominate, the others are accents.
        let main = rng.int(colors.count)
        for _ in 0..<Int(300 + c.density * 2700) {
            var x = rng.range(-0.1, 1.1) * w, y = rng.range(-0.1, 1.1) * h
            var p = Path()
            p.move(to: CGPoint(x: x, y: y))
            for _ in 0..<Int(rng.range(30, 110)) {
                let a = noise.fbm(x / u * scale + c.time * 0.12, y / u * scale + c.time * 0.08) * .pi * 2 * turns
                x += cos(a) * step; y += sin(a) * step
                p.addLine(to: CGPoint(x: x, y: y))
            }
            let color = rng.chance(0.45) ? colors[main] : colors[rng.int(colors.count)]
            ctx.stroke(p, with: .color(color.opacity(rng.range(0.35, 0.9))),
                       style: StrokeStyle(lineWidth: u * rng.range(0.0008, 0.0036), lineCap: .round, lineJoin: .round))
        }
    }

    private static func circles(_ ctx: GraphicsContext, _ size: CGSize, _ c: ArtConfig, _ colors: [Color], _ rng: inout SeededRNG) {
        let w = size.width, h = size.height, u = min(w, h)
        let maxR = u * 0.17, minR = u * 0.005, gap = u * 0.004
        var placed: [(x: Double, y: Double, r: Double)] = []
        for _ in 0..<Int(1200 + c.density * 6800) {
            let x = rng.range(0, 1) * w, y = rng.range(0, 1) * h
            let cap = minR + maxR * pow(rng.unit(), 2.2)
            var r = cap
            for o in placed {
                let d = ((x - o.x) * (x - o.x) + (y - o.y) * (y - o.y)).squareRoot() - o.r - gap
                if d < r { r = d }
                if r < minR { break }
            }
            // Keep a margin around the picture.
            r = min(r, x - u * 0.03, w - u * 0.03 - x, y - u * 0.03, h - u * 0.03 - y)
            guard r >= minR else { continue }
            placed.append((x, y, r))
            // Random draws below must not depend on the animated radius, or the picture would flicker.
            let still = r
            if c.time != 0 {
                let pace = 0.7 + (x / w * 7.3 + y / h * 3.1).truncatingRemainder(dividingBy: 1) * 1.1
                r *= 1 - 0.22 * (0.5 - 0.5 * cos(c.time * pace))
            }
            let color = colors[rng.int(colors.count)]
            let rect = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
            let kind = rng.unit()
            if kind < 0.55 {
                ctx.fill(Path(ellipseIn: rect), with: .color(color))
                if still > u * 0.03, rng.chance(0.5) {
                    let k = rng.range(0.3, 0.6)
                    ctx.fill(Path(ellipseIn: rect.insetBy(dx: r * (1 - k), dy: r * (1 - k))), with: .color(colors[rng.int(colors.count)]))
                }
            } else if kind < 0.8 {
                let lw = max(u * 0.002, r * 0.16)
                ctx.stroke(Path(ellipseIn: rect.insetBy(dx: lw / 2, dy: lw / 2)), with: .color(color), lineWidth: lw)
            } else {
                var rr = r
                let lw = max(u * 0.0015, r * 0.07)
                while rr > lw {
                    ctx.stroke(Path(ellipseIn: CGRect(x: x - rr + lw / 2, y: y - rr + lw / 2, width: (rr - lw / 2) * 2, height: (rr - lw / 2) * 2)),
                               with: .color(color), lineWidth: lw)
                    rr -= lw * 2.6
                }
            }
        }
    }

    private static func truchet(_ ctx: GraphicsContext, _ size: CGSize, _ c: ArtConfig, _ colors: [Color], _ bg: Color, _ rng: inout SeededRNG, _ noise: ValueNoise) {
        let cols = Int(5 + c.density * 25)
        let cell = size.width / Double(cols)
        let rows = Int((size.height / cell).rounded(.up))
        let lw = cell * rng.range(0.16, 0.34)
        let zoom = rng.range(0.12, 0.4)
        func arc(_ cx: Double, _ cy: Double, _ start: Double) -> Path {
            var p = Path()
            p.addArc(center: CGPoint(x: cx, y: cy), radius: cell / 2, startAngle: .degrees(start), endAngle: .degrees(start + 90), clockwise: false)
            return p
        }
        for row in 0..<rows {
            for col in 0..<cols {
                let x = Double(col) * cell, y = Double(row) * cell
                let n = noise.fbm(Double(col) * zoom + c.time * 0.18, Double(row) * zoom + c.time * 0.11)
                let color = colors[min(colors.count - 1, Int(n * Double(colors.count)))]
                let arcs = rng.chance(0.5)
                    ? [arc(x, y, 0), arc(x + cell, y + cell, 180)]
                    : [arc(x + cell, y, 90), arc(x, y + cell, 270)]
                for a in arcs {
                    ctx.stroke(a, with: .color(color), lineWidth: lw)
                }
            }
        }
    }

    private static func ridges(_ ctx: GraphicsContext, _ size: CGSize, _ c: ArtConfig, _ colors: [Color], _ bg: Color, _ rng: inout SeededRNG, _ noise: ValueNoise) {
        let w = size.width, h = size.height, u = min(w, h)
        let rows = Int(16 + c.density * 54)
        let freq = rng.range(3, 7), amp = u * rng.range(0.14, 0.24), peak = rng.range(0.35, 0.65) + 0.08 * sin(c.time * 0.3)
        let samples = 180
        for r in 0..<rows {
            let baseY = h * (0.2 + 0.7 * Double(r) / Double(rows - 1))
            var line = Path()
            for s in 0...samples {
                let t = Double(s) / Double(samples)
                let x = w * (0.08 + 0.84 * t)
                // Flat at the edges, mountainous around a moving peak.
                let env = exp(-pow((t - peak) / 0.22, 2))
                let n = noise.fbm(t * freq, Double(r) * 0.32 + c.time * 0.22)
                let y = baseY - env * amp * n * n * 1.6 - noise.value(t * 45, Double(r) * 3.1) * u * 0.004
                if s == 0 { line.move(to: CGPoint(x: x, y: y)) } else { line.addLine(to: CGPoint(x: x, y: y)) }
            }
            var fill = line
            fill.addLine(to: CGPoint(x: w * 0.92, y: baseY + u * 0.02))
            fill.addLine(to: CGPoint(x: w * 0.08, y: baseY + u * 0.02))
            fill.closeSubpath()
            ctx.fill(fill, with: .color(bg))
            let color = colors[min(colors.count - 1, Int(Double(r) / Double(rows) * Double(colors.count)))]
            ctx.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: u * 0.0026, lineCap: .round, lineJoin: .round))
        }
    }

    private static func blocks(_ ctx: GraphicsContext, _ size: CGSize, _ c: ArtConfig, _ colors: [Color], _ bg: Color, _ rng: inout SeededRNG) {
        let u = min(size.width, size.height)
        let gap = u * 0.006, maxDepth = Int(3 + c.density * 6)
        var leaves: [CGRect] = []
        // `still` decides the structure (stable across frames), `r` is what gets drawn.
        func cut(_ r: CGRect, _ k: Double, _ vertical: Bool) -> (CGRect, CGRect) {
            vertical
                ? (CGRect(x: r.minX, y: r.minY, width: r.width * k, height: r.height),
                   CGRect(x: r.minX + r.width * k, y: r.minY, width: r.width * (1 - k), height: r.height))
                : (CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height * k),
                   CGRect(x: r.minX, y: r.minY + r.height * k, width: r.width, height: r.height * (1 - k)))
        }
        func split(_ r: CGRect, _ still: CGRect, _ depth: Int, _ rng: inout SeededRNG) {
            let small = min(still.width, still.height) < u * 0.05
            if depth >= maxDepth || small || (depth > 1 && rng.chance(0.14)) { leaves.append(r); return }
            let k = rng.range(0.3, 0.7), pace = rng.range(0.4, 1.1)
            let vertical = still.width > still.height * 1.25 ? true : still.height > still.width * 1.25 ? false : rng.chance(0.5)
            let moving = min(0.85, max(0.15, k + 0.12 * sin(c.time * pace)))
            let a = cut(r, c.time == 0 ? k : moving, vertical), b = cut(still, k, vertical)
            split(a.0, b.0, depth + 1, &rng)
            split(a.1, b.1, depth + 1, &rng)
        }
        let m = u * 0.04
        let frame = CGRect(x: m, y: m, width: size.width - 2 * m, height: size.height - 2 * m)
        split(frame, frame, 0, &rng)
        for leaf in leaves {
            let r = leaf.insetBy(dx: gap, dy: gap)
            let ci = rng.int(colors.count)
            let color = colors[ci], other = colors[(ci + 1 + rng.int(max(1, colors.count - 1))) % colors.count]
            let kind = rng.unit(), dot = rng.range(0.45, 0.8)
            guard r.width > 1, r.height > 1 else { continue }
            let shape = Path(roundedRect: r, cornerRadius: u * 0.004)
            if kind < 0.12 {
                ctx.stroke(shape, with: .color(color), lineWidth: u * 0.003)
            } else {
                ctx.fill(shape, with: .color(color))
                let s = min(r.width, r.height)
                if kind < 0.32 {
                    let d = s * dot
                    ctx.fill(Path(ellipseIn: CGRect(x: r.midX - d / 2, y: r.midY - d / 2, width: d, height: d)), with: .color(other))
                } else if kind < 0.5 {
                    var inner = ctx
                    inner.clip(to: shape)
                    let stripe = max(u * 0.008, s * 0.12)
                    var x = r.minX - r.height
                    while x < r.maxX {
                        var p = Path()
                        p.move(to: CGPoint(x: x, y: r.maxY)); p.addLine(to: CGPoint(x: x + r.height, y: r.minY))
                        inner.stroke(p, with: .color(other), lineWidth: stripe * 0.5)
                        x += stripe * 1.6
                    }
                } else if kind < 0.6 {
                    var p = Path()
                    p.move(to: CGPoint(x: r.minX, y: r.maxY)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
                    p.closeSubpath()
                    var inner = ctx
                    inner.clip(to: shape)
                    inner.fill(p, with: .color(other))
                }
            }
        }
    }

    private static func orbits(_ ctx: GraphicsContext, _ size: CGSize, _ c: ArtConfig, _ colors: [Color], _ rng: inout SeededRNG) {
        let u = min(size.width, size.height)
        let cx = size.width / 2, cy = size.height / 2
        let curves = Int(1 + c.density * 5)
        for i in 0..<curves {
            // Harmonograph: two damped pendulums per axis, near-integer frequency ratios.
            func freq(_ rng: inout SeededRNG) -> Double { Double(1 + rng.int(4)) + rng.range(-0.012, 0.012) }
            let f = (freq(&rng), freq(&rng), freq(&rng), freq(&rng))
            let ph = (rng.range(0, .pi * 2) + c.time * 0.21, rng.range(0, .pi * 2) + c.time * 0.13, rng.range(0, .pi * 2) + c.time * 0.17, rng.range(0, .pi * 2) + c.time * 0.09)
            let d = (rng.range(0.004, 0.02), rng.range(0.004, 0.02))
            let radius = u * 0.22 * (1 - Double(i) * 0.08)
            var p = Path()
            let points = 5200
            for s in 0..<points {
                let t = Double(s) * 0.022
                let x = cx + radius * (sin(f.0 * t + ph.0) * exp(-d.0 * t) + sin(f.1 * t + ph.1) * exp(-d.1 * t))
                let y = cy + radius * (sin(f.2 * t + ph.2) * exp(-d.0 * t) + sin(f.3 * t + ph.3) * exp(-d.1 * t))
                if s == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
            }
            ctx.stroke(p, with: .color(colors[i % colors.count].opacity(0.85)),
                       style: StrokeStyle(lineWidth: u * 0.002, lineCap: .round, lineJoin: .round))
        }
    }

    /// Two or three fine gratings (rings, lines or rays) slightly out of register: the interference draws the picture.
    private static func moire(_ ctx: GraphicsContext, _ size: CGSize, _ c: ArtConfig, _ colors: [Color], _ rng: inout SeededRNG) {
        let w = size.width, h = size.height, u = min(w, h)
        let diag = (w * w + h * h).squareRoot()
        let spacing = u / (26 + c.density * 74)
        let layers = rng.chance(0.4) ? 3 : 2
        let first = rng.int(colors.count)
        // Rings against rings is the classic; other pairings give fans and curtains.
        let kinds = [0, rng.chance(0.55) ? 0 : 1 + rng.int(2), rng.int(3)]
        for i in 0..<layers {
            let phase = rng.range(0, .pi * 2), pace = rng.range(0.25, 0.6) * (i % 2 == 0 ? 1 : -1)
            let wander = u * rng.range(0.03, 0.09)
            let base = CGPoint(x: w * rng.range(0.35, 0.65), y: h * rng.range(0.35, 0.65))
            let a = phase + c.time * pace
            let center = CGPoint(x: base.x + cos(a) * wander, y: base.y + sin(a) * wander)
            let tilt = rng.range(0, .pi) + c.time * pace * 0.12
            let gap = spacing * rng.range(0.92, 1.08)
            var p = Path()
            var lineWidth = gap * 0.42
            switch kinds[i] {
            case 0:
                var r = gap * 0.5
                while r < diag {
                    p.addEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
                    r += gap
                }
            case 1:
                let dx = cos(tilt), dy = sin(tilt)
                var d = -diag
                while d < diag {
                    // Line at signed distance d from the center, direction (dx, dy).
                    let ox = center.x - dy * d, oy = center.y + dx * d
                    p.move(to: CGPoint(x: ox - dx * diag, y: oy - dy * diag))
                    p.addLine(to: CGPoint(x: ox + dx * diag, y: oy + dy * diag))
                    d += gap
                }
            default:
                let rays = Int(70 + c.density * 190)
                for k in 0..<rays {
                    let t = tilt + Double(k) / Double(rays) * .pi * 2
                    p.move(to: CGPoint(x: center.x + cos(t) * u * 0.02, y: center.y + sin(t) * u * 0.02))
                    p.addLine(to: CGPoint(x: center.x + cos(t) * diag, y: center.y + sin(t) * diag))
                }
                lineWidth = u * 0.0022
            }
            ctx.stroke(p, with: .color(colors[(first + i) % colors.count].opacity(layers == 3 ? 0.8 : 0.9)), lineWidth: lineWidth)
        }
    }

    /// Seeds of a sunflower: one dot every golden angle (or a neighbouring angle, for other spirals).
    private static func phyllo(_ ctx: GraphicsContext, _ size: CGSize, _ c: ArtConfig, _ colors: [Color], _ rng: inout SeededRNG) {
        let u = min(size.width, size.height)
        let cx = size.width / 2, cy = size.height / 2
        let n = Int(350 + c.density * 2650)
        let angles = [137.508, 137.508, 137.3, 137.65, 99.5, 151.14, 222.49]
        let divergence = (angles[rng.int(angles.count)] + 0.12 * sin(c.time * 0.23)) * .pi / 180
        let arms = [3, 5, 8, 13, 21][rng.int(5)]
        let spread = u * 0.47 / Double(n).squareRoot()
        let grow = rng.chance(0.5), swell = rng.range(0.7, 1.3)
        let spin = c.time * 0.05
        for i in 1...n {
            let t = Double(i) / Double(n)
            let a = Double(i) * divergence + spin, r = spread * Double(i).squareRoot()
            let d = spread * swell * (grow ? 0.35 + 0.9 * t : 1.15 - 0.75 * t)
            let pulse = c.time == 0 ? 1 : 0.8 + 0.2 * sin(c.time * 1.2 - t * 9)
            let rect = CGRect(x: cx + cos(a) * r - d * pulse / 2, y: cy + sin(a) * r - d * pulse / 2, width: d * pulse, height: d * pulse)
            ctx.fill(Path(ellipseIn: rect), with: .color(colors[(i % arms) % colors.count]))
        }
    }

    /// Halftone screen: dots sized by ripples spreading from two sources.
    private static func halftone(_ ctx: GraphicsContext, _ size: CGSize, _ c: ArtConfig, _ colors: [Color], _ rng: inout SeededRNG, _ noise: ValueNoise) {
        let w = size.width, h = size.height, u = min(w, h)
        let cols = Int(14 + c.density * 56)
        let cell = w / Double(cols), rows = Int((h / cell).rounded(.up))
        let s1 = CGPoint(x: w * rng.range(0.1, 0.9), y: h * rng.range(0.1, 0.9))
        let s2 = CGPoint(x: w * rng.range(0.1, 0.9), y: h * rng.range(0.1, 0.9))
        let k1 = rng.range(14, 34) / u, k2 = rng.range(14, 34) / u
        let zoom = rng.range(1.5, 4), stagger = rng.chance(0.5)
        for row in 0...rows {
            for col in 0...cols {
                let x = (Double(col) + (stagger && row % 2 == 1 ? 0.5 : 0)) * cell, y = Double(row) * cell
                let d1 = ((x - s1.x) * (x - s1.x) + (y - s1.y) * (y - s1.y)).squareRoot()
                let d2 = ((x - s2.x) * (x - s2.x) + (y - s2.y) * (y - s2.y)).squareRoot()
                let wave = (sin(d1 * k1 - c.time * 1.4) + sin(d2 * k2 - c.time * 1.1)) / 4 + 0.5
                let d = cell * (0.12 + 0.86 * wave)
                let n = noise.fbm(x / u * zoom, y / u * zoom)
                let color = colors[min(colors.count - 1, Int(n * Double(colors.count)))]
                ctx.fill(Path(ellipseIn: CGRect(x: x - d / 2, y: y - d / 2, width: d, height: d)), with: .color(color))
            }
        }
    }

    /// Drifting points, linked when they come close to each other.
    private static func constellation(_ ctx: GraphicsContext, _ size: CGSize, _ c: ArtConfig, _ colors: [Color], _ rng: inout SeededRNG) {
        let w = size.width, h = size.height, u = min(w, h)
        let n = Int(50 + c.density * 330)
        let reach = (w * h).squareRoot() * 1.7 / Double(n).squareRoot()
        var pts: [(p: CGPoint, color: Color, size: Double)] = []
        for _ in 0..<n {
            let x = rng.range(0.03, 0.97) * w, y = rng.range(0.03, 0.97) * h
            let phase = rng.range(0, .pi * 2), pace = rng.range(0.15, 0.5) * (rng.chance(0.5) ? 1 : -1), orbit = u * rng.range(0.01, 0.05)
            let a = phase + c.time * pace
            pts.append((CGPoint(x: x + (cos(a) - cos(phase)) * orbit, y: y + (sin(a * 1.3) - sin(phase * 1.3)) * orbit),
                        colors[rng.int(colors.count)], u * (rng.chance(0.12) ? rng.range(0.007, 0.013) : rng.range(0.002, 0.005))))
        }
        for i in 0..<n {
            for j in (i + 1)..<max(i + 1, n) {
                let dx = pts[i].p.x - pts[j].p.x, dy = pts[i].p.y - pts[j].p.y
                let d = (dx * dx + dy * dy).squareRoot()
                guard d < reach else { continue }
                var line = Path()
                line.move(to: pts[i].p); line.addLine(to: pts[j].p)
                ctx.stroke(line, with: .color(pts[i].color.opacity(0.75 * (1 - d / reach))), lineWidth: u * 0.0014)
            }
        }
        for pt in pts {
            ctx.fill(Path(ellipseIn: CGRect(x: pt.p.x - pt.size, y: pt.p.y - pt.size, width: pt.size * 2, height: pt.size * 2)), with: .color(pt.color))
        }
    }

    // MARK: Export

    @MainActor
    static func png(_ config: ArtConfig, pixels: CGSize) -> Data? {
        let renderer = ImageRenderer(content: ArtCanvas(config: config).frame(width: pixels.width / 2, height: pixels.height / 2))
        renderer.scale = 2
        guard let cg = renderer.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }
}

/// The picture itself; only redrawn when its configuration changes.
struct ArtCanvas: View, Equatable {
    let config: ArtConfig

    var body: some View {
        Canvas(rendersAsynchronously: false) { ctx, size in
            ArtRenderer.draw(ctx, size: size, config: config)
        }
    }
}

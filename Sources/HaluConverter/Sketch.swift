import Foundation

// The vector model shared by the SVG, PDF and image importers and the DXF writer.
// Coordinates are millimetres with y pointing up (CAD convention) once an importer is done.

struct Vec2: Hashable {
    var x: Double
    var y: Double

    static let zero = Vec2(x: 0, y: 0)

    static func + (a: Vec2, b: Vec2) -> Vec2 { Vec2(x: a.x + b.x, y: a.y + b.y) }
    static func - (a: Vec2, b: Vec2) -> Vec2 { Vec2(x: a.x - b.x, y: a.y - b.y) }
    static func * (a: Vec2, k: Double) -> Vec2 { Vec2(x: a.x * k, y: a.y * k) }

    var length: Double { (x * x + y * y).squareRoot() }
    var normalized: Vec2 { let l = length; return l > 0 ? self * (1 / l) : .zero }
    func distance(to p: Vec2) -> Double { (self - p).length }
    func lerp(_ p: Vec2, _ t: Double) -> Vec2 { self + (p - self) * t }
}

/// A 2D affine transform, column-vector style: x' = a·x + c·y + tx, y' = b·x + d·y + ty.
struct Affine {
    var a = 1.0, b = 0.0, c = 0.0, d = 1.0, tx = 0.0, ty = 0.0

    static let identity = Affine()
    static func translate(_ x: Double, _ y: Double) -> Affine { Affine(tx: x, ty: y) }
    static func scale(_ sx: Double, _ sy: Double) -> Affine { Affine(a: sx, d: sy) }
    static func rotate(degrees: Double) -> Affine {
        let r = degrees * .pi / 180
        return Affine(a: cos(r), b: sin(r), c: -sin(r), d: cos(r))
    }

    func apply(_ p: Vec2) -> Vec2 { Vec2(x: a * p.x + c * p.y + tx, y: b * p.x + d * p.y + ty) }

    /// `self` after `inner`: the result maps p to self(inner(p)).
    func concatenating(_ inner: Affine) -> Affine {
        Affine(a: a * inner.a + c * inner.b, b: b * inner.a + d * inner.b,
               c: a * inner.c + c * inner.d, d: b * inner.c + d * inner.d,
               tx: a * inner.tx + c * inner.ty + tx, ty: b * inner.tx + d * inner.ty + ty)
    }

    /// Circles stay circles: no skew and the same scale on both axes (mirroring allowed).
    var keepsCircles: Bool {
        let sx = a * a + b * b, sy = c * c + d * d
        return abs(sx - sy) <= 1e-9 * max(sx, sy) && abs(a * c + b * d) <= 1e-9 * max(sx, sy)
    }

    var uniformScale: Double { (a * a + b * b).squareRoot() }
}

enum Segment {
    case line(Vec2)
    case cubic(Vec2, Vec2, Vec2)

    var end: Vec2 {
        switch self {
        case .line(let p): p
        case .cubic(_, _, let p): p
        }
    }
}

/// One subpath: a start point and the segments after it.
struct Contour {
    var start: Vec2
    var segments: [Segment] = []
    var closed = false
    /// Set for true circles, which the DXF writer stores as CIRCLE entities.
    var circle: (center: Vec2, radius: Double)?

    var end: Vec2 { segments.last?.end ?? start }

    func transformed(_ t: Affine) -> Contour {
        var copy = Contour(start: t.apply(start), closed: closed)
        copy.segments = segments.map { segment in
            switch segment {
            case .line(let p): .line(t.apply(p))
            case .cubic(let c1, let c2, let p): .cubic(t.apply(c1), t.apply(c2), t.apply(p))
            }
        }
        if let circle, t.keepsCircles {
            copy.circle = (t.apply(circle.center), circle.radius * t.uniformScale)
        }
        return copy
    }

    /// Closes the contour, snapping a nearly closed end onto the start so CAD sees one loop.
    mutating func close() {
        closed = true
        guard let last = segments.last else { return }
        if last.end.distance(to: start) <= 1e-7 * max(1, abs(start.x) + abs(start.y)) {
            switch last {
            case .line: segments[segments.count - 1] = .line(start)
            case .cubic(let c1, let c2, _): segments[segments.count - 1] = .cubic(c1, c2, start)
            }
        } else {
            segments.append(.line(start))
        }
    }

    /// Points along the contour, with each curve split into `steps` pieces (the start point is included once).
    func flattened(steps: Int = 8) -> [Vec2] {
        var points = [start]
        var current = start
        for segment in segments {
            switch segment {
            case .line(let p):
                points.append(p)
            case .cubic(let c1, let c2, let p):
                for i in 1...steps {
                    points.append(Self.bezier(current, c1, c2, p, Double(i) / Double(steps)))
                }
            }
            current = segment.end
        }
        return points
    }

    static func bezier(_ p0: Vec2, _ c1: Vec2, _ c2: Vec2, _ p1: Vec2, _ t: Double) -> Vec2 {
        let u = 1 - t
        return p0 * (u * u * u) + c1 * (3 * u * u * t) + c2 * (3 * u * t * t) + p1 * (t * t * t)
    }

    /// Four cubic arcs approximating an ellipse (with the circle marker when rx == ry).
    static func ellipse(cx: Double, cy: Double, rx: Double, ry: Double) -> Contour {
        let k = 0.5522847498307936
        let p = [Vec2(x: cx + rx, y: cy), Vec2(x: cx, y: cy + ry), Vec2(x: cx - rx, y: cy), Vec2(x: cx, y: cy - ry)]
        let handles = [Vec2(x: 0, y: ry * k), Vec2(x: -rx * k, y: 0), Vec2(x: 0, y: -ry * k), Vec2(x: rx * k, y: 0)]
        var contour = Contour(start: p[0])
        for i in 0..<4 {
            let next = p[(i + 1) % 4]
            contour.segments.append(.cubic(p[i] + handles[i], next - handles[(i + 1) % 4], next))
        }
        contour.closed = true
        if rx == ry { contour.circle = (Vec2(x: cx, y: cy), rx) }
        return contour
    }
}

struct RGB: Hashable {
    var r: UInt8, g: UInt8, b: UInt8
    static let black = RGB(r: 0, g: 0, b: 0)
    var hex: String { String(format: "%02X%02X%02X", r, g, b) }
}

/// Contours that share a colour; `filled` is false for stroked outlines (open centre lines).
struct SketchShape {
    var contours: [Contour]
    var color: RGB?
    var filled = true
}

struct Sketch {
    var shapes: [SketchShape] = []

    var isEmpty: Bool { shapes.allSatisfy { $0.contours.isEmpty } }

    func transformed(_ t: Affine) -> Sketch {
        Sketch(shapes: shapes.map { SketchShape(contours: $0.contours.map { $0.transformed(t) }, color: $0.color, filled: $0.filled) })
    }

    /// Bounds of all contours, using control points (close enough for placing the drawing).
    var bounds: (min: Vec2, max: Vec2)? {
        var lo = Vec2(x: .infinity, y: .infinity), hi = Vec2(x: -.infinity, y: -.infinity)
        for shape in shapes {
            for contour in shape.contours {
                for p in contour.flattened(steps: 6) {
                    lo = Vec2(x: min(lo.x, p.x), y: min(lo.y, p.y))
                    hi = Vec2(x: max(hi.x, p.x), y: max(hi.y, p.y))
                }
            }
        }
        return lo.x.isFinite ? (lo, hi) : nil
    }

    /// Moves the drawing to the origin (bottom-left corner at 0,0), optionally scaled to a width in mm.
    func placed(width: Double?) -> Sketch {
        guard let b = bounds else { return self }
        let w = b.max.x - b.min.x
        let k = (width.map { w > 0 ? $0 / w : 1 }) ?? 1
        return transformed(Affine.scale(k, k).concatenating(.translate(-b.min.x, -b.min.y)))
    }

    /// Shapes merged by colour, in first-seen order. Strokes stay apart from fills of the same colour.
    var colorGroups: [SketchShape] {
        var groups: [SketchShape] = []
        for shape in shapes where !shape.contours.isEmpty {
            if let i = groups.firstIndex(where: { $0.color == shape.color && $0.filled == shape.filled }) {
                groups[i].contours += shape.contours
            } else {
                groups.append(shape)
            }
        }
        return groups
    }

    /// Splits one colour's contours into pieces: each outer outline with the holes directly inside it.
    /// An island inside a hole is a piece of its own. Open lines are single pieces.
    static func pieces(of contours: [Contour]) -> [[Contour]] {
        let closed = contours.filter(\.closed)
        let polygons = closed.map { $0.flattened(steps: 6) }
        let areas = polygons.map { abs(signedArea($0)) }
        let boxes = polygons.map(box)

        // Parent = the smallest closed contour that contains this one.
        var parent = [Int?](repeating: nil, count: closed.count)
        for i in closed.indices {
            let probe = polygons[i][0]
            var best: Int?
            for j in closed.indices where j != i && areas[j] > areas[i] {
                guard boxes[j].contains(probe), contains(polygons[j], probe) else { continue }
                if best == nil || areas[j] < areas[best!] { best = j }
            }
            parent[i] = best
        }
        func depth(_ i: Int) -> Int {
            var d = 0, k = parent[i]
            while let p = k, d < closed.count { d += 1; k = parent[p] }
            return d
        }

        var pieces: [[Contour]] = []
        var pieceOf: [Int: Int] = [:]
        let depths = closed.indices.map(depth)
        for i in closed.indices where depths[i] % 2 == 0 {
            pieceOf[i] = pieces.count
            pieces.append([closed[i]])
        }
        for i in closed.indices where depths[i] % 2 == 1 {
            if let p = parent[i], let piece = pieceOf[p] { pieces[piece].append(closed[i]) }
        }
        pieces += contours.filter { !$0.closed }.map { [$0] }
        return pieces
    }

    static func signedArea(_ points: [Vec2]) -> Double {
        guard points.count > 2 else { return 0 }
        var sum = 0.0
        for i in points.indices {
            let p = points[i], q = points[(i + 1) % points.count]
            sum += p.x * q.y - q.x * p.y
        }
        return sum / 2
    }

    /// Even-odd point-in-polygon test.
    static func contains(_ polygon: [Vec2], _ p: Vec2) -> Bool {
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let a = polygon[i], b = polygon[j]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    private struct Box {
        var lo: Vec2, hi: Vec2
        func contains(_ p: Vec2) -> Bool { p.x >= lo.x && p.x <= hi.x && p.y >= lo.y && p.y <= hi.y }
    }

    private static func box(_ points: [Vec2]) -> Box {
        var lo = points[0], hi = points[0]
        for p in points {
            lo = Vec2(x: min(lo.x, p.x), y: min(lo.y, p.y))
            hi = Vec2(x: max(hi.x, p.x), y: max(hi.y, p.y))
        }
        return Box(lo: lo, hi: hi)
    }
}

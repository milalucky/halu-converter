import Foundation

/// RGBA pixels, 8 bits per channel, not premultiplied, rows top to bottom.
struct Bitmap {
    let width: Int
    let height: Int
    var pixels: [UInt8]
}

/// Turns a flat logo bitmap into smooth outlines (pixel coordinates, y down).
/// Steps: find the background and up to 8 logo colours, build a soft mask per colour,
/// trace it with marching squares (sub-pixel edges), simplify, then fit lines and cubic curves
/// with sharp corners kept as corners.
enum Tracer {
    /// `detail` 0…1: low = smoother curves and no specks, high = follows the pixels closely.
    static func trace(_ bitmap: Bitmap, detail: Double, separateColors: Bool) -> [SketchShape] {
        let palette = Palette(bitmap)
        guard !palette.colors.isEmpty else { return [] }
        let longest = Double(max(bitmap.width, bitmap.height))
        let scale = max(1, longest / 1000)
        let tolerance = (1.6 - 1.2 * detail) * scale
        let minArea = 6 * scale * scale + (1 - detail) * 0.00015 * Double(bitmap.width * bitmap.height)
        let cornerAngle = (50 - 20 * detail) * .pi / 180

        let groups: [(field: [Float], color: RGB)] = separateColors
            ? palette.colors.indices.map { (field: palette.field(bitmap, color: $0), color: palette.colors[$0]) }
            : [(field: palette.silhouette(bitmap), color: palette.colors[0])]

        return groups.compactMap { group -> SketchShape? in
            let loops = contours(group.field, width: bitmap.width, height: bitmap.height)
                .filter { abs(Sketch.signedArea($0)) >= minArea }
                .map { simplifyClosed($0, tolerance: tolerance) }
                .filter { $0.count >= 3 }
            let outlines = loops.map { fitCurves($0, tolerance: tolerance, cornerAngle: cornerAngle) }
            return outlines.isEmpty ? nil : SketchShape(contours: outlines, color: group.color)
        }
    }

    // MARK: - Colours

    private struct Palette {
        var colors: [RGB] = []
        var background: RGB?
        let transparent: Bool

        init(_ bitmap: Bitmap) {
            let count = bitmap.width * bitmap.height
            let px = bitmap.pixels
            var clear = 0
            for i in 0..<count where px[i * 4 + 3] < 128 { clear += 1 }
            transparent = clear > count / 100

            func key(_ i: Int) -> Int { Int(px[i] >> 4) << 8 | Int(px[i + 1] >> 4) << 4 | Int(px[i + 2] >> 4) }

            if !transparent {
                // The most common colour along the border is the background.
                var border = [Int: (n: Int, r: Int, g: Int, b: Int)]()
                func sample(_ x: Int, _ y: Int) {
                    let i = (y * bitmap.width + x) * 4
                    let e = border[key(i)] ?? (0, 0, 0, 0)
                    border[key(i)] = (e.n + 1, e.r + Int(px[i]), e.g + Int(px[i + 1]), e.b + Int(px[i + 2]))
                }
                for x in 0..<bitmap.width { sample(x, 0); sample(x, bitmap.height - 1) }
                for y in 0..<bitmap.height { sample(0, y); sample(bitmap.width - 1, y) }
                if let top = border.values.max(by: { $0.n < $1.n }) {
                    background = RGB(r: UInt8(top.r / top.n), g: UInt8(top.g / top.n), b: UInt8(top.b / top.n))
                }
            }

            // Histogram of logo pixels in 4-bit bins; the big bins become the palette.
            var bins = [Int: (n: Int, r: Int, g: Int, b: Int)]()
            var foreground = 0
            for p in 0..<count {
                let i = p * 4
                if transparent {
                    guard px[i + 3] >= 128 else { continue }
                } else if let background, Self.distance(px, i, background) < 40 {
                    continue
                }
                foreground += 1
                let e = bins[key(i)] ?? (0, 0, 0, 0)
                bins[key(i)] = (e.n + 1, e.r + Int(px[i]), e.g + Int(px[i + 1]), e.b + Int(px[i + 2]))
            }
            let minimum = max(16, foreground * 3 / 1000)
            for bin in bins.values.sorted(by: { $0.n > $1.n }) where bin.n >= minimum {
                let c = RGB(r: UInt8(bin.r / bin.n), g: UInt8(bin.g / bin.n), b: UInt8(bin.b / bin.n))
                let farFromOthers = colors.allSatisfy { Self.distance(c, $0) >= 56 }
                let farFromBackground = background.map { Self.distance(c, $0) >= 56 } ?? true
                if farFromOthers && farFromBackground { colors.append(c) }
                if colors.count == 8 { break }
            }
        }

        /// 1 where the pixel is exactly this colour, 0.5 halfway to the nearest other colour (or the background).
        func field(_ bitmap: Bitmap, color index: Int) -> [Float] {
            let target = colors[index]
            var others = colors.enumerated().filter { $0.offset != index }.map(\.element)
            if let background { others.append(background) }
            let px = bitmap.pixels
            return (0..<(bitmap.width * bitmap.height)).map { p in
                let i = p * 4
                let alpha = transparent ? Double(px[i + 3]) / 255 : 1
                guard !others.isEmpty else { return Float(alpha) }
                let own = Self.distance(px, i, target)
                var other = Double.infinity
                for c in others { other = min(other, Self.distance(px, i, c)) }
                let m = own + other > 0 ? other / (own + other) : 0.5
                return Float(m * alpha)
            }
        }

        /// Every logo colour together: one solid silhouette.
        func silhouette(_ bitmap: Bitmap) -> [Float] {
            let px = bitmap.pixels
            return (0..<(bitmap.width * bitmap.height)).map { p in
                let i = p * 4
                if transparent { return Float(px[i + 3]) / 255 }
                guard let background else { return 1 }
                let toBackground = Self.distance(px, i, background)
                var toLogo = Double.infinity
                for c in colors { toLogo = min(toLogo, Self.distance(px, i, c)) }
                return toBackground + toLogo > 0 ? Float(toBackground / (toBackground + toLogo)) : 0.5
            }
        }

        static func distance(_ a: RGB, _ b: RGB) -> Double {
            let dr = Double(a.r) - Double(b.r), dg = Double(a.g) - Double(b.g), db = Double(a.b) - Double(b.b)
            return (dr * dr + dg * dg + db * db).squareRoot()
        }

        static func distance(_ px: [UInt8], _ i: Int, _ c: RGB) -> Double {
            let dr = Double(px[i]) - Double(c.r), dg = Double(px[i + 1]) - Double(c.g), db = Double(px[i + 2]) - Double(c.b)
            return (dr * dr + dg * dg + db * db).squareRoot()
        }
    }

    // MARK: - Marching squares

    /// Closed iso-lines at 0.5 through pixel centres. The field is padded with zeros so every line closes.
    static func contours(_ field: [Float], width w: Int, height h: Int) -> [[Vec2]] {
        let W = w + 2, H = h + 2
        func value(_ x: Int, _ y: Int) -> Float {
            let fx = x - 1, fy = y - 1
            return fx >= 0 && fx < w && fy >= 0 && fy < h ? field[fy * w + fx] : 0
        }
        // Edge ids: horizontal edge from (x,y) to (x+1,y) = 2·(y·W+x), vertical edge from (x,y) to (x,y+1) = 2·(y·W+x)+1.
        var next: [Int: Int] = [:]
        var points: [Int: Vec2] = [:]
        var order: [Int] = []

        for y in 0..<(H - 1) {
            for x in 0..<(W - 1) {
                // Corners clockwise on screen: top-left, top-right, bottom-right, bottom-left.
                let v0 = value(x, y), v1 = value(x + 1, y), v2 = value(x + 1, y + 1), v3 = value(x, y + 1)
                let high = (v0 >= 0.5 ? 1 : 0) + (v1 >= 0.5 ? 1 : 0) + (v2 >= 0.5 ? 1 : 0) + (v3 >= 0.5 ? 1 : 0)
                if high == 0 || high == 4 { continue }
                let corners = [(x, y), (x + 1, y), (x + 1, y + 1), (x, y + 1)]
                let values = [v0, v1, v2, v3]
                let inside = values.map { $0 >= 0.5 }

                var crossings: [(edge: Int, exits: Bool)] = []
                for i in 0..<4 {
                    let j = (i + 1) % 4
                    guard inside[i] != inside[j] else { continue }
                    let (x0, y0) = corners[i], (x1, y1) = corners[j]
                    let edge = 2 * (min(y0, y1) * W + min(x0, x1)) + (y0 == y1 ? 0 : 1)
                    let t = Double((0.5 - values[i]) / (values[j] - values[i]))
                    // Padded grid point (x,y) is the centre of pixel (x-1,y-1), which sits at (x-0.5, y-0.5).
                    points[edge] = Vec2(x: Double(x0) + Double(x1 - x0) * t - 0.5, y: Double(y0) + Double(y1 - y0) * t - 0.5)
                    crossings.append((edge, inside[i]))
                }
                func link(_ from: Int, _ to: Int) {
                    next[from] = to
                    order.append(from)
                }
                if crossings.count == 2 {
                    let exit = crossings.first(where: { $0.exits })!.edge, enter = crossings.first(where: { !$0.exits })!.edge
                    link(exit, enter)
                } else {
                    // Saddle: the centre value decides whether the two inside corners connect.
                    let first = crossings.firstIndex(where: { !$0.exits })!
                    let s = (0..<4).map { crossings[(first + $0) % 4].edge } // enter, exit, enter, exit
                    if values.reduce(0, +) / 4 >= 0.5 {
                        link(s[1], s[2]); link(s[3], s[0])
                    } else {
                        link(s[1], s[0]); link(s[3], s[2])
                    }
                }
            }
        }

        var loops: [[Vec2]] = []
        var seen = Set<Int>()
        for start in order where !seen.contains(start) {
            var loop: [Vec2] = []
            var edge = start
            while !seen.contains(edge), let p = points[edge], let following = next[edge] {
                seen.insert(edge)
                loop.append(p)
                edge = following
            }
            if loop.count >= 3 { loops.append(loop) }
        }
        return loops
    }

    // MARK: - Simplify and fit

    /// Douglas–Peucker on a closed loop, split at the point farthest from the first one.
    static func simplifyClosed(_ points: [Vec2], tolerance: Double) -> [Vec2] {
        guard points.count > 4 else { return points }
        var far = 0, best = 0.0
        for (i, p) in points.enumerated() where p.distance(to: points[0]) > best { best = p.distance(to: points[0]); far = i }
        let first = simplify(Array(points[0...far]), tolerance: tolerance)
        let second = simplify(Array(points[far...]) + [points[0]], tolerance: tolerance)
        return Array(first.dropLast()) + Array(second.dropLast())
    }

    private static func simplify(_ points: [Vec2], tolerance: Double) -> [Vec2] {
        guard points.count > 2 else { return points }
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        var stack = [(0, points.count - 1)]
        while let (a, b) = stack.popLast() {
            guard b > a + 1 else { continue }
            var index = a, worst = 0.0
            for i in (a + 1)..<b {
                let d = distance(points[i], toSegment: points[a], points[b])
                if d > worst { worst = d; index = i }
            }
            if worst > tolerance {
                keep[index] = true
                stack.append((a, index))
                stack.append((index, b))
            }
        }
        return points.indices.filter { keep[$0] }.map { points[$0] }
    }

    private static func distance(_ p: Vec2, toSegment a: Vec2, _ b: Vec2) -> Double {
        let ab = b - a
        let len2 = ab.x * ab.x + ab.y * ab.y
        guard len2 > 0 else { return p.distance(to: a) }
        let t = max(0, min(1, ((p.x - a.x) * ab.x + (p.y - a.y) * ab.y) / len2))
        return p.distance(to: a + ab * t)
    }

    /// A closed polygon → lines between corners and long straight runs, smooth cubics elsewhere.
    static func fitCurves(_ p: [Vec2], tolerance: Double, cornerAngle: Double) -> Contour {
        let n = p.count
        func at(_ i: Int) -> Vec2 { p[(i % n + n) % n] }
        let length = (0..<n).map { at($0).distance(to: at($0 + 1)) }
        let direction = (0..<n).map { (at($0 + 1) - at($0)).normalized }
        func len(_ i: Int) -> Double { length[(i % n + n) % n] }
        func dir(_ i: Int) -> Vec2 { direction[(i % n + n) % n] }

        let corner = (0..<n).map { i -> Bool in
            let a = dir(i - 1), b = dir(i)
            return acos(max(-1, min(1, a.x * b.x + a.y * b.y))) > cornerAngle
        }
        func isCorner(_ i: Int) -> Bool { corner[(i % n + n) % n] }
        let straight = (0..<n).map { i -> Bool in
            (isCorner(i) && isCorner(i + 1)) || (len(i) > 3 * max(len(i - 1), len(i + 1)) && len(i) > 12 * tolerance)
        }
        func isStraight(_ i: Int) -> Bool { straight[(i % n + n) % n] }
        func tangent(_ i: Int) -> Vec2 {
            if isStraight(i - 1) { return dir(i - 1) }
            if isStraight(i) { return dir(i) }
            return (at(i + 1) - at(i - 1)).normalized
        }

        var contour = Contour(start: p[0])
        for i in 0..<n {
            let end = i == n - 1 ? p[0] : p[i + 1]
            if isStraight(i) {
                contour.segments.append(.line(end))
            } else {
                let handle = len(i) / 3
                let t0 = isCorner(i) ? dir(i) : tangent(i)
                let t1 = isCorner(i + 1) ? dir(i) : tangent(i + 1)
                contour.segments.append(.cubic(at(i) + t0 * handle, end - t1 * handle, end))
            }
        }
        contour.closed = true
        return contour
    }
}

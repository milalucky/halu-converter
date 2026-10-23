import Foundation

/// Reads the filled and stroked shapes of an SVG into a Sketch (mm, y up).
/// Handles paths (all commands, arcs included), basic shapes, groups, transforms, <use>,
/// presentation attributes, inline styles and simple CSS class rules (Illustrator, Figma, Inkscape exports).
/// Text that wasn't converted to outlines and embedded bitmaps are skipped.
enum SVGImporter {
    struct Result {
        var sketch: Sketch
        var skippedText: Int
    }

    static func read(_ data: Data) throws -> Result {
        let builder = TreeBuilder()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = builder
        guard parser.parse() || builder.root != nil, let root = builder.root, root.name == "svg" else {
            throw HaluError.failed("This SVG can't be read.")
        }
        var renderer = Renderer(root: root)
        renderer.render()
        return Result(sketch: renderer.sketch, skippedText: renderer.skippedText)
    }
}

// MARK: - XML tree

private final class Node {
    let name: String
    let attributes: [String: String]
    var children: [Node] = []
    var text = ""

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    subscript(_ key: String) -> String? { attributes[key] }
}

private final class TreeBuilder: NSObject, XMLParserDelegate {
    var root: Node?
    private var stack: [Node] = []

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        var attributes: [String: String] = [:]
        for (key, value) in attributeDict {
            // "xlink:href" and "href" mean the same; other prefixes (sodipodi:, inkscape:) are kept as is.
            attributes[key == "xlink:href" ? "href" : key] = value
        }
        let node = Node(name: elementName.split(separator: ":").last.map(String.init) ?? elementName, attributes: attributes)
        if let parent = stack.last { parent.children.append(node) } else if root == nil { root = node }
        stack.append(node)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        _ = stack.popLast()
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        stack.last?.text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        stack.last?.text += String(decoding: CDATABlock, as: UTF8.self)
    }
}

// MARK: - Styles

private enum Paint {
    case none, color(RGB), current, url(String)
}

private struct Style {
    var fill: Paint = .color(.black)
    var stroke: Paint = .none
    var color: RGB = .black
    var fillOpacity = 1.0
    var visible = true
}

private struct CSSRule {
    var tag: String?
    var id: String?
    var classes: [String]
    var declarations: [String: String]

    func matches(_ node: Node) -> Bool {
        if let tag, tag != node.name { return false }
        if let id, id != node["id"] { return false }
        let own = Set((node["class"] ?? "").split(whereSeparator: \.isWhitespace).map(String.init))
        return classes.allSatisfy(own.contains)
    }

    static func parse(_ css: String) -> [CSSRule] {
        let text = css.replacingOccurrences(of: #"/\*[\s\S]*?\*/"#, with: "", options: .regularExpression)
        var rules: [CSSRule] = []
        for block in text.components(separatedBy: "}") {
            let parts = block.components(separatedBy: "{")
            guard parts.count == 2 else { continue }
            let declarations = SVGStyleText.declarations(parts[1])
            for selector in parts[0].components(separatedBy: ",") {
                let s = selector.trimmingCharacters(in: .whitespacesAndNewlines)
                // Only simple selectors: tag, .class, #id and their combinations.
                guard !s.isEmpty, !s.hasPrefix("@"), s.rangeOfCharacter(from: CharacterSet(charactersIn: " >+~[:*")) == nil else { continue }
                var rule = CSSRule(tag: nil, id: nil, classes: [], declarations: declarations)
                var current = "", kind: Character = "t"
                func flush() {
                    guard !current.isEmpty else { return }
                    switch kind {
                    case ".": rule.classes.append(current)
                    case "#": rule.id = current
                    default: rule.tag = current
                    }
                    current = ""
                }
                for ch in s {
                    if ch == "." || ch == "#" { flush(); kind = ch } else { current.append(ch) }
                }
                flush()
                rules.append(rule)
            }
        }
        return rules
    }
}

private enum SVGStyleText {
    static func declarations(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for item in text.components(separatedBy: ";") {
            guard let colon = item.firstIndex(of: ":") else { continue }
            let key = item[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = item[item.index(after: colon)...]
                .replacingOccurrences(of: "!important", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty { result[key] = value }
        }
        return result
    }

    static func paint(_ value: String) -> Paint? {
        let v = value.trimmingCharacters(in: .whitespaces)
        let lower = v.lowercased()
        if lower == "inherit" || lower.isEmpty { return nil }
        if lower == "none" || lower == "transparent" { return Paint.none }
        if lower == "currentcolor" { return .current }
        if lower.hasPrefix("url(") {
            let inner = v.dropFirst(4).prefix { $0 != ")" }
            let id = inner.trimmingCharacters(in: CharacterSet(charactersIn: " '\"")).drop { $0 == "#" }
            return .url(String(id))
        }
        return color(lower).map(Paint.color)
    }

    static func color(_ lower: String) -> RGB? {
        if lower.hasPrefix("#") {
            let hex = Array(lower.dropFirst())
            func byte(_ s: String) -> UInt8? { UInt8(s, radix: 16) }
            switch hex.count {
            case 3, 4:
                guard let r = byte(String([hex[0], hex[0]])), let g = byte(String([hex[1], hex[1]])),
                      let b = byte(String([hex[2], hex[2]])) else { return nil }
                return RGB(r: r, g: g, b: b)
            case 6, 8:
                guard let r = byte(String(hex[0...1])), let g = byte(String(hex[2...3])), let b = byte(String(hex[4...5])) else { return nil }
                return RGB(r: r, g: g, b: b)
            default:
                return nil
            }
        }
        if lower.hasPrefix("rgb") {
            guard let open = lower.firstIndex(of: "("), let close = lower.firstIndex(of: ")") else { return nil }
            let parts = lower[lower.index(after: open)..<close]
                .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" })
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 3 else { return nil }
            func channel(_ s: String) -> UInt8 {
                let value = s.hasSuffix("%") ? (Double(s.dropLast()) ?? 0) * 2.55 : (Double(s) ?? 0)
                return UInt8(max(0, min(255, value.rounded())))
            }
            return RGB(r: channel(parts[0]), g: channel(parts[1]), b: channel(parts[2]))
        }
        return named[lower]
    }

    static let named: [String: RGB] = [
        "black": RGB(r: 0, g: 0, b: 0), "white": RGB(r: 255, g: 255, b: 255), "red": RGB(r: 255, g: 0, b: 0),
        "green": RGB(r: 0, g: 128, b: 0), "lime": RGB(r: 0, g: 255, b: 0), "blue": RGB(r: 0, g: 0, b: 255),
        "yellow": RGB(r: 255, g: 255, b: 0), "orange": RGB(r: 255, g: 165, b: 0), "purple": RGB(r: 128, g: 0, b: 128),
        "gray": RGB(r: 128, g: 128, b: 128), "grey": RGB(r: 128, g: 128, b: 128), "silver": RGB(r: 192, g: 192, b: 192),
        "navy": RGB(r: 0, g: 0, b: 128), "teal": RGB(r: 0, g: 128, b: 128), "maroon": RGB(r: 128, g: 0, b: 0),
        "olive": RGB(r: 128, g: 128, b: 0), "aqua": RGB(r: 0, g: 255, b: 255), "cyan": RGB(r: 0, g: 255, b: 255),
        "fuchsia": RGB(r: 255, g: 0, b: 255), "magenta": RGB(r: 255, g: 0, b: 255), "pink": RGB(r: 255, g: 192, b: 203),
        "brown": RGB(r: 165, g: 42, b: 42), "gold": RGB(r: 255, g: 215, b: 0), "darkgray": RGB(r: 169, g: 169, b: 169),
        "lightgray": RGB(r: 211, g: 211, b: 211),
    ]
}

// MARK: - Rendering

private struct Renderer {
    let root: Node
    var sketch = Sketch()
    var skippedText = 0
    private var rules: [CSSRule] = []
    private var byID: [String: Node] = [:]

    private static let styleKeys: Set<String> = ["fill", "stroke", "color", "fill-opacity", "opacity", "display", "visibility"]
    private static let skipped: Set<String> = ["defs", "clipPath", "mask", "pattern", "marker", "linearGradient", "radialGradient",
                                               "title", "desc", "metadata", "style", "script", "filter", "symbol", "foreignObject",
                                               "image", "namedview"]

    init(root: Node) {
        self.root = root
        index(root)
    }

    private mutating func index(_ node: Node) {
        if let id = node["id"] { byID[id] = node }
        if node.name == "style" { rules += CSSRule.parse(node.text) }
        for child in node.children { index(child) }
    }

    mutating func render() {
        walk(root, ctm: rootTransform(), parent: Style(), depth: 0)
    }

    /// Maps user units to millimetres with y flipped: viewBox → width/height (default 96 px per inch).
    private func rootTransform() -> Affine {
        let pxToMM = 25.4 / 96
        let width = root["width"].flatMap(Self.millimetres)
        let height = root["height"].flatMap(Self.millimetres)
        let box = (root["viewBox"] ?? root["viewbox"]).map(Self.numbers) ?? []
        guard box.count == 4, box[2] > 0, box[3] > 0 else { return .scale(pxToMM, -pxToMM) }
        let w = width ?? (height.map { $0 * box[2] / box[3] } ?? box[2] * pxToMM)
        let h = height ?? (width.map { $0 * box[3] / box[2] } ?? box[3] * pxToMM)
        let k = min(w / box[2], h / box[3])
        return Affine.scale(k, -k).concatenating(.translate(-box[0], -box[1]))
    }

    private mutating func walkChildren(of node: Node, ctm: Affine, style: Style, depth: Int) {
        for child in node.children { walk(child, ctm: ctm, parent: style, depth: depth) }
    }

    private mutating func walk(_ node: Node, ctm parentCTM: Affine, parent: Style, depth: Int) {
        guard depth < 64, !Self.skipped.contains(node.name) else { return }
        let declarations = resolvedDeclarations(node)
        if declarations["display"] == "none" { return }
        if let opacity = declarations["opacity"].flatMap(Double.init), opacity <= 0 { return }
        let style = apply(declarations, to: parent)
        var ctm = parentCTM
        if let transform = node["transform"] { ctm = ctm.concatenating(Self.transform(transform)) }

        switch node.name {
        case "svg", "g", "a", "switch":
            if node !== root, node.name == "svg" {
                ctm = ctm.concatenating(.translate(length(node["x"]), length(node["y"])))
            }
            walkChildren(of: node, ctm: ctm, style: style, depth: depth + 1)
        case "use":
            guard let href = node["href"], href.hasPrefix("#"), let target = byID[String(href.dropFirst())] else { return }
            ctm = ctm.concatenating(.translate(length(node["x"]), length(node["y"])))
            if target.name == "symbol" {
                walkChildren(of: target, ctm: ctm, style: apply(resolvedDeclarations(target), to: style), depth: depth + 1)
            } else {
                walk(target, ctm: ctm, parent: style, depth: depth + 1)
            }
        case "text", "tspan", "textPath":
            skippedText += 1
        default:
            let contours = geometry(node)
            guard !contours.isEmpty, style.visible else { return }
            emit(contours, ctm: ctm, style: style)
        }
    }

    private func resolvedDeclarations(_ node: Node) -> [String: String] {
        var result: [String: String] = [:]
        for key in Self.styleKeys { if let value = node[key] { result[key] = value } }
        for rule in rules where rule.matches(node) {
            result.merge(rule.declarations) { _, new in new }
        }
        if let inline = node["style"] {
            result.merge(SVGStyleText.declarations(inline)) { _, new in new }
        }
        return result
    }

    private func apply(_ d: [String: String], to parent: Style) -> Style {
        var style = parent
        if let value = d["color"], let color = SVGStyleText.color(value.lowercased()) { style.color = color }
        if let value = d["fill"], let paint = SVGStyleText.paint(value) { style.fill = paint }
        if let value = d["stroke"], let paint = SVGStyleText.paint(value) { style.stroke = paint }
        if let value = d["fill-opacity"].flatMap(Double.init) { style.fillOpacity = value }
        if let value = d["visibility"] { style.visible = value != "hidden" && value != "collapse" }
        return style
    }

    private func color(of paint: Paint, style: Style) -> RGB? {
        switch paint {
        case .none: return nil
        case .color(let c): return c
        case .current: return style.color
        case .url(let id): return gradientColor(id, hops: 0)
        }
    }

    /// A gradient or pattern fill becomes the colour of its first stop.
    private func gradientColor(_ id: String, hops: Int) -> RGB? {
        guard let node = byID[id] else { return .black }
        if let stop = node.children.first(where: { $0.name == "stop" }) {
            let d = stop["style"].map(SVGStyleText.declarations) ?? [:]
            return (d["stop-color"] ?? stop["stop-color"]).flatMap { SVGStyleText.color($0.lowercased()) } ?? .black
        }
        if hops < 4, let href = node["href"], href.hasPrefix("#") { return gradientColor(String(href.dropFirst()), hops: hops + 1) }
        return .black
    }

    private mutating func emit(_ contours: [Contour], ctm: Affine, style: Style) {
        if style.fillOpacity > 0, let fill = color(of: style.fill, style: style) {
            let closed = contours.filter { !$0.segments.isEmpty }.map { contour -> Contour in
                var c = contour
                if !c.closed { c.close() }
                return c.transformed(ctm)
            }
            if !closed.isEmpty { sketch.shapes.append(SketchShape(contours: closed, color: fill)) }
        } else if let stroke = color(of: style.stroke, style: style) {
            let lines = contours.filter { !$0.segments.isEmpty }.map { $0.transformed(ctm) }
            if !lines.isEmpty { sketch.shapes.append(SketchShape(contours: lines, color: stroke, filled: false)) }
        }
    }

    // MARK: Geometry

    private func geometry(_ node: Node) -> [Contour] {
        switch node.name {
        case "path":
            return PathData.parse(node["d"] ?? "")
        case "rect":
            let x = length(node["x"]), y = length(node["y"])
            let w = length(node["width"]), h = length(node["height"])
            guard w > 0, h > 0 else { return [] }
            var rx = node["rx"].map { length($0) }, ry = node["ry"].map { length($0) }
            rx = rx ?? ry
            ry = ry ?? rx
            let cx = min(max(rx ?? 0, 0), w / 2), cy = min(max(ry ?? 0, 0), h / 2)
            return [Self.rectangle(x: x, y: y, w: w, h: h, rx: cx, ry: cy)]
        case "circle":
            let r = length(node["r"])
            guard r > 0 else { return [] }
            return [Contour.ellipse(cx: length(node["cx"]), cy: length(node["cy"]), rx: r, ry: r)]
        case "ellipse":
            let rx = node["rx"].map { length($0) }, ry = node["ry"].map { length($0) }
            guard let a = rx ?? ry, let b = ry ?? rx, a > 0, b > 0 else { return [] }
            return [Contour.ellipse(cx: length(node["cx"]), cy: length(node["cy"]), rx: a, ry: b)]
        case "line":
            let a = Vec2(x: length(node["x1"]), y: length(node["y1"])), b = Vec2(x: length(node["x2"]), y: length(node["y2"]))
            return a == b ? [] : [Contour(start: a, segments: [.line(b)])]
        case "polyline", "polygon":
            let n = Self.numbers(node["points"] ?? "")
            guard n.count >= 4 else { return [] }
            var contour = Contour(start: Vec2(x: n[0], y: n[1]))
            for i in stride(from: 2, to: n.count - 1, by: 2) { contour.segments.append(.line(Vec2(x: n[i], y: n[i + 1]))) }
            if node.name == "polygon" { contour.close() }
            return [contour]
        default:
            return []
        }
    }

    private static func rectangle(x: Double, y: Double, w: Double, h: Double, rx: Double, ry: Double) -> Contour {
        guard rx > 0, ry > 0 else {
            var c = Contour(start: Vec2(x: x, y: y), segments: [.line(Vec2(x: x + w, y: y)), .line(Vec2(x: x + w, y: y + h)), .line(Vec2(x: x, y: y + h))])
            c.close()
            return c
        }
        let k = 0.5522847498307936
        let kx = rx * k, ky = ry * k
        var c = Contour(start: Vec2(x: x + rx, y: y))
        func corner(_ c1: Vec2, _ c2: Vec2, _ p: Vec2) { c.segments.append(.cubic(c1, c2, p)) }
        func line(_ p: Vec2) { if p != c.end { c.segments.append(.line(p)) } }
        line(Vec2(x: x + w - rx, y: y))
        corner(Vec2(x: x + w - rx + kx, y: y), Vec2(x: x + w, y: y + ry - ky), Vec2(x: x + w, y: y + ry))
        line(Vec2(x: x + w, y: y + h - ry))
        corner(Vec2(x: x + w, y: y + h - ry + ky), Vec2(x: x + w - rx + kx, y: y + h), Vec2(x: x + w - rx, y: y + h))
        line(Vec2(x: x + rx, y: y + h))
        corner(Vec2(x: x + rx - kx, y: y + h), Vec2(x: x, y: y + h - ry + ky), Vec2(x: x, y: y + h - ry))
        line(Vec2(x: x, y: y + ry))
        corner(Vec2(x: x, y: y + ry - ky), Vec2(x: x + rx - kx, y: y), Vec2(x: x + rx, y: y))
        c.closed = true
        return c
    }

    /// A length in user units (px). Percentages resolve against the viewBox width.
    private func length(_ value: String?) -> Double {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return 0 }
        if value.hasSuffix("%") {
            let box = (root["viewBox"] ?? root["viewbox"]).map(Self.numbers) ?? []
            return (Double(value.dropLast()) ?? 0) / 100 * (box.count == 4 ? box[2] : 0)
        }
        guard let mm = Self.millimetres(value) else { return 0 }
        return mm * 96 / 25.4
    }

    /// "12mm", "3in", "40px", "40" → millimetres (nil for percentages and garbage).
    static func millimetres(_ value: String) -> Double? {
        let v = value.trimmingCharacters(in: .whitespaces).lowercased()
        let units: [(String, Double)] = [("mm", 1), ("cm", 10), ("in", 25.4), ("pt", 25.4 / 72), ("pc", 25.4 / 6),
                                         ("px", 25.4 / 96), ("em", 16 * 25.4 / 96), ("ex", 8 * 25.4 / 96)]
        if v.hasSuffix("%") { return nil }
        for (unit, factor) in units where v.hasSuffix(unit) {
            return Double(v.dropLast(unit.count).trimmingCharacters(in: .whitespaces)).map { $0 * factor }
        }
        return Double(v).map { $0 * 25.4 / 96 }
    }

    static func numbers(_ text: String) -> [Double] {
        var scanner = NumberScanner(text)
        var result: [Double] = []
        while let n = scanner.number() { result.append(n) }
        return result
    }

    /// "translate(10 20) rotate(45) scale(2)" → one matrix, applied right to left like SVG does.
    static func transform(_ text: String) -> Affine {
        var result = Affine.identity
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "("), let close = rest[open...].firstIndex(of: ")") {
            let name = rest[..<open].trimmingCharacters(in: CharacterSet(charactersIn: " ,\t\n\r")).lowercased()
            let n = numbers(String(rest[rest.index(after: open)..<close]))
            rest = rest[rest.index(after: close)...]
            var m = Affine.identity
            switch name {
            case "matrix" where n.count >= 6:
                m = Affine(a: n[0], b: n[1], c: n[2], d: n[3], tx: n[4], ty: n[5])
            case "translate" where !n.isEmpty:
                m = .translate(n[0], n.count > 1 ? n[1] : 0)
            case "scale" where !n.isEmpty:
                m = .scale(n[0], n.count > 1 ? n[1] : n[0])
            case "rotate" where !n.isEmpty:
                m = .rotate(degrees: n[0])
                if n.count >= 3 {
                    m = Affine.translate(n[1], n[2]).concatenating(m).concatenating(.translate(-n[1], -n[2]))
                }
            case "skewx" where !n.isEmpty:
                m = Affine(c: tan(n[0] * .pi / 180))
            case "skewy" where !n.isEmpty:
                m = Affine(b: tan(n[0] * .pi / 180))
            default:
                break
            }
            result = result.concatenating(m)
        }
        return result
    }
}

// MARK: - Path data

private struct NumberScanner {
    private let s: [UInt8]
    private var i = 0

    init(_ text: String) { s = Array(text.utf8) }

    private static func isDigit(_ c: UInt8) -> Bool { c >= 48 && c <= 57 }

    mutating func skipSeparators() {
        while i < s.count, s[i] == 32 || s[i] == 9 || s[i] == 10 || s[i] == 13 || s[i] == 44 { i += 1 }
    }

    /// The next command letter, if the next token is one.
    mutating func command() -> UInt8? {
        skipSeparators()
        guard i < s.count else { return nil }
        let c = s[i] | 0x20
        guard c >= 97, c <= 122, c != 101 else { return nil }
        i += 1
        return s[i - 1]
    }

    mutating func hasNumber() -> Bool {
        skipSeparators()
        guard i < s.count else { return false }
        let c = s[i]
        return Self.isDigit(c) || c == 45 || c == 43 || c == 46
    }

    mutating func number() -> Double? {
        skipSeparators()
        let start = i
        if i < s.count, s[i] == 45 || s[i] == 43 { i += 1 }
        var digits = false
        while i < s.count, Self.isDigit(s[i]) { i += 1; digits = true }
        if i < s.count, s[i] == 46 {
            i += 1
            while i < s.count, Self.isDigit(s[i]) { i += 1; digits = true }
        }
        guard digits else { i = start; return nil }
        if i < s.count, s[i] == 101 || s[i] == 69 {
            let mark = i
            i += 1
            if i < s.count, s[i] == 45 || s[i] == 43 { i += 1 }
            if i < s.count, Self.isDigit(s[i]) {
                while i < s.count, Self.isDigit(s[i]) { i += 1 }
            } else {
                i = mark
            }
        }
        return Double(String(decoding: s[start..<i], as: UTF8.self))
    }

    /// Arc flags may be written without separators ("a1 1 0 01 10 10").
    mutating func flag() -> Bool? {
        skipSeparators()
        guard i < s.count, s[i] == 48 || s[i] == 49 else { return nil }
        i += 1
        return s[i - 1] == 49
    }
}

private enum PathData {
    static func parse(_ d: String) -> [Contour] {
        var scanner = NumberScanner(d)
        var contours: [Contour] = []
        var current: Contour?
        var pen = Vec2.zero, subpathStart = Vec2.zero
        var lastCubic: Vec2?, lastQuad: Vec2?

        func finish() {
            if let c = current, !c.segments.isEmpty { contours.append(c) }
            current = nil
        }
        func ensure() { if current == nil { current = Contour(start: pen) } }
        func add(_ segment: Segment) {
            ensure()
            if case .line(let p) = segment, p == pen { return }
            current!.segments.append(segment)
            pen = segment.end
        }
        func point(_ relative: Bool) -> Vec2? {
            guard let x = scanner.number(), let y = scanner.number() else { return nil }
            return relative ? pen + Vec2(x: x, y: y) : Vec2(x: x, y: y)
        }

        commands: while let letter = scanner.command() {
            var command = letter
            repeat {
                let relative = command >= 97
                var cubicControl: Vec2?, quadControl: Vec2?
                switch command | 0x20 {
                case 109: // m
                    guard let p = point(relative) else { break commands }
                    finish()
                    pen = p
                    subpathStart = p
                    current = Contour(start: p)
                    command = relative ? 108 : 76 // further pairs are lineto
                case 108: // l
                    guard let p = point(relative) else { break commands }
                    add(.line(p))
                case 104: // h
                    guard let x = scanner.number() else { break commands }
                    add(.line(Vec2(x: relative ? pen.x + x : x, y: pen.y)))
                case 118: // v
                    guard let y = scanner.number() else { break commands }
                    add(.line(Vec2(x: pen.x, y: relative ? pen.y + y : y)))
                case 99: // c
                    guard let c1 = point(relative), let c2 = point(relative), let p = point(relative) else { break commands }
                    add(.cubic(c1, c2, p))
                    cubicControl = c2
                case 115: // s
                    let reflected = lastCubic.map { pen * 2 - $0 } ?? pen
                    guard let c2 = point(relative), let p = point(relative) else { break commands }
                    add(.cubic(reflected, c2, p))
                    cubicControl = c2
                case 113: // q
                    let start = pen
                    guard let q = point(relative), let p = point(relative) else { break commands }
                    add(quadratic(start, q, p))
                    quadControl = q
                case 116: // t
                    let start = pen
                    let q = lastQuad.map { pen * 2 - $0 } ?? pen
                    guard let p = point(relative) else { break commands }
                    add(quadratic(start, q, p))
                    quadControl = q
                case 97: // a
                    let start = pen
                    guard let rx = scanner.number(), let ry = scanner.number(), let angle = scanner.number(),
                          let large = scanner.flag(), let sweep = scanner.flag(), let p = point(relative) else { break commands }
                    for segment in arc(from: start, rx: rx, ry: ry, angle: angle, large: large, sweep: sweep, to: p) { add(segment) }
                    pen = p
                case 122: // z
                    if current != nil {
                        current!.close()
                        contours.append(current!)
                        current = nil
                    }
                    pen = subpathStart
                default:
                    break commands
                }
                lastCubic = cubicControl
                lastQuad = quadControl
            } while command | 0x20 != 122 && scanner.hasNumber()
        }
        finish()
        return contours
    }

    private static func quadratic(_ p0: Vec2, _ q: Vec2, _ p: Vec2) -> Segment {
        .cubic(p0 + (q - p0) * (2.0 / 3), p + (q - p) * (2.0 / 3), p)
    }

    /// SVG's endpoint arc as cubic Béziers, at most a quarter turn each (SVG spec F.6.5).
    private static func arc(from p0: Vec2, rx: Double, ry: Double, angle: Double, large: Bool, sweep: Bool, to p: Vec2) -> [Segment] {
        if p0 == p { return [] }
        var rx = abs(rx), ry = abs(ry)
        if rx == 0 || ry == 0 { return [.line(p)] }
        let phi = angle * .pi / 180, cosPhi = cos(phi), sinPhi = sin(phi)
        let dx = (p0.x - p.x) / 2, dy = (p0.y - p.y) / 2
        let x1 = cosPhi * dx + sinPhi * dy, y1 = -sinPhi * dx + cosPhi * dy
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 { rx *= lambda.squareRoot(); ry *= lambda.squareRoot() }
        let num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let den = rx * rx * y1 * y1 + ry * ry * x1 * x1
        let coef = (den > 0 ? max(0, num / den).squareRoot() : 0) * (large == sweep ? -1 : 1)
        let cxp = coef * rx * y1 / ry, cyp = -coef * ry * x1 / rx
        let cx = cosPhi * cxp - sinPhi * cyp + (p0.x + p.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (p0.y + p.y) / 2

        func angleBetween(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
            atan2(ux * vy - uy * vx, ux * vx + uy * vy)
        }
        let ux = (x1 - cxp) / rx, uy = (y1 - cyp) / ry
        let vx = (-x1 - cxp) / rx, vy = (-y1 - cyp) / ry
        let theta = angleBetween(1, 0, ux, uy)
        var delta = angleBetween(ux, uy, vx, vy)
        if !sweep && delta > 0 { delta -= 2 * .pi }
        if sweep && delta < 0 { delta += 2 * .pi }

        let count = max(1, Int((abs(delta) / (.pi / 2) - 1e-9).rounded(.up)))
        let step = delta / Double(count)
        let t = 4.0 / 3 * tan(step / 4)
        func at(_ a: Double) -> Vec2 {
            Vec2(x: cx + rx * cos(a) * cosPhi - ry * sin(a) * sinPhi, y: cy + rx * cos(a) * sinPhi + ry * sin(a) * cosPhi)
        }
        func derivative(_ a: Double) -> Vec2 {
            Vec2(x: -rx * sin(a) * cosPhi - ry * cos(a) * sinPhi, y: -rx * sin(a) * sinPhi + ry * cos(a) * cosPhi)
        }
        var segments: [Segment] = []
        for i in 0..<count {
            let a1 = theta + Double(i) * step, a2 = a1 + step
            let end = i == count - 1 ? p : at(a2)
            segments.append(.cubic(at(a1) + derivative(a1) * t, at(a2) - derivative(a2) * t, end))
        }
        return segments
    }
}

import Foundation

enum DXFCurveStyle: String, CaseIterable, Identifiable {
    case smooth, polylines
    var id: String { rawValue }
    var label: String { self == .smooth ? "Smooth curves" : "Polylines" }
}

/// Writes an AutoCAD 2000 (AC1015) DXF in millimetres: lines as LINE, curves as cubic SPLINEs
/// (or flattened LWPOLYLINEs), true circles as CIRCLE. Every layer is one colour of the drawing.
/// Shapr3D, Fusion, Onshape and other CAD apps read it as an editable sketch.
struct DXFWriter {
    struct Layer {
        var name: String
        var contours: [Contour]
    }

    var curves: DXFCurveStyle = .smooth

    func data(layers: [Layer]) -> Data {
        var tables = Groups(), blocks = Groups(), entities = Groups(), objects = Groups()
        var handle = 0x10
        func next() -> String { handle += 1; return String(handle, radix: 16, uppercase: true) }

        var extMin = Vec2(x: .infinity, y: .infinity), extMax = Vec2(x: -.infinity, y: -.infinity)
        for p in layers.flatMap({ $0.contours.flatMap { $0.flattened(steps: 4) } }) {
            extMin = Vec2(x: min(extMin.x, p.x), y: min(extMin.y, p.y))
            extMax = Vec2(x: max(extMax.x, p.x), y: max(extMax.y, p.y))
        }
        if !extMin.x.isFinite { extMin = .zero; extMax = .zero }

        // Tables
        func table(_ name: String, _ records: [[(Int, String)]]) -> [String] {
            let tableHandle = next()
            tables.add(0, "TABLE"); tables.add(2, name); tables.add(5, tableHandle); tables.add(330, "0")
            tables.add(100, "AcDbSymbolTable"); tables.add(70, "\(records.count)")
            if name == "DIMSTYLE" { tables.add(100, "AcDbDimStyleTable"); tables.add(71, "\(records.count)") }
            var handles: [String] = []
            for record in records {
                let h = next()
                handles.append(h)
                tables.add(0, name); tables.add(name == "DIMSTYLE" ? 105 : 5, h); tables.add(330, tableHandle)
                tables.add(100, "AcDbSymbolTableRecord")
                for (code, value) in record { tables.add(code, value) }
            }
            tables.add(0, "ENDTAB")
            return handles
        }

        let height = max(extMax.y - extMin.y, 1) * 1.2
        let vport: [(Int, String)] = [(100, "AcDbViewportTableRecord"), (2, "*ACTIVE"), (70, "0"), (10, "0"), (20, "0"), (11, "1"), (21, "1"),
            (12, num((extMin.x + extMax.x) / 2)), (22, num((extMin.y + extMax.y) / 2)), (13, "0"), (23, "0"),
            (14, "10"), (24, "10"), (15, "10"), (25, "10"), (16, "0"), (26, "0"), (36, "1"), (17, "0"), (27, "0"),
            (37, "0"), (40, num(height)), (41, "1.5"), (42, "50"), (43, "0"), (44, "0"), (50, "0"), (51, "0"),
            (71, "0"), (72, "100"), (73, "1"), (74, "3"), (75, "0"), (76, "0"), (77, "0"), (78, "0")]
        _ = table("VPORT", [vport])
        let linetype = { (name: String, description: String) -> [(Int, String)] in
            [(100, "AcDbLinetypeTableRecord"), (2, name), (70, "0"), (3, description), (72, "65"), (73, "0"), (40, "0")]
        }
        _ = table("LTYPE", [linetype("ByBlock", ""), linetype("ByLayer", ""), linetype("Continuous", "Solid line")])
        _ = table("LAYER", (["0"] + layers.map(\.name)).map { name -> [(Int, String)] in
            [(100, "AcDbLayerTableRecord"), (2, name), (70, "0"), (62, "7"), (6, "Continuous")]
        })
        _ = table("STYLE", [[(100, "AcDbTextStyleTableRecord"), (2, "Standard"), (70, "0"), (40, "0"), (41, "1"), (50, "0"),
            (71, "0"), (42, "2.5"), (3, "txt"), (4, "")]])
        _ = table("VIEW", [])
        _ = table("UCS", [])
        _ = table("APPID", [[(100, "AcDbRegAppTableRecord"), (2, "ACAD"), (70, "0")]])
        _ = table("DIMSTYLE", [[(100, "AcDbDimStyleTableRecord"), (2, "Standard"), (70, "0")]])
        let spaces = ["*Model_Space", "*Paper_Space"]
        let records = table("BLOCK_RECORD", spaces.map { space -> [(Int, String)] in [(100, "AcDbBlockTableRecord"), (2, space)] })
        let modelSpace = records[0]

        // Blocks
        for (space, owner) in zip(spaces, records) {
            let paper = space == "*Paper_Space"
            blocks.add(0, "BLOCK"); blocks.add(5, next()); blocks.add(330, owner); blocks.add(100, "AcDbEntity")
            if paper { blocks.add(67, "1") }
            blocks.add(8, "0"); blocks.add(100, "AcDbBlockBegin"); blocks.add(2, space); blocks.add(70, "0")
            blocks.add(10, "0"); blocks.add(20, "0"); blocks.add(30, "0"); blocks.add(3, space); blocks.add(1, "")
            blocks.add(0, "ENDBLK"); blocks.add(5, next()); blocks.add(330, owner); blocks.add(100, "AcDbEntity")
            if paper { blocks.add(67, "1") }
            blocks.add(8, "0"); blocks.add(100, "AcDbBlockEnd")
        }

        // Entities
        func begin(_ type: String, _ layer: String) {
            entities.add(0, type); entities.add(5, next()); entities.add(330, modelSpace)
            entities.add(100, "AcDbEntity"); entities.add(8, layer)
        }
        func point(_ p: Vec2, _ code: Int = 10) {
            entities.add(code, num(p.x)); entities.add(code + 10, num(p.y)); entities.add(code + 20, "0")
        }
        func line(_ a: Vec2, _ b: Vec2, _ layer: String) {
            guard a != b else { return }
            begin("LINE", layer); entities.add(100, "AcDbLine"); point(a, 10); point(b, 11)
        }
        func spline(_ points: [Vec2], _ layer: String) {
            // A chain of cubic Béziers is a degree-3 B-spline whose inner knots repeat three times.
            let count = (points.count - 1) / 3
            var knots = [Int](repeating: 0, count: 4)
            for i in stride(from: 1, to: count, by: 1) { knots += [i, i, i] }
            knots += [Int](repeating: count, count: 4)
            begin("SPLINE", layer)
            entities.add(100, "AcDbSpline"); entities.add(210, "0"); entities.add(220, "0"); entities.add(230, "1")
            entities.add(70, "8"); entities.add(71, "3"); entities.add(72, "\(knots.count)"); entities.add(73, "\(points.count)")
            entities.add(74, "0"); entities.add(42, "0.0000001"); entities.add(43, "0.0000001")
            for k in knots { entities.add(40, "\(k)") }
            for p in points { point(p) }
        }
        func polyline(_ points: [Vec2], closed: Bool, _ layer: String) {
            var points = points
            if closed, points.count > 1, points.first == points.last { points.removeLast() }
            guard points.count > 1 else { return }
            begin("LWPOLYLINE", layer)
            entities.add(100, "AcDbPolyline"); entities.add(90, "\(points.count)"); entities.add(70, closed ? "1" : "0")
            entities.add(43, "0")
            for p in points { entities.add(10, num(p.x)); entities.add(20, num(p.y)) }
        }

        for layer in layers {
            for contour in layer.contours {
                if let circle = contour.circle {
                    begin("CIRCLE", layer.name); entities.add(100, "AcDbCircle"); point(circle.center); entities.add(40, num(circle.radius))
                    continue
                }
                if curves == .polylines {
                    polyline(Self.adaptiveFlatten(contour), closed: contour.closed, layer.name)
                    continue
                }
                var current = contour.start
                var run: [Vec2] = []
                func flush() {
                    if run.count >= 4 { spline(run, layer.name) }
                    run = []
                }
                for segment in contour.segments {
                    switch segment {
                    case .line(let p):
                        flush()
                        line(current, p, layer.name)
                    case .cubic(let c1, let c2, let p):
                        if run.isEmpty { run = [current] }
                        run += [c1, c2, p]
                    }
                    current = segment.end
                }
                flush()
            }
        }

        // Objects: the root dictionary AutoCAD expects.
        let root = next(), groups = next()
        objects.add(0, "DICTIONARY"); objects.add(5, root); objects.add(330, "0"); objects.add(100, "AcDbDictionary")
        objects.add(281, "1"); objects.add(3, "ACAD_GROUP"); objects.add(350, groups)
        objects.add(0, "DICTIONARY"); objects.add(5, groups); objects.add(330, root); objects.add(100, "AcDbDictionary")
        objects.add(281, "1")

        var header = Groups()
        header.add(9, "$ACADVER"); header.add(1, "AC1015")
        header.add(9, "$HANDSEED"); header.add(5, String(handle + 1, radix: 16, uppercase: true))
        header.add(9, "$INSUNITS"); header.add(70, "4")
        header.add(9, "$MEASUREMENT"); header.add(70, "1")
        header.add(9, "$EXTMIN"); header.add(10, num(extMin.x)); header.add(20, num(extMin.y)); header.add(30, "0")
        header.add(9, "$EXTMAX"); header.add(10, num(extMax.x)); header.add(20, num(extMax.y)); header.add(30, "0")

        var out = ""
        for (name, section) in [("HEADER", header), ("TABLES", tables), ("BLOCKS", blocks), ("ENTITIES", entities), ("OBJECTS", objects)] {
            out += "  0\nSECTION\n  2\n\(name)\n" + section.text + "  0\nENDSEC\n"
        }
        out += "  0\nEOF\n"
        return Data(out.utf8)
    }

    /// Curves split finely enough that the polyline stays within ~0.02 mm of the curve.
    static func adaptiveFlatten(_ contour: Contour) -> [Vec2] {
        var points = [contour.start]
        var current = contour.start
        for segment in contour.segments {
            switch segment {
            case .line(let p):
                points.append(p)
            case .cubic(let c1, let c2, let p):
                let hull = current.distance(to: c1) + c1.distance(to: c2) + c2.distance(to: p)
                let steps = min(64, max(4, Int((hull / 0.35).rounded(.up))))
                for i in 1...steps { points.append(Contour.bezier(current, c1, c2, p, Double(i) / Double(steps))) }
            }
            current = segment.end
        }
        return points
    }

    /// Fixed-precision numbers, so shared endpoints are written identically and CAD joins them.
    private func num(_ v: Double) -> String {
        var s = String(format: "%.5f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s == "-0" ? "0" : s
    }

    private struct Groups {
        var text = ""
        mutating func add(_ code: Int, _ value: String) {
            let c = String(code)
            text += String(repeating: " ", count: max(0, 3 - c.count)) + c + "\n" + value + "\n"
        }
    }
}

import CoreGraphics
import Foundation

/// Reads the vector paths of PDF pages (and PDF-compatible Illustrator files) into Sketches, one per page.
/// Walks the content stream with CGPDFScanner: paths, fills, strokes, colours, the CTM and form XObjects.
/// Text glyphs and images are skipped; a full-page background rectangle is dropped.
enum PDFVectorImporter {
    struct Page {
        var sketch: Sketch
        var textRuns: Int
    }

    static func read(_ url: URL) throws -> [Page] {
        guard let document = CGPDFDocument(url as CFURL) else {
            if url.pathExtension.lowercased() == "ai" {
                throw HaluError.failed("This Illustrator file has no PDF inside. Save it with “Create PDF Compatible File” on, or export SVG.")
            }
            throw HaluError.unreadable(url)
        }
        guard document.isUnlocked else { throw HaluError.failed("“\(url.lastPathComponent)” is password-protected.") }
        guard document.numberOfPages > 0 else { return [] }

        let table = makeOperatorTable()
        return (1...document.numberOfPages).compactMap { number -> Page? in
            guard let page = document.page(at: number) else { return nil }
            let box = page.getBoxRect(.cropBox)
            let mm = 25.4 / 72
            let context = Context(table: table, ctm: Affine.scale(mm, mm).concatenating(.translate(-box.minX, -box.minY)))
            let stream = CGPDFContentStreamCreateWithPage(page)
            let scanner = CGPDFScannerCreate(stream, table, Unmanaged.passUnretained(context).toOpaque())
            _ = CGPDFScannerScan(scanner)
            let pageArea = Double(box.width * box.height) * mm * mm
            let shapes = context.shapes.filter { !isBackground($0, pageArea: pageArea) }
            return Page(sketch: Sketch(shapes: shapes), textRuns: context.textRuns)
        }
    }

    /// A single filled rectangle covering (almost) the whole page.
    private static func isBackground(_ shape: SketchShape, pageArea: Double) -> Bool {
        guard shape.filled, shape.contours.count == 1, let contour = shape.contours.first,
              contour.segments.allSatisfy({ if case .line = $0 { true } else { false } }), contour.segments.count <= 5 else { return false }
        return abs(Sketch.signedArea(contour.flattened())) >= pageArea * 0.95
    }

    private final class Context {
        struct State {
            var ctm: Affine
            var fill = RGB.black
            var stroke = RGB.black
        }

        let table: CGPDFOperatorTableRef
        var state: State
        var saved: [State] = []
        var path: [Contour] = []
        var current: Contour?
        var pen = Vec2.zero
        var shapes: [SketchShape] = []
        var textRuns = 0
        var depth = 0

        init(table: CGPDFOperatorTableRef, ctm: Affine) {
            self.table = table
            state = State(ctm: ctm)
        }

        func point(_ x: Double, _ y: Double) -> Vec2 { state.ctm.apply(Vec2(x: x, y: y)) }

        func move(_ p: Vec2) {
            finishSubpath()
            current = Contour(start: p)
            pen = p
        }

        func append(_ segment: Segment) {
            if current == nil { current = Contour(start: pen) }
            current!.segments.append(segment)
            pen = segment.end
        }

        func closeSubpath() {
            guard current != nil else { return }
            current!.close()
            pen = current!.start
            finishSubpath()
        }

        func finishSubpath() {
            if let c = current, !c.segments.isEmpty { path.append(c) }
            current = nil
        }

        func paint(fill: Bool, stroke: Bool, closeFirst: Bool = false) {
            if closeFirst { closeSubpath() }
            finishSubpath()
            defer { path = [] }
            if fill {
                let contours = path.map { contour -> Contour in
                    var c = contour
                    if !c.closed { c.close() }
                    return c
                }
                if !contours.isEmpty { shapes.append(SketchShape(contours: contours, color: state.fill)) }
            } else if stroke, !path.isEmpty {
                shapes.append(SketchShape(contours: path, color: state.stroke, filled: false))
            }
        }
    }

    private static func context(_ info: UnsafeMutableRawPointer?) -> Context {
        Unmanaged<Context>.fromOpaque(info!).takeUnretainedValue()
    }

    /// Pops up to `count` numbers (they come off the stack last-first).
    private static func numbers(_ scanner: CGPDFScannerRef, _ count: Int) -> [Double]? {
        var values: [Double] = []
        for _ in 0..<count {
            var v: CGPDFReal = 0
            guard CGPDFScannerPopNumber(scanner, &v) else { break }
            values.insert(Double(v), at: 0)
        }
        return values.count == count ? values : nil
    }

    /// Colour operands: 1 = gray, 3 = RGB, 4 = CMYK. A pattern name leaves the colour as it was.
    private static func color(_ scanner: CGPDFScannerRef) -> RGB? {
        var values: [Double] = []
        var v: CGPDFReal = 0
        while values.count < 4, CGPDFScannerPopNumber(scanner, &v) { values.insert(Double(v), at: 0) }
        func byte(_ x: Double) -> UInt8 { UInt8(max(0, min(255, (x * 255).rounded()))) }
        switch values.count {
        case 1: return RGB(r: byte(values[0]), g: byte(values[0]), b: byte(values[0]))
        case 3: return RGB(r: byte(values[0]), g: byte(values[1]), b: byte(values[2]))
        case 4:
            let k = 1 - values[3]
            return RGB(r: byte((1 - values[0]) * k), g: byte((1 - values[1]) * k), b: byte((1 - values[2]) * k))
        default: return nil
        }
    }

    private static func makeOperatorTable() -> CGPDFOperatorTableRef {
        let table = CGPDFOperatorTableCreate()!

        // Callbacks are C function pointers: they reach the context through `info` and name the type explicitly.

        // Graphics state
        CGPDFOperatorTableSetCallback(table, "q") { _, info in
            let c = PDFVectorImporter.context(info)
            c.saved.append(c.state)
        }
        CGPDFOperatorTableSetCallback(table, "Q") { _, info in
            let c = PDFVectorImporter.context(info)
            if let state = c.saved.popLast() { c.state = state }
        }
        CGPDFOperatorTableSetCallback(table, "cm") { scanner, info in
            let c = PDFVectorImporter.context(info)
            guard let n = PDFVectorImporter.numbers(scanner, 6) else { return }
            c.state.ctm = c.state.ctm.concatenating(Affine(a: n[0], b: n[1], c: n[2], d: n[3], tx: n[4], ty: n[5]))
        }

        // Path construction
        CGPDFOperatorTableSetCallback(table, "m") { scanner, info in
            let c = PDFVectorImporter.context(info)
            guard let n = PDFVectorImporter.numbers(scanner, 2) else { return }
            c.move(c.point(n[0], n[1]))
        }
        CGPDFOperatorTableSetCallback(table, "l") { scanner, info in
            let c = PDFVectorImporter.context(info)
            guard let n = PDFVectorImporter.numbers(scanner, 2) else { return }
            let p = c.point(n[0], n[1])
            if p != c.pen { c.append(.line(p)) }
        }
        CGPDFOperatorTableSetCallback(table, "c") { scanner, info in
            let c = PDFVectorImporter.context(info)
            guard let n = PDFVectorImporter.numbers(scanner, 6) else { return }
            c.append(.cubic(c.point(n[0], n[1]), c.point(n[2], n[3]), c.point(n[4], n[5])))
        }
        CGPDFOperatorTableSetCallback(table, "v") { scanner, info in
            let c = PDFVectorImporter.context(info)
            guard let n = PDFVectorImporter.numbers(scanner, 4) else { return }
            c.append(.cubic(c.pen, c.point(n[0], n[1]), c.point(n[2], n[3])))
        }
        CGPDFOperatorTableSetCallback(table, "y") { scanner, info in
            let c = PDFVectorImporter.context(info)
            guard let n = PDFVectorImporter.numbers(scanner, 4) else { return }
            let end = c.point(n[2], n[3])
            c.append(.cubic(c.point(n[0], n[1]), end, end))
        }
        CGPDFOperatorTableSetCallback(table, "h") { _, info in
            PDFVectorImporter.context(info).closeSubpath()
        }
        CGPDFOperatorTableSetCallback(table, "re") { scanner, info in
            let c = PDFVectorImporter.context(info)
            guard let n = PDFVectorImporter.numbers(scanner, 4) else { return }
            c.move(c.point(n[0], n[1]))
            c.append(.line(c.point(n[0] + n[2], n[1])))
            c.append(.line(c.point(n[0] + n[2], n[1] + n[3])))
            c.append(.line(c.point(n[0], n[1] + n[3])))
            c.closeSubpath()
        }

        // Painting
        for op in ["f", "F", "f*", "B", "B*"] {
            CGPDFOperatorTableSetCallback(table, op) { _, info in PDFVectorImporter.context(info).paint(fill: true, stroke: true) }
        }
        for op in ["b", "b*"] {
            CGPDFOperatorTableSetCallback(table, op) { _, info in PDFVectorImporter.context(info).paint(fill: true, stroke: true, closeFirst: true) }
        }
        CGPDFOperatorTableSetCallback(table, "S") { _, info in PDFVectorImporter.context(info).paint(fill: false, stroke: true) }
        CGPDFOperatorTableSetCallback(table, "s") { _, info in PDFVectorImporter.context(info).paint(fill: false, stroke: true, closeFirst: true) }
        // "n" ends a clipping path: nothing is painted.
        CGPDFOperatorTableSetCallback(table, "n") { _, info in PDFVectorImporter.context(info).paint(fill: false, stroke: false) }

        // Colours
        for op in ["g", "rg", "k", "sc", "scn"] {
            CGPDFOperatorTableSetCallback(table, op) { scanner, info in
                if let rgb = PDFVectorImporter.color(scanner) { PDFVectorImporter.context(info).state.fill = rgb }
            }
        }
        for op in ["G", "RG", "K", "SC", "SCN"] {
            CGPDFOperatorTableSetCallback(table, op) { scanner, info in
                if let rgb = PDFVectorImporter.color(scanner) { PDFVectorImporter.context(info).state.stroke = rgb }
            }
        }
        CGPDFOperatorTableSetCallback(table, "cs") { _, info in PDFVectorImporter.context(info).state.fill = .black }
        CGPDFOperatorTableSetCallback(table, "CS") { _, info in PDFVectorImporter.context(info).state.stroke = .black }

        // Text is not geometry here; count it so the user can be told to outline it.
        for op in ["Tj", "TJ", "'", "\""] {
            CGPDFOperatorTableSetCallback(table, op) { _, info in PDFVectorImporter.context(info).textRuns += 1 }
        }

        // Form XObjects (groups, symbols, artboards) are drawn inline with their own matrix.
        CGPDFOperatorTableSetCallback(table, "Do") { scanner, info in
            let c = PDFVectorImporter.context(info)
            var namePointer: UnsafePointer<CChar>?
            guard c.depth < 16, CGPDFScannerPopName(scanner, &namePointer), let namePointer else { return }
            let content = CGPDFScannerGetContentStream(scanner)
            guard let object = CGPDFContentStreamGetResource(content, "XObject", namePointer) else { return }
            var streamRef: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &streamRef), let stream = streamRef,
                  let dictionary = CGPDFStreamGetDictionary(stream) else { return }
            var subtype: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype, String(cString: subtype) == "Form" else { return }

            let saved = c.state
            var matrix: CGPDFArrayRef?
            if CGPDFDictionaryGetArray(dictionary, "Matrix", &matrix), let matrix, CGPDFArrayGetCount(matrix) == 6 {
                var n = [CGPDFReal](repeating: 0, count: 6)
                for i in 0..<6 { _ = CGPDFArrayGetNumber(matrix, i, &n[i]) }
                c.state.ctm = c.state.ctm.concatenating(Affine(a: n[0], b: n[1], c: n[2], d: n[3], tx: n[4], ty: n[5]))
            }
            var resources: CGPDFDictionaryRef?
            _ = CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources)
            let inner = CGPDFContentStreamCreateWithStream(stream, resources ?? dictionary, content)
            let innerScanner = CGPDFScannerCreate(inner, c.table, info)
            c.depth += 1
            _ = CGPDFScannerScan(innerScanner)
            c.depth -= 1
            c.state = saved
        }
        return table
    }
}

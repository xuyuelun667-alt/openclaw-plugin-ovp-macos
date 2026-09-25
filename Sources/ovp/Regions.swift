import Foundation
import CoreGraphics

/// Basic region segmentation.
///
/// This is deliberately NOT UI element detection (that is a later phase). It only
/// splits the frame into content bands and column blocks using local-contrast
/// projections, and marks rects we actually know (CGWindowList windows, AX dialogs).
/// Unknown areas stay `generic_region` with a low confidence and no label.
enum RegionFinder {

    static func detect(bitmap: Bitmap, screen: ScreenInfo, frontApp: String?,
                       windows: [WindowInfo], dialogs: [[Int]], level: String) -> [Region] {
        var regions: [Region] = []

        // 1. rects we know for certain
        var known: [Region] = []
        for (i, d) in dialogs.enumerated() {
            known.append(Region(id: "d\(i + 1)", kind: "dialog", bbox: d, source: "ax", confidence: 1.0, label: nil, text_ids: []))
        }
        if level == "normal" {
            for (i, w) in windows.enumerated() {
                if w.frontmost { continue }
                known.append(Region(id: "w\(i + 1)", kind: "window", bbox: w.bounds_px ?? [0, 0, 0, 0],
                                    source: "cgwindow", confidence: 1.0, label: w.app, text_ids: []))
            }
        }

        // 2. heuristic content bands (CV, no semantics)
        var cv: [Region] = []
        if level == "normal" {
            let small = makeBitmapFrom(bitmap, maxWidth: 1000)
            if let small = small {
                let grid = buildInkGrid(small, cellW: 8, cellH: 8)
                let sx = Double(bitmap.width) / Double(small.width)
                let sy = Double(bitmap.height) / Double(small.height)
                let bands = contentBands(grid)
                for (bi, band) in bands.enumerated() {
                    let blocks = columnBlocks(grid, band.0, band.1)
                    for (ci, b) in blocks.enumerated() {
                        let x = Double(b.0 * grid.cellW) * sx
                        let y = Double(band.0 * grid.cellH) * sy
                        let w = Double((b.1 - b.0) * grid.cellW) * sx
                        let h = Double((band.1 - band.0) * grid.cellH) * sy
                        cv.append(Region(id: "r\(bi + 1)_\(ci + 1)", kind: "generic_region",
                                         bbox: [Int(x.rounded()), Int(y.rounded()), Int(w.rounded()), Int(h.rounded())],
                                         source: "cv", confidence: 0.35, label: nil, text_ids: []))
                    }
                }
            }
        }

        regions = known + cv

        return regions
    }

    /// rows of the grid that contain ink, grouped into bands (gap tolerant)
    private static func contentBands(_ g: InkGrid) -> [(Int, Int)] {
        let thresh = 0.03
        var rows: [Int] = []
        for r in 0..<g.rows where g.rowInk[r] > thresh { rows.append(r) }
        guard !rows.isEmpty else { return [] }
        let gapTol = max(2, g.rows / 80)
        var bands: [(Int, Int)] = []
        var start = rows[0], prev = rows[0]
        for r in rows.dropFirst() {
            if r - prev > gapTol {
                if prev - start >= 2 { bands.append((start, prev + 1)) }
                start = r
            }
            prev = r
        }
        if prev - start >= 2 { bands.append((start, prev + 1)) }
        return bands
    }

    /// split a band into column blocks at vertical whitespace gutters
    private static func columnBlocks(_ g: InkGrid, _ r0: Int, _ r1: Int) -> [(Int, Int)] {
        var colInk = [Double](repeating: 0, count: g.cols)
        for c in 0..<g.cols {
            var s = 0.0
            for r in r0..<min(r1, g.rows) { s += g.ink(c, r) }
            colInk[c] = s / Double(max(1, r1 - r0))
        }
        let gutterThresh = 0.005
        let minGutter = max(2, g.cols / 120)
        var blocks: [(Int, Int)] = []
        var start = 0
        var run = 0
        for c in 0..<g.cols {
            if colInk[c] < gutterThresh {
                run += 1
            } else {
                if run >= minGutter && c - run > start + 1 {
                    blocks.append((start, c - run))
                    start = c
                }
                run = 0
            }
        }
        if g.cols > start + 1 { blocks.append((start, g.cols)) }
        // drop slivers
        return blocks.filter { $0.1 - $0.0 >= 4 }
    }

    private static func makeBitmapFrom(_ bmp: Bitmap, maxWidth: Int) -> Bitmap? {
        guard bmp.width > maxWidth else { return bmp }
        let s = Double(maxWidth) / Double(bmp.width)
        let w = maxWidth
        let h = max(1, Int((Double(bmp.height) * s).rounded()))
        let bpr = w * 4
        var out = [UInt8](repeating: 0, count: bpr * h)
        for y in 0..<h {
            let sy = min(bmp.height - 1, Int(Double(y) / s))
            for x in 0..<w {
                let sx = min(bmp.width - 1, Int(Double(x) / s))
                let so = sy * bmp.bytesPerRow + sx * 4
                let doff = y * bpr + x * 4
                out[doff] = bmp.data[so]; out[doff + 1] = bmp.data[so + 1]
                out[doff + 2] = bmp.data[so + 2]; out[doff + 3] = bmp.data[so + 3]
            }
        }
        return Bitmap(width: w, height: h, bytesPerRow: bpr, data: out)
    }

    /// assign each text item to the most specific containing region
    static func assignText(_ text: inout [TextItem], regions: inout [Region]) {
        for i in text.indices {
            let c = center(text[i].bbox)
            var best: Region? = nil
            var bestKind = 9
            for r in regions {
                guard contains(r.bbox, text[i].bbox) || (c.0 >= r.bbox[0] && c.0 <= r.bbox[0] + r.bbox[2] &&
                                                          c.1 >= r.bbox[1] && c.1 <= r.bbox[1] + r.bbox[3]) else { continue }
                let rank: Int
                switch r.kind {
                case "dialog": rank = 0
                case "window": rank = 1
                case "generic_region": rank = 2
                default: rank = 3
                }
                if rank < bestKind || (rank == bestKind && (best.map { rectArea($0.bbox) > rectArea(r.bbox) } ?? true)) {
                    best = r; bestKind = rank
                }
            }
            text[i].region_id = best?.id
        }
        for ri in regions.indices {
            regions[ri].text_ids = text.filter { $0.region_id == regions[ri].id }.map { $0.id }
        }
    }
}

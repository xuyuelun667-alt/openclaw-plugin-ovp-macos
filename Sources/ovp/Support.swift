import Foundation
import CryptoKit
import CoreGraphics
import AppKit

// MARK: - hashing / time

func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
func sha256Hex(_ s: String) -> String { sha256Hex(Data(s.utf8)) }
func shortHash(_ hex: String) -> String { String(hex.prefix(12)) }

// MARK: - bitmap access

struct Bitmap {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let data: [UInt8]

    func luminance(_ x: Int, _ y: Int) -> Double {
        let o = y * bytesPerRow + x * 4
        let r = Double(data[o]), g = Double(data[o + 1]), b = Double(data[o + 2])
        return 0.299 * r + 0.587 * g + 0.114 * b
    }
}

/// Rasterize a CGImage into a deterministic RGBA8 buffer (optionally downscaled).
func makeBitmap(_ cg: CGImage, maxWidth: Int? = nil) -> Bitmap? {
    var w = cg.width
    var h = cg.height
    if let mw = maxWidth, w > mw {
        let s = Double(mw) / Double(w)
        w = mw
        h = max(1, Int((Double(cg.height) * s).rounded()))
    }
    let bpr = w * 4
    var buf = [UInt8](repeating: 0, count: bpr * h)
    var ok = false
    buf.withUnsafeMutableBytes { raw in
        guard let base = raw.baseAddress,
              let ctx = CGContext(data: base, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: bpr, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        ok = true
    }
    guard ok else { return nil }
    return Bitmap(width: w, height: h, bytesPerRow: bpr, data: buf)
}

// MARK: - ink grid (region heuristics, no semantics)

struct InkGrid {
    var cols: Int
    var rows: Int
    var cellW: Int
    var cellH: Int
    var ink: [Double]     // cols*rows, 0..1
    var rowInk: [Double]
    var colInk: [Double]

    func ink(_ c: Int, _ r: Int) -> Double { ink[r * cols + c] }
}

func buildInkGrid(_ bmp: Bitmap, cellW: Int = 8, cellH: Int = 8) -> InkGrid {
    let cols = max(1, bmp.width / cellW)
    let rows = max(1, bmp.height / cellH)
    var ink = [Double](repeating: 0, count: cols * rows)
    for r in 0..<rows {
        for c in 0..<cols {
            let x0 = c * cellW, y0 = r * cellH
            var lo = 255.0, hi = 0.0
            for y in y0..<min(y0 + cellH, bmp.height) {
                for x in x0..<min(x0 + cellW, bmp.width) {
                    let l = bmp.luminance(x, y)
                    if l < lo { lo = l }
                    if l > hi { hi = l }
                }
            }
            // local contrast => ink. Flat areas (wallpaper/background) => 0.
            ink[r * cols + c] = min(1.0, max(0.0, (hi - lo - 25.0) / 60.0))
        }
    }
    var rowInk = [Double](repeating: 0, count: rows)
    var colInk = [Double](repeating: 0, count: cols)
    for r in 0..<rows {
        var s = 0.0
        for c in 0..<cols { s += ink[r * cols + c] }
        rowInk[r] = s / Double(cols)
    }
    for c in 0..<cols {
        var s = 0.0
        for r in 0..<rows { s += ink[r * cols + c] }
        colInk[c] = s / Double(rows)
    }
    return InkGrid(cols: cols, rows: rows, cellW: cellW, cellH: cellH, ink: ink, rowInk: rowInk, colInk: colInk)
}

// MARK: - geometry helpers

func bboxXYWH(_ r: CGRect) -> [Int] { [Int(r.minX.rounded()), Int(r.minY.rounded()), Int(r.width.rounded()), Int(r.height.rounded())] }

func rectArea(_ b: [Int]) -> Double { b.count == 4 ? Double(b[2]) * Double(b[3]) : 0 }

func rectUnionArea(_ rects: [[Int]]) -> Double {
    // exact union via x-sweep (rect counts here are small)
    guard !rects.isEmpty else { return 0 }
    var xs: [Int] = []
    for r in rects { xs.append(r[0]); xs.append(r[0] + r[2]) }
    xs = Array(Set(xs)).sorted()
    var area = 0.0
    for i in 0..<(xs.count - 1) {
        let x0 = Double(xs[i]), x1 = Double(xs[i + 1])
        if x1 <= x0 { continue }
        var spans: [(Double, Double)] = []
        for r in rects where Double(r[0]) < x1 && Double(r[0] + r[2]) > x0 {
            spans.append((Double(r[1]), Double(r[1] + r[3])))
        }
        if spans.isEmpty { continue }
        spans.sort { $0.0 < $1.0 }
        var total = 0.0
        var cur = spans[0]
        for s in spans.dropFirst() {
            if s.0 > cur.1 { total += cur.1 - cur.0; cur = s }
            else { cur.1 = max(cur.1, s.1) }
        }
        total += cur.1 - cur.0
        area += (x1 - x0) * total
    }
    return area
}

func contains(_ outer: [Int], _ inner: [Int]) -> Bool {
    guard outer.count == 4, inner.count == 4 else { return false }
    return inner[0] >= outer[0] && inner[1] >= outer[1] &&
           inner[0] + inner[2] <= outer[0] + outer[2] &&
           inner[1] + inner[3] <= outer[1] + outer[3]
}

func center(_ b: [Int]) -> (Int, Int) { (b[0] + b[2] / 2, b[1] + b[3] / 2) }

// MARK: - process / files

@discardableResult
func runProcess(_ path: String, _ args: [String]) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return -1 }
    p.waitUntilExit()
    return p.terminationStatus
}

func cacheRoot() -> URL {
    let base = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".cache/ovp", isDirectory: true)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base
}

func truncate(_ s: String, _ n: Int) -> String {
    s.count <= n ? s : String(s.prefix(n)) + "…"
}

func collapseWhitespace(_ s: String) -> String {
    s.split(whereSeparator: { $0 == "\n" || $0 == "\t" || $0 == " " || $0 == "\u{00a0}" })
        .joined(separator: " ")
}
